# 采集 ioctl 链 R32 兼容垫片 — 实现说明 / 判定依据 / 风险

目标：让 **JP4(R32) 出厂相机用户态**（chroot 内 libargus / nvargus-daemon）在
**JP5(R35, 5.10.216-tegra) 内核**上正确调用 VI / ISP 采集通道字符设备的 ioctl。

手法沿用 `build/nvmap-r32compat/0001` 的已验证套路：
**按 `_IOC_SIZE(cmd)` 分流；R35 原生路径逐字节不变（零回归）；R32 分支单独翻译。**

产物：
- patch: `0001-fusa-capture-r32-ioctl-abi-compat.patch`（`patch -p1` 从
  `kernel/nvidia/` 应用；已实测 apply 后字节级复现当前源码树）
- 内核产物: `out/`（Image + DTB + 全模块 + 8821cu.ko + SHA256SUMS + VERMAGIC）
- 改前原件: `pristine/`（回滚用）

---

## 0. 一句话结论（先读这条）

**墙 2 / 6 / 7 已实现并编译通过；墙 1.5 经核实判定"不该按原方案修"，跳过；
墙 8 判定为可接受降级。但本轮最重要的产出不是这几个垫片，而是查明了它们
后面还有一堵更硬、且 ioctl 垫片原理上无法翻越的墙：**

> **R35 内核与 R32 RCE 固件之间的 camrtc 采集"控制面 + 每帧内存面"ABI 已经结构性
> 分家。最硬的证据：`CAPTURE_CHANNEL_SETUP_REQ` 的消息号 R32=`0x10`，R35=`0x1E`，
> 而 R35 把 `0x10` 显式改名成了 `CAPTURE_CONTROL_RESERVED_10`。**

详见 §6。这决定了对"这批改动让相机出图的把握"的诚实评估。

---

## 1. 各墙的判定与实现

### 墙 2 — `VI_CAPTURE_SETUP` 40B → 88B【已实现，头号】

**判定依据（静态比对，双树对照）**

| 源 | 文件 | `sizeof(struct vi_capture_setup)` |
|---|---|---|
| R32 | `mirror/cyberdog_tegra_kernel.git : kernel/nvidia/include/media/capture.h` | **40** |
| R35 | `include/media/fusa-capture/capture-vi.h` | **88** |

R35 在中段插入 `uint64_t vi2_channel_mask`（偏移 16），此后**每一个字段全部错位**；
末尾另加 `csi_stream_id / virtual_channel_id / csi_port / __pad_csi /
stop_on_error_notify_bits / reserved[2]`。

派发器是 `switch (_IOC_NR(cmd))`，所以 R32 的 `_IOW('I',1,40)`（`0x40284901`）
**能命中 case**，然后 `copy_from_user(&setup, ptr, sizeof(setup))` 从一个 40 字节
的用户对象里读 88 字节 → 越界读 + 字段全错 → 后续
`setup.request_size < sizeof(struct capture_descriptor)` 之类的校验必然乱判
（读到的 request_size 实际是 R32 的 `mem`），→ `-EINVAL`，通道建不起来。

**改法**：`capture-vi-channel.c` 新增私有复制体 `struct vi_capture_setup_r32`
（40B，`BUILD_BUG_ON` 断言尺寸）+ 静态函数
`vi_capture_setup_copy_from_user(ptr, cmd, setup)`：

- `_IOC_SIZE(cmd) != 40` → 原样 `copy_from_user(setup, ptr, sizeof(*setup))`，
  R35 原生路径**行为逐字节不变**；
- `_IOC_SIZE(cmd) == 40` → 读 40 字节，`memset` 后逐字段搬运。

`VI_CAPTURE_SETUP` case 内把原来的 `copy_from_user(...) break;` 换成调用该函数，
失败后**把 `err` 重新置回 `-EFAULT`**，以保持"后续任何早退 `break` 都返回 -EFAULT"
的原有语义（原代码正是靠函数开头的 `int err = -EFAULT;` 哨兵值）。

**R35 独有字段怎么合成（每一个都有依据）**

| 字段 | 合成值 | 依据 |
|---|---|---|
| `vi2_channel_mask` | `0`（= `CAPTURE_CHANNEL_INVALID_MASK`，`capture-vi.c:54` 定义为 `U64_C(0x0)`） | T194 只有一个 VI 单元。活体 DT `/proc/device-tree/tegra-capture-vi/nvidia,vi-mapping` 实读 = `{0→0,1→0,2→0,3→0,4→0,5→0}`，即 `vi_instance_table[*] = VI_UNIT_VI(0)`。`vi_capture_setup()` 里只有 `vi_inst == VI_UNIT_VI2` 时才 `WARN_ON(vi2_channel_mask == INVALID)`，本机永不成立 |
| `csi_stream_id` | `0` | 必须 `< MAX_NVCSI_STREAM_IDS(6)` 且 `!= NVCSI_STREAM_INVALID_ID(0xFFFF)`（`capture-vi.c:683` 的 `WARN_ON`）。填 0 两条都满足 |
| `virtual_channel_id` | `0` | 必须 `< MAX_VIRTUAL_CHANNEL_PER_STREAM(16)`（`capture-vi.c:613`） |
| `csi_port` | `NVCSI_PORT_UNSPECIFIED (0xFFFFFFFF)` | 与 `vi_capture_init()` 给 `capture->csi_port` 的初值一致；setup 阶段对它无任何校验 |
| `stop_on_error_notify_bits`, `reserved[2]` | `0`（memset） | R32 无此概念 |

**为什么合成 stream/vc/port 是安全的、不是"糊弄"**：R32 的绑定机制本来就不在
channel setup 里。R32 与 R35 的 `vi_capture_control_message*()` 都会**嗅探**用户态
发下来的控制消息，在 `CAPTURE_PHY_STREAM_OPEN_REQ` 时写
`capture->stream_id / ->csi_port`，在 `CSI_STREAM_TPG_START_REQ` 时写
`->virtual_channel_id`（R32 `capture.c:876`；R35 `capture-vi.c:1063`）。也就是说
真正生效的绑定是**后续**由用户态自己下发的，setup 里的值只是初值。

**唯一的副作用**：`capture-vi.c:818` 的 `channels[csi_stream_id][vc_id] = chan;`
反查表——所有 R32 通道都会落在 `channels[0][0]`，互相覆盖。核实过该表只有
`csi5_fops.c:146`（V4L2 通路）在用，libargus/fusa 通路不读它，因此对本任务无影响
（最坏是 V4L2 侧错误上报串台，而 V4L2 通路本机不用于 AI 相机）。

---

### 墙 6 — `VI_CAPTURE_GET_INFO` `copy_to_user` 越界【已实现】

`struct vi_capture_info`：R32 **40B**，R35 **48B**（尾部追加 `vi2_channel_mask`，
**没有任何字段移动**）。原代码 `copy_to_user(ptr, &info, sizeof(info))` 会往用户的
40 字节缓冲多写 8 字节。

改法：`copy_size = min_t(size_t, (size_t)_IOC_SIZE(cmd), sizeof(info))`。
R35 原生调用者 `_IOC_SIZE(cmd) == sizeof(info)`，**可证明是 no-op**；R32 调用者被
截到 40 字节，而前 40 字节布局完全一致 → 这是一次**语义完整**的 R32 回答，不是降级。

### 墙 7 — `ISP_CAPTURE_SETUP` 32B → 40B【已实现】

`struct isp_capture_setup`：R32 **32B**，R35 **40B**，差异是**纯追加**
（`error_mask_correctable` / `error_mask_uncorrectable`）。原代码
`copy_from_user(&setup, ptr, sizeof(setup))` 越界读 8 字节。

改法：先 `memset(&setup, 0, sizeof(setup))`（把 R35 独有尾部清零 = "无 error mask"），
再 `copy_from_user(..., min_t(size_t, _IOC_SIZE(cmd), sizeof(setup)))`。

### 墙 6' — `ISP_CAPTURE_GET_INFO` 16B → 24B【顺手一起修，同类】

`struct isp_capture_info`：R32 **16B**（4×u32），R35 **24B**（追加 `channel_id`
+ 8 字节对齐尾）。同样是纯追加 → 同样用 `min_t` 截尾写回。任务清单里只点名了 VI 的
GET_INFO，但 ISP 的这个是**一模一样的 8 字节用户缓冲区溢写**，不修留着就是个坑。

其余 VI/ISP ioctl 载荷经逐一比对 **R32 与 R35 尺寸完全相同**，无需处理：
`vi_capture_control_msg`(24)、`vi_capture_req`(16)、`vi_capture_progress_status_req`(24)、
`vi_capture_compand`(120)、`isp_capture_req`(64)、`isp_program_req`(24)、
`isp_capture_req_ex`(104)、`isp_capture_progress_status_req`(32)。
`__u32` 载荷的（RELEASE/RESET/STATUS 等）天然一致。

---

## 2. 墙 1.5（nvmap `RESERVE`, nr 18）— **判定：跳过，且原方案有害**

**事实核对**

- R32 有 `NVMAP_IOC_RESERVE = _IOW('N',18, struct nvmap_cache_op_list)`；
  R35 `include/uapi/linux/nvmap.h` 里 **nr 18 已删除**。
- `struct nvmap_cache_op_list` 在 R32/R35 **完全一致**（32B），所以 R32 用户态发出的
  命令字确实就是 `0x40204e12`，在 R35 落到 `default:` → `-ENOTTY`。

**为什么不做**

1. **没有证据说明 JP4 用户态真的会发它。** 本次 `journalctl -b0` / `dmesg` 里没有
   任何相机相关记录（本次引导没跑过相机），历史 strace 也没留档。任务要求
   "先用 dmesg 证据判定是否真需要，不需要就跳过"——证据不存在，故跳过。
2. **更要紧：任务给的修法（"路由到 cache maintenance"）在语义上是错的，而且危险。**
   `RESERVE` 的 `op` 是**另一套枚举**：
   `NVMAP_PAGES_UNRESERVE=0 / NVMAP_PAGES_RESERVE=1 / NVMAP_INSERT_PAGES_ON_UNRESERVE=2 /
   NVMAP_PAGES_PROT_AND_CLEAN=3`，而 cache 的是
   `NVMAP_CACHE_OP_WB=0 / INV=1 / WB_INV=2`。直接路由过去会把
   `RESERVE(1)` 解释成 **`INV`（只失效不回写）**——脏的 CPU cache 行被直接丢弃，
   **静默数据损坏**；`PROT_AND_CLEAN(3)` 则落到非法 op → `-EINVAL`。
   这比现状（干净的 `-ENOTTY`）**更坏**。
3. R32 里 `nvmap_handles_reserve()`（`nv2/nvmap_handle_mm.c:150`）的真实语义是
   **页保护 + 脏页跟踪**（`handles_prot(PROT_NONE/RESTORE)` + `pgalloc.reserved` +
   `ndirty` 清零），只有句柄带 `NVMAP_HANDLE_CACHE_SYNC_AT_RESERVE` 用户标志时才附带
   一次 `WB` / `WB_INV`。R35 仍保留 `NVMAP_HANDLE_CACHE_SYNC_AT_RESERVE` 这个标志位，
   但删掉了整条 reserve 通路。

**如果将来 strace 证明确实在发 nr 18，正确修法是二选一**（不要用原方案）：
   - (a) 忠实回移 `nvmap_handles_reserve()` 的语义（页保护 + 按 `CACHE_SYNC_AT_RESERVE`
     决定 `WB`/`WB_INV`）；
   - (b) 保守地实现成 **返回 0 的具名空操作**——reserve 本质是回收/脏页优化，不做只
     影响性能，不影响正确性；除非句柄带 `CACHE_SYNC_AT_RESERVE`，那时必须走 (a)。

---

## 3. 墙 8 — `capture_descriptor` 字段错位【判定：可接受降级，本轮不修】

用两棵树的真实头文件编译尺寸探针（`scratchpad/szprobe/`，LP64 下与 aarch64 等价）：

| 结构 | R32 | R35 |
|---|---|---|
| `struct capture_descriptor` | **704 B** | **384 B** |
| `offsetof(capture_descriptor, status)` | **624** | **272** |
| `offsetof(capture_descriptor, ch_cfg)` | 64 | 64 |
| `struct isp_capture_descriptor` | 576 B | 768 B |

- **不会误伤 setup**：`capture-vi-channel.c` 有
  `if (setup.request_size < sizeof(struct capture_descriptor)) return -EINVAL;`。
  R32 用户态给的 `request_size` ≥ 704，R35 的 `sizeof` = 384，**704 ≥ 384 通过**。
  （方向反了就会直接卡死在这里——特意验了。）
- 帧完成走 syncpoint + `CAPTURE_STATUS_IND` IVC（该消息 R32/R35 布局与 id 一致，
  见 §6 表），所以"知道第几帧好了"这件事不受影响。
- 受损的只是内核侧按错误偏移读 `desc->status` 的详细状态回读/错误统计。
- **描述符本身由 R32 用户态写、R32 固件读，两边天然对齐**，所以画面数据通路不因
  这个偏移而错。故标记为可接受降级。

---

## 4. 改了哪个文件的哪个函数

```
drivers/media/platform/tegra/camera/fusa-capture/capture-vi-channel.c
  + struct vi_capture_setup_r32                   (新增，文件私有，40B 复制体)
  + VI_CAPTURE_SETUP_SIZE_R32                     (新增宏 40)
  + vi_capture_setup_copy_from_user()             (新增 static 函数，尺寸分流+翻译)
  ~ vi_channel_ioctl() / case VI_CAPTURE_SETUP    (改 3 行：调用上面的函数)
  ~ vi_channel_ioctl() / case VI_CAPTURE_GET_INFO (改 2 行：copy_to_user 用 min_t)

drivers/media/platform/tegra/camera/fusa-capture/capture-isp-channel.c
  ~ isp_channel_ioctl() / case ISP_CAPTURE_SETUP    (memset + copy_from_user 用 min_t)
  ~ isp_channel_ioctl() / case ISP_CAPTURE_GET_INFO (copy_to_user 用 min_t)
  + 一段 doc 注释块
```

**没有触碰任何 R35 原生代码路径的语义**：三处 `min_t` 在 `_IOC_SIZE(cmd) ==
sizeof(struct)` 时恒等；`vi_capture_setup_copy_from_user()` 的非-40 分支就是原来的
那行 `copy_from_user`。

---

## 5. 构建与校验

- 容器 `nvmap-kbuild`（镜像 `cyberdog-kbuild`），`bash /work/full-build.sh`，
  `athena_defconfig`，`LOCALVERSION=-tegra`。**退出码 0**，耗时 2m13s。
- `KREL = 5.10.216-tegra`（脚本内已断言）；`8821cu.ko` vermagic
  `5.10.216-tegra SMP preempt mod_unload modversions aarch64`。
- **零 warning 引入**：`fusa-capture/Makefile` 带 `ccflags-y += -Werror`，我们改的两个
  `.o` 本轮都重新编译过（`/tmp/kb/.../capture-vi-channel.o`、`capture-isp-channel.o`
  时间戳 = 本次构建）。全构建日志里 `warning:` 共 **12 条，全部是既有的、与本改动无关的
  DTS 预处理告警**（`tegra234-p3740-camera-*.dtsi:"CAM0_PWDN" redefined`，T234 别的板子）。
  C 编译零告警。
- 目标码确认：`strings capture-vi-channel.o` 含 `vi_capture_setup_copy_from_user`
  与 `vi_capture_setup_r32`（函数被内联进 `vi_channel_ioctl`，符号只留在调试信息里）。
- **patch 自检**：把 `pristine/` 摆成树形后 `patch -p1` 应用，结果与当前源码树
  **byte-identical**。

### DTB 铁律校验（`dtc -I dtb -O dts` 反编译实测）

`out/tegra194-p3668-0001-p2151-0000.dtb`（sha256 `ca10d58c…`）：

| 检查项 | 结果 |
|---|---|
| `camera-diagnostics/diag@5` → `status` | **`"disabled"` ✅**（防 CH_SETUP 错误 128 复发） |
| legacy `hsp`（`nvidia,tegra186-hsp-mailbox`） | `status="okay"`, `mbox-names="cmd-rx,cmd-tx,ivc-rx,ivc-tx"` ✅ |
| `hsp-vm1/2/3` + `hsp-cem` | 全 `disabled` ✅ |
| 热区 `map3` | 出现 **0** 次（已删）✅ 防热跳闸死机 |
| `rt5680` | 6 处 ✅（音频不回退） |
| `bcm4775` GPS | 存在 ✅ |

---

## 6. 【最重要】下一堵墙：R35 内核 ↔ R32 RCE 固件的 camrtc 采集 ABI 已分家

这不是猜测，是三条独立的硬证据。狗上跑的 RCE 固件是 **eMMC boot0 里的出厂 R32 固件**
（刷固件路线此前已实测排除），所以内核**自己生成**的 IVC 消息必须说 R32 方言。

**证据 1 — 消息号被改了（最致命，一票否决）**

```
R32 camrtc-capture-messages.h :  #define CAPTURE_CHANNEL_SETUP_REQ   U32_C(0x10)
R35 camrtc-capture-messages.h :  #define CAPTURE_CONTROL_RESERVED_10 MK_U32(0x10)
                                 #define CAPTURE_CHANNEL_SETUP_REQ   MK_U32(0x1E)
```
R35 内核发的是 `0x1E`。R32 固件不认识 `0x1E`。**这一条就足以让
`VI_CAPTURE_SETUP` 在 IVC 层失败，无论 ioctl 垫片多完美。**
（注意：这与已修好的那个 "CH_SETUP 错误 128 / diag@5" **是两回事**——那个是 IVC
总线建立层的 `RTCPU_CMD_CH_SETUP`，这个是采集通道分配的
`CAPTURE_CHANNEL_SETUP_REQ`。）

**证据 2 — 控制面结构体布局分家**

| 结构（内核→固件） | R32 | R35 | 变化 |
|---|---|---|---|
| `capture_channel_config` | 216 B | 272 B | 中段插入 `vi_unit_id/__pad`、`vi2_channel_mask`、`csi_stream`、`requests_memoryinfo`… 字段全错位 |
| `capture_channel_isp_config` | 168 B | 184 B | 中段插入 `requests_memoryinfo/programs_memoryinfo/*_memoryinfo_size` |
| `CAPTURE_CONTROL_MSG` | 264 B | 280 B | — |

而 `CAPTURE_CHANNEL_ISP_SETUP_REQ` 的**消息号两边都是 `0x20`** —— 更糟：R32 固件会
"接受"这条消息然后按错误布局解析，**静默乱掉**而不是干脆报错。

**证据 3 — 每帧内存模型换了范式（这条即使修好前两条也还挡着）**

- **R32**：用户态在 `vi_capture_req` 里给 `num_relocs` + `reloc_relatives`，
  **内核把 IOVA 就地打补丁写进描述符**（`capture_common_request_pin_and_reloc`）。
- **R35**：内核**不再改描述符**，改为把 IOVA 写进一条独立的 `requests_memoryinfo`
  环（`pin_vi_capture_request_buffers_locked`），由固件通过
  `config->requests_memoryinfo` 去读；缓冲区必须先经
  **`VI_CAPTURE_BUFFER_REQUEST`（`_IOW('I',10,…)`，R32 根本没有这个 ioctl 号）**
  注册进 `capture->buf_ctx` 缓冲表。

后果：R32 用户态永远不会调 `VI_CAPTURE_BUFFER_REQUEST` → `buf_ctx` 是空的 →
每一次 `VI_CAPTURE_REQUEST` 里的 `capture_common_pin_and_get_iova()` 都会失败；
即便侥幸过了，R32 固件也仍在读描述符里那份**没被打补丁**的地址。

**好消息（划定范围用）**：数据面消息本身两边一致——
`CAPTURE_REQUEST_REQ_MSG` / `CAPTURE_STATUS_IND_MSG` 布局与 id 相同；
`VI_CAPTURE_SET_CONFIG` 走的是"用户态自带 buffer 原样透传"
（`vi_capture_control_message_from_user` 里 `kzalloc(msg->size)` + 原样转发），
所以**用户态自己构造的那些控制消息（PHY_STREAM_OPEN / CSI_STREAM_SET_CONFIG / TPG…）
天生就是 R32 方言，会被固件正确接受**。坏的只有内核自己造的那几条。

### 由此得出的路线建议

继续在 R35 驱动上打 ioctl 垫片是**死路**：还得再翻译控制面结构体、伪造消息号、
再把 R35 的 memoryinfo 范式退回 R32 的 reloc 范式——那等于把 R35 的
`fusa-capture` 重写成 R32。

**更省力、且和已经打赢的那两仗（legacy hsp 邮箱回移、diag@5）同一套路的做法：
把 R32 的采集驱动整体回移**——源码在镜像里现成：
```
mirror/cyberdog_tegra_kernel.git:
  kernel/nvidia/drivers/media/platform/tegra/camera/vi/capture.c
  kernel/nvidia/drivers/media/platform/tegra/camera/vi/capture_vi_channel.c
  kernel/nvidia/drivers/media/platform/tegra/camera/capture_common.c
  kernel/nvidia/drivers/media/platform/tegra/camera/isp/capture_isp.c
  kernel/nvidia/drivers/media/platform/tegra/camera/isp/isp_channel.c
  kernel/nvidia/include/media/capture*.h
  kernel/nvidia/include/soc/tegra/camrtc-capture*.h   (R32 版本)
```
它们对内核的依赖面很窄（`tegra-capture-ivc`、nvhost syncpt、dma-buf/nvmap），
这些接口在 R35 上都还在。这样 **用户态(R32) ↔ 驱动(R32 语义) ↔ 固件(R32)** 三方
自洽，不需要任何翻译。工作量估计比继续糊垫片小，成功概率高得多。
（本轮这批垫片在那条路线下会变成无用功——但它们**风险为零、可随时回滚**，
且在"先部署看看下一堵墙长什么样"的调试节奏里仍有价值。）

---

## 7. 部署（由主控执行；本 agent 未动狗一个字节）

**这批改动全部编进 `Image`**，不是 `.ko`：
`CONFIG_TEGRA_CAMERA_RTCPU=y`（`athena_defconfig`），`fusa-capture/Makefile` 是
`obj-$(CONFIG_TEGRA_CAMERA_RTCPU) +=`，所以 `capture-vi-channel.o` /
`capture-isp-channel.o` 是**内建**的。

要换的文件：

| 文件 | 必须换吗 | 说明 |
|---|---|---|
| `out/Image` | **必须** | 本次改动的唯一载体 |
| `out/tegra194-p3668-0001-p2151-0000.dtb` | 建议同步换 | 内容与上一版一致（同一套 DT 修复，已 dtc 校验 diag@5 disabled），换成配套的更安全 |
| `out/modules-5.10.216-tegra.tar.gz` | 建议同步换 | 同一次构建的模块集（含 `nvmap.ko`，**内含 0001/0002/0003 三层 nvmap 修复**） |
| `out/modules/8821cu.ko` | 同上 | Wi-Fi |

- 引导配置真身 = **eMMC p1 的 `/boot/extlinux`（→ `/boot-jp5/`）**；nvme 上那两份
  conf 是幌子（见 memory）。
- 换 `Image` 后按既有流程重建 initrd（`tools/phase4/build-jp5-initrd.sh`，注意顺序：
  永远先 `full-build.sh` 再建 initrd）。
- **部署前备份**：`Image.prev-capture-compat` / `*.dtb.prev-capture-compat`。
- 上一版可回滚基线：`build/nvmap-handle-fd/out/`（Image sha256 `c13cfaf9…`）。

## 8. 风险与回滚

- **回归风险：极低。** 三处改动在 R35 原生尺寸下可证明恒等；第四处
  （SETUP 翻译）只有 `_IOC_SIZE(cmd)==40` 时才走新分支，R35 原生调用者
  `_IOC_SIZE` 恒等于 88。本机上除 JP4 chroot 外没有别的 nvargus 用户态。
- **安全性其实是变好了**：修掉了两处 `copy_to_user` 越界写用户缓冲（VI 和 ISP 的
  GET_INFO）和两处越界读。
- **回滚**：还原 `Image`（+ DTB/模块）到 `.prev-capture-compat`，重建 initrd，重启。
  源码侧：`pristine/` 里两个 `.c` 覆盖回去，或反向应用 patch。
- **DTB 铁律**：任何后续构建部署的 DTB 都必须含 `diag@5 disabled`，否则 CH_SETUP
  复发错误 128。本轮产物已 dtc 校验通过（§5）。
- **热管理连带风险**：热区 `map3` 删除修复寄生在 `tegra194-mi-k91-audio.dtsi` 里；
  本轮 DTB 已确认 `map3` 出现 0 次。若将来有人回退音频 DTS，会**静默复发热跳闸死机**。
