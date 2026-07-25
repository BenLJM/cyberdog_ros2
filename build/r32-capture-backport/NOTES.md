# R32 采集语义回移到 R35 内核 — 实现说明 / 判定依据 / 风险 / 把握度

**日期**：2026-07-25
**目标**：让 JP5(R35, 5.10.216-tegra) 内核对 eMMC boot0 里那份**不可刷写的 R32 RCE 相机固件**
说 R32 的采集 ABI，从而让 chroot 里的 JP4 出厂 libargus/nvargus 走通最后一层。
**产物**：`0001..0004` patch + `pristine/`（改前原件）+ `out/`（Image/DTB/全模块）

---

## 0. 一句话结论（先读这条）

**工程做完了，编译零 warning 零 error，DTB 五项铁律全过，改动 100% 是纯增量（`+2809 / -0`，
每一处都包在 `#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)` 里），关掉开关重编即字节级回到今天的行为。
但能不能出图仍是未知——把握度我给 35–45%，理由见 §8。**

---

## 1. 最终采用的共存策略

侦察 A1b 判定的是 **(A) 直接替换，范围严格限定在"RCE 线协议层"**；任务硬要求 2 又要
"R35 原生路径尽量逐字节不变、R32 语义由 Kconfig 门控"。这两者不矛盾，落地形态是：

> **全局 ABI 头二选一 + 逐点 `#if` 分支 + Kconfig 编译期开关。**
> `CONFIG_TEGRA_CAPTURE_R32_ABI=y` → 整个内核构建看到 R32 的 camrtc 布局；
> `=n` → 预处理结果与 NVIDIA 原版逐字节相同。

### 1.1 为什么必须是"全局"而不是"只给几个 .c 换头"

`struct vi_capture`（`include/media/fusa-capture/capture-vi.h`）内嵌
`struct CAPTURE_CONTROL_MSG control_resp_msg` 和 `struct syncpoint_info progress_sp`。
这个结构被 `capture-vi.c` / `capture-vi-channel.c` / `vi5_fops.c` / `csi5_fops.c`
四个编译单元共享。若只给其中一部分换 R32 头，`sizeof(struct vi_capture)` 与各成员偏移
会在不同 TU 之间不一致 → **ODR 违例 → 静默内存踩踏**。这比"消息号不对"危险一个数量级。
所以头文件选择只能是全局的、编译期唯一的。

### 1.2 实现手法（`0001`）

- 新增 `include/soc/tegra/camrtc-capture-r32.h`
  = R32 mirror（`build/mirror/cyberdog_tegra_kernel.git` 分支 `athena`）
  `kernel/nvidia/include/soc/tegra/camrtc-capture.h` **逐字节原样**，只做两处机械改动：
  1. include guard 改名 `INCLUDE_CAMRTC_CAPTURE_H` → `..._R32_H`；
  2. 文件尾追加一段 **"r35 兼容附录"**（见 §3.3）。
- 新增 `include/soc/tegra/camrtc-capture-messages-r32.h`
  = R32 同名文件原样，guard 改名 + `#include "camrtc-capture.h"` 改指 r32 头。
- 把 R35 的 `camrtc-capture.h` / `camrtc-capture-messages.h` **整体正文包进
  `#ifndef CAMRTC_CAPTURE_R32_ABI_SELECTED`**，开头插入：

  ```c
  #if defined(__KERNEL__)
  #include <linux/kconfig.h>
  #if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)
  #include "camrtc-capture-r32.h"
  #define CAMRTC_CAPTURE_R32_ABI_SELECTED 1
  #endif
  #endif
  ```

  两个 R35 头各只多了 43 行，**一行原有内容都没删**。`__KERNEL__` 判断保证用户态
  包含这两个头（NVIDIA 允许）时行为不变。
- `drivers/media/platform/tegra/Kconfig` 新增 `config TEGRA_CAPTURE_R32_ABI`
  （`depends on TEGRA_CAMERA_RTCPU`，`default n`）。
- `arch/arm64/configs/athena_defconfig` 加一行 `CONFIG_TEGRA_CAPTURE_R32_ABI=y`
  —— **回滚 = 删这一行重编**。

### 1.3 为什么没有走"整体搬 12 个文件 / 6664 行"

侦察 A1a 的清单是对的，但真正**必须**按 R32 语义走的只有三件事：

| 差异 | 是否必须动 | 处理 |
|---|---|---|
| `CAPTURE_CHANNEL_SETUP_REQ` 0x10 vs 0x1E | ✅ | 换头即自动生效 |
| `capture_channel_config` 216B vs 272B | ✅ | 换头 + `#if` 掉 R35 独有字段赋值 |
| `capture_channel_isp_config` 168B vs 184B（消息号两边都是 0x20，会静默乱解析） | ✅ | 同上 |
| `capture_descriptor` 704B vs 384B | ✅ | 换头即自动生效（`vi5_fops.c` 因此**零改动**就对了） |
| 每帧内存模型 reloc vs buffer-table/memoryinfo | ✅ | 新增 R32 reloc pass（`0002`/`0003`） |
| 其余 57 个控制消息号 | ❌ 两边一致 | 不动 |
| `tegra-capture-ivc` 传输层 | ❌ 签名逐字节相同、且已实测跑通 | 不动 |
| `capture-support.c` / syncpt / GoS ops | ❌ 结构逐字段一致 | 不动 |
| `tegra-camrtc-capture-vi` 平台驱动 / media controller / DT | ❌ | **保留 R35**，DT 一个字节没动 |

我做了一次全量核对（脚本对 R32/R35 两套头里 29 个同名结构逐个编译 `sizeof`）：
**只有 8 个结构尺寸不同**，其中 5 个（`capture_status` / `isp5_program` /
`isp5_program_entry` / `nvcsi_error_config` / `nvcsi_tpg_config_t194`）内核根本不按字段访问，
或只 `memset(0)` 后整块塞进消息。所以"6664 行整体搬运"是不必要的：真正的语义差只有上表那 5 行。

**代价**：因为保留了 R35 的注册底盘，9 个 video 节点 / 6 个 subdev 绑定 /
`tegra-capture-vi` 平台驱动 / `nvidia,vi-mapping` 解析全部原封不动 —— 这正是 A1c 点名的
"最容易自伤的一坑"，本方案从结构上避开了它。

---

## 2. 逐文件改了什么、为什么

### 2.1 `0001` — ABI 头 + Kconfig（+2392 行，全部新增）

见 §1.2。此外 R32 头的兼容附录里补了 `VI_UNIT_VI` / `VI_UNIT_VI2` 两个宏
（R32 没有多 VI 实例的概念，但 R35 的 `vi_instance_table[]` 内核侧记账要用；
T194 只有一个 VI 单元，值 0/1 与 R35 一致）。

### 2.2 `0002` — VI（`capture-vi.c` + `capture-vi-channel.c`，+214 行）

**a) `vi_capture_setup()`：`#if` 掉 R35 独有的 wire 字段赋值**

```
config->requests_memoryinfo / request_memoryinfo_size   ← R32 struct 没有
config->vi2_channel_mask                                ← R32 struct 没有
config->vi_unit_id                                      ← R32 struct 没有
config->csi_stream.{stream_id,csi_port,virtual_channel} ← R32 struct 没有
config->stop_on_error_notify_bits                       ← R32 struct 没有
```

其余赋值（`channel_flags` / `vi_channel_mask` / `slvsec_*` / `queue_depth` /
`request_size` / `requests` / `error_mask_*` / 三个 syncpt）**一个字都没改** ——
它们在 R32 结构里字段名与语义完全相同，换头后自动落到 R32 偏移。

> ⚠️ **语义降级（已知、可接受、必须记录）**：R32 的 channel setup 不携带
> csi-stream ↔ vi-unit 映射。DT 里那张表仍被 `capture_vi_probe()` 解析用于内核侧选
> VI 实例，只是**不下发给固件**。T194/Xavier NX 只有一个 VI 单元，R35 引入这些字段是为
> Orin/T234 双 VI 服务的 —— 这是本路线在这块硬件上可行的物理前提。

**b) 控制消息 switch：两边各自补齐**

- `#if` 掉 R35 独有的 `CAPTURE_CSI_STREAM_TPG_APPLY_GAIN_{REQ,RESP}` 和
  `CAPTURE_HSM_CHANSEL_ERROR_MASK_{REQ,RESP}`（R32 消息集里不存在，
  转发过去会落到无关/保留 opcode）。
- **补回** R32 独有的 `CAPTURE_CHANNEL_TPG_{SETUP,START,STOP}_{REQ,RESP}`（0x30..0x35）——
  R32 出厂用户态认识这几条，R35 把它们删了。这是 R32 `capture.c` 原本就有的行为。

**c) 编译期断言（`static_assert`，文件作用域，`_Static_assert` 语义，保证真的被求值）**

```c
CAPTURE_CHANNEL_SETUP_REQ == 0x10
sizeof(struct capture_channel_config) == 216
sizeof(struct capture_descriptor)     == 704
offsetof(capture_descriptor, status)  == 624
offsetof(capture_descriptor, ch_cfg)  == 64
sizeof(struct CAPTURE_CONTROL_MSG)    <= 320   /* ivccontrol 帧长，实测 RX[64x320] */
```

**编译通过即证明 R32 布局真的生效了**，这是 A1c 点名要防的"R35 头悄悄漏回来"。
（我特意用 `static_assert` 而不是包在未调用 `static inline` 里的 `BUILD_BUG_ON` ——
后者在 5.10 上可能被优化掉、断言不生效。）

**d) 成功路径的 `dev_info`（关键诊断）**

R32 原码几乎全是 `dev_dbg`，失败时 dmesg 一片空白。这里在 setup 成功后无条件打印
`hw_channel_id / vi_channel_mask / queue_depth / request_size`。**部署后第一眼就看这行。**

**e) R32 reloc pass：`r32_reloc_vi_capture_request_buffers_locked()`**

替换 R35 的 `pin_vi_capture_request_buffers_locked()`（后者整段被 `#else` 保留，
关开关即原样回来）。语义：

1. 从用户态取 `reloc_relatives[]`（`req->reloc_relatives`，R35 的
   `struct vi_capture_req` 依然带这个字段，两边都是 16B）；
2. 每个 offset 处从描述符里读一个 u64 = `{低32=surface offset, 高32=nvmap handle}`；
3. `capture_common_pin_and_get_iova()` 把 handle pin 住，拿到 `iova + offset`；
4. **把 IOVA 就地写回描述符**（这就是 R32 固件真正会去读的地方）；
5. 循环结束后 `dma_sync_single_range_for_device(rtcpu_dev, requests.iova,
   request_offset, request_size, DMA_TO_DEVICE)`。

### 2.3 `0003` — ISP（`capture-isp.c`，+187 行）

同构：`#if` 掉 4 个 memoryinfo 字段赋值；新增
`r32_isp_reloc_request_buffers_locked()`，同时用在 **process 请求**（`req->isp_relocs`）
和 **program 请求**（`req->isp_program_relocs`）两条路径上；补 ISP 侧 `static_assert`
（`ISP_SETUP_REQ==0x20` / `capture_channel_isp_config==168` /
`isp_capture_descriptor==576`）。

ISP 特有的一处：reloc 目标可能位于**描述符环自身内部**（ISP pushbuffer 1/2 紧跟在
program/process 描述符后面）。R32 是拿嵌入的 handle 与"环自己的 handle"比较，相等则加上
本描述符的偏移。为此在 `struct isp_desc_rec` 里加了一个字段 `desc_mem`，在
`isp_capture_setup()` 里记下 `setup->mem` / `setup->isp_program_mem`。
这与 R35 自己对 `isp_pb1_mem` / `isp_pb2_mem` 写死的算术**完全一致**，只是推广到整个 reloc 表。

`isp_capture_setup_inputfences()` / `isp_capture_setup_prefences()` R35 原样保留 ——
逐行比对过，与 R32 相同，不需要动。

### 2.4 `0004` — NVCSI（`csi5_fops.c`，+16 行）

`csi5_tpg_set_gain()` 在 R32 下直接返回 `-EOPNOTSUPP`：
`CAPTURE_CSI_STREAM_TPG_APPLY_GAIN_REQ` 和整个 `..._GAIN_RATIO_*` 枚举是 R32 之后才有的，
**R32 固件没有这个 opcode**。这条只影响 NVCSI 测试图案发生器（`pg_mode`），
不在任何真实传感器采集路径上。

`csi5_fops.c` 其余部分**零改动**：核实过 NVCSI 消息族（0x40–0x4b）两边完全一致；
`nvcsi_error_config` 虽然字段名和尺寸不同（40 vs 56），但代码只 `memset(&err_config,0,...)`
后整块赋值，从不按字段访问 → 换头后自然变成 R32 的 40 字节布局，是正确的 R32 行为。

### 2.5 一处**功能删减**（唯一一处，必须让机主知道）

`CONFIG_VIDEO_TEGRA_VI_TPG`（`nvhost-vi-tpg.ko`，测试图案发生器）在
`CONFIG_TEGRA_CAPTURE_R32_ABI=y` 时被 Kconfig 关掉。

- **理由**：R35 的 `tpg_t19x.c` 只会编程 `union nvcsi_tpg_config.tpg_ng`
  （"下一代 TPG"），R32 的 union 里根本没有这个成员、R32 固件也没有这个功能。
  强行编过去只会往 R32 RCE 推一条畸形的 `CSI_STREAM_TPG_SET_CONFIG_REQ`。
- **影响评估**：基线 `lsmod` 与 `dmesg` 里**都搜不到 tpg**（本机从未加载）；
  它是纯测试驱动，不影响任何真实传感器通路。
- **代价**：模块包里少一个 `nvhost-vi-tpg.ko`。

---

## 3. 每处 API 适配的理由

### 3.1 `dma_buf_kmap()` / `dma_buf_kunmap()` —— 5.10 已删除

这是 A1b/A1c 都点名的"唯一真正需要重写的代码"。R32 的
`capture_common_request_pin_and_reloc()` 用它们逐页映射描述符。
5.10.216 树里 `include/linux/dma-buf.h` 与 `drivers/dma-buf/dma-buf.c` **都没有这两个符号**
（上游 v5.6 前后移除）。

**我的处理不是"改写 R32 的函数"，而是不需要它**：R35 的
`capture_common_pin_memory()` 在 pin 描述符环时已经做了整体
`unpin_data->va = dma_buf_vmap(buf)`（`capture-common.c:614`），
`struct capture_common_buf` 有 `va` 字段。所以 reloc pass 直接
`(uint8_t *)capture->requests.va + reloc_offset` 索引即可 —— **一次映射代替 N 次分页映射，
同样的字节**。顺带把 R32 的 `(void __iomem *)` 强转 + `__raw_readq/writeq` 换成
`READ_ONCE/WRITE_ONCE`：dma_buf vmap 出来的是普通内核虚拟地址，不是 MMIO，
R32 那样写是历史包袱。

### 3.2 `speculation_barrier()` / `arch_counter_get_cntvct()` / `soc/tegra/chip-id.h`

**一处都没碰到** —— 因为我没有搬 R32 的 .c 文件，用的是 R35 已经做过 5.10 适配的代码。
A1a 列的 11 处适配点在本方案下全部归零。

### 3.3 R32 头的 "r35 兼容附录"

R35 内核代码引用了几个 R32 头里没有的结构。附录里补了三个：
`memoryinfo_surface` / `capture_descriptor_memoryinfo` / `isp_capture_descriptor_memoryinfo`
（外加 `CAPTURE_IVC_ALIGN` / `CAPTURE_DESCRIPTOR_ALIGN` 别名和 `VI_UNIT_VI*` 宏）。

**这些永远不会被交给 R32 固件**：R32 的 `capture_channel_config` /
`capture_channel_isp_config` 没有 `requests_memoryinfo` 字段，固件根本不知道这些缓冲在哪。
内核仍然分配并填写它们（无害的私有 DMA 内存，且顺带保持 alloc/free 路径对称），
真正生效的是 reloc pass 写进描述符里的 IOVA。

### 3.4 保留的一个"多余"分配

R32 下 `vi_capture_setup()` / `isp_capture_setup()` 仍会
`dma_alloc_coherent()` 那块 memoryinfo 环形缓冲。这是**有意的**：
不动它，release/shutdown 的释放路径就完全不用改，`#if` 面积最小。
代价是每个通道多占几 KB DMA 内存。

---

## 4. 已部署垫片的处置（明确回答）

### 4.1 `NVMAP_CONFIG_HANDLE_AS_FD := y`（nvmap handle-as-fd 手术）→ **必须保留，不要动**

R32 用户态把 **nvmap handle 直接当 fd** 交给内核，reloc pass 里每一次
`capture_common_pin_and_get_iova()` 最终都会走到 `dma_buf_get(handle)`。
撤掉它，每一次 pin 都会 `-EBADF`，整条路径立刻死。
已核实源码树里 `nvidia/drivers/video/tegra/nvmap/Makefile.memory.configs:127`
仍是 `NVMAP_CONFIG_HANDLE_AS_FD := y`，本次构建包含它。

### 4.2 `build/capture-ioctl-compat/0001`（采集 ioctl 结构翻译垫片）→ **必须保留，且不冲突**

这一条与侦察 A1c 的判断**相反**，理由如下（A1c 的判断是针对"整体换文件"方案的，
在本方案下不成立）：

- 本方案**没有**把内核内部结构换成 R32。`struct vi_capture_setup`（`capture-vi.h`）
  仍是 R35 的 88 字节，`struct vi_capture_info` 仍是 48 字节。
- 而 chroot 里的 R32 用户态发的仍然是 40B / 40B。
- 所以 **ioctl 边界上的翻译依然是必需的**，它和固件线协议层是两个独立的层。
- 两者**没有重复翻译**：垫片只在 `_IOC_SIZE(cmd)` 上分流用户态 payload；
  线协议层只管内核 → 固件的消息构造。中间的内核结构是唯一的、R35 的。

**证据**：本次 patch 是基于"已含 capture-ioctl-compat 的源码树"生成的，
`capture-vi-channel.c` 的 diff 里只有我新增的 reloc 函数与调用点分流，
`vi_capture_setup_copy_from_user()` / `min_t` 截尾那几处**原封不动**；
`capture-isp-channel.c` **零改动**（patch 里根本没有这个文件）。

### 4.3 `build/rce-legacy-port`（legacy hsp 邮箱回移）+ `rce-chsetup-fix`（禁 diag@5）→ **保留**

两者都在 DTB 里，本次 DTB 未改（见 §5）。

---

## 5. DTB 五项铁律自检结果

产物 DTB：`out/tegra194-p3668-0001-p2151-0000.dtb`
（部署时改名为 `/boot-jp5/tegra194-mi-k91.dtb`）
反编译件：`out/dtb-decompiled.dts`（容器内 `scripts/dtc/dtc -I dtb -O dts`）

| # | 铁律 | 结果 |
|---|---|---|
| 1 | `diag@5` disabled | ✅ `diag@5 { ... status = "disabled"; }` |
| 2 | 热区 `map3` 出现 0 次 | ✅ `grep -c map3 = 0`（只有 map0×11 / map1×4 / map2×4 / map4×4） |
| 3 | `aonclk` 裁剪 | ✅ `aonclk { compatible="nvidia,tegra-aon-clks"; #clock-cells=<1>; status="okay"; }`，无悬空表项 |
| 4 | `adsp_audio` 禁用 | ✅ `adsp_audio { ... status = "disabled"; }` |
| 5 | legacy `hsp` okay + 四邮箱 | ✅ `hsp { compatible="nvidia,tegra186-hsp-mailbox"; mbox-names="cmd-rx\0cmd-tx\0ivc-rx\0ivc-tx"; status="okay"; }`；`hsp-vm1/2/3`、`hsp-cem` 均 disabled |

**更强的证据**：把新 DTB 与狗上正在跑的 `/mnt/emmcp1/boot-jp5/tegra194-mi-k91.dtb`
（sha256 `8da03287…`）双双反编译后 diff，**唯一差异是一行构建时间戳**：

```
< nvidia,dtbbuildtime = "Jul 24 2026\016:55:01";
> nvidia,dtbbuildtime = "Jul 25 2026\003:00:51";
```

→ **DTB 功能上完全一致，本次部署不需要、也不应该替换 DTB。**

---

## 6. 构建结果

```
KREL      = 5.10.216-tegra                (full-build.sh 断言通过)
VERMAGIC  = 5.10.216-tegra SMP preempt mod_unload modversions aarch64
Image     f4b6a0351ea1a251fb07221e3f76743597e3ea454d4f34dd21e8ca2502a3fbd1
DTB       dcca14637be3086ebebb44c7c01b78010240ff279236aa84396f9542d14aac59
modules   ab3dbdb6cd42bf77a765f186ac639bcb978b6346d74e784b847044980749a816
8821cu.ko 7f5d820921fe8dee4553ded41528d486fd7a11774bfb70f280382c95bec7e812
```

- **C 侧 warning：0**（该构建带 `-Werror`；`camera/Makefile` 与 `fusa-capture/Makefile`
  都有 `ccflags-y += -Werror`，能编过就说明零告警）。
- 构建日志里 12 条 warning 全部是 `t23x/prometheus` 平台 DTS 的 `CAM0_PWDN` 宏重定义，
  **与本次改动无关、构建前就有**（那是 Orin 的 dtsi，本机不用）。
- **额外做了反向验证**：把 `.config` 里的开关改成 `# CONFIG_TEGRA_CAPTURE_R32_ABI is not set`
  后重编 `drivers/media/platform/tegra/` + `drivers/video/tegra/`，同样零 error 零 warning。
  → **开关两个方向都能构建**，回滚路径是活的。
- **patch 可复现性已验证**：把 `pristine/` 复制一份、依次 `patch -p1` 应用 0001..0004，
  与当前源码树逐文件 `cmp` → **字节级一致**。

---

## 7. 部署说明（给主控）

### 7.1 改动编进 Image 还是 .ko？

**全部在 Image 里。** `CONFIG_TEGRA_CAMERA_RTCPU=y`、`CONFIG_VIDEO_TEGRA_VI=y`、
`CONFIG_TEGRA_GRHOST=y` —— fusa-capture / vi5 / isp5 / nvcsi 全是内建。
**没有 .ko 级热插拔可用，回滚粒度就是整个 Image。**

### 7.2 要换哪些文件

| 文件 | 动作 |
|---|---|
| `/mnt/emmcp1/boot-jp5/Image` | **换**（先 `cp Image Image.prev-r32capture`） |
| `/mnt/emmcp1/boot-jp5/tegra194-mi-k91.dtb` | **不换**（功能等价，见 §5） |
| `/mnt/emmcp1/boot-jp5/initrd` | **不换**（内核接口无变化；但若按惯例重跑 `tools/phase4/build-jp5-initrd.sh`，注意 full-build 已清空 `out/final`） |
| `/lib/modules/5.10.216-tegra/` | **换**（vermagic 相同，但模块与 Image 必须同批；注意 `nvhost-vi-tpg.ko` 这次不再存在） |
| `/lib/modules/.../extra/8821cu.ko` | 按既有部署脚本处理 |

引导入口已确认：eMMC `/dev/mmcblk0p1`（挂在 `/mnt/emmcp1` 与 `/mnt/emmc`）的
`/boot/extlinux/extlinux.conf`，`DEFAULT jp5` → `LINUX /boot-jp5/Image`。
rootfs 上的 `/boot/extlinux/extlinux.conf` 是幌子。

### 7.3 部署顺序（**这一段是硬性的，不是建议**）

1. **先禁掉相机自启**：`sudo systemctl disable --now nvargus-daemon`，
   并停掉 `camera_server`（`/opt/ros2/cyberdog/lib/athena_camera/maincamera`）。
   现场实测 `nvargus-daemon` 目前 `enabled` 且 `active`。
   最可能的失败模式是良性的（probe 成功、系统正常、只是不出图）；
   **危险模式是 ioctl 路径 oops / SMMU fault**，而开机自启会主动把系统推进那条路径。
2. 备份：`sudo cp /mnt/emmcp1/boot-jp5/Image /mnt/emmcp1/boot-jp5/Image.prev-r32capture`
3. 在 extlinux.conf 里**新增**（不改 `DEFAULT`）一个 `LABEL jp5-prev` 指向
   `Image.prev-r32capture`，这样串口控制台一条路径就能回到"能跑的 JP5"，
   而不是被 autorevert 一路打回 JP4（丢掉音频/Wi-Fi/温控全套成果）。
4. 换 Image + 模块 → reboot（**机主在场**）
5. 跑 A 层红线：`build/baseline-2026-07-25/verify-after-deploy.sh`，任一失败**立刻回滚**
6. A 层全过后，才手动 `systemctl start nvargus-daemon` 做第一次采集尝试

现成回滚点（都在狗上）：
`Image.prev-dbatch`（= 当前运行的上一版）、`Image.prev-handlefd`、`Image.prev-legacy`。

### 7.4 验证顺序

**A 层 · 红线不回归**（沿用 `build/baseline-2026-07-25/verify-after-deploy.sh`）

`ls /dev/video* | wc -l` = 9 · `ls /dev/v4l-subdev* | wc -l` = 6 ·
`/sys/class/video4linux/video3/name` 含 `RealSense` ·
`readlink /sys/devices/platform/tegra-capture-vi/driver` 指向 `tegra-camrtc-capture-vi` ·
`lsmod` 里 nvgpu 在 / nvmap Used-by ≥1 / `snd_soc_rt5680` 在 ·
热区数 ≥6 · `dmesg | grep -c "Unhandled context fault"` = 0 ·
`dmesg | grep -ciE "Call trace|Unable to handle kernel"` = 0

**B 层 · 回移确实装上了**

- `dmesg | grep "firmware version cpu=rce"` 仍是 `cmd=5 sha1=cf2bef3a…`
- `dmesg | grep -c "ivc-bus:"` = 5，`grep -c "ivc-bus:diag@5"` = 0
- `/dev/capture-vi-channel*` = 36，`/dev/capture-isp-channel*` = 64

**C 层 · 成败判据（新增的一手信号）**

```
dmesg | grep "r32-abi:"
```
- 出现 `r32-abi: VI channel setup accepted: hw_channel_id=... vi_channel_mask=0x...`
  → **0x10 握手成功，控制面通了**，这就是本次工程的胜负手。
- 出现 `r32-abi: ISP channel setup accepted: ...` → ISP 侧同上。

V4L2 直采探针（不需要 chroot，最干净）：
```
v4l2-ctl -d /dev/video0 --set-fmt-video=width=640,height=480,pixelformat=BG10 \
         --stream-mmap --stream-count=10 --stream-to=/dev/null
```
（video0/1 = ov7251 BG10 640×480；video2 = ov13b10 RG10 4208×3120，先用小的）
这条路径现在也说 R32 方言（`capture_descriptor` 已是 704B 的 R32 布局，`vi5_fops.c`
一个字都没改就自动对了）。**出帧 = 内核↔固件那一半通了。**

然后才是 chroot 内 `nvargus-daemon` + `argus_camera`。

**故障分诊表**

| 现象 | 判定 | 下一步 |
|---|---|---|
| 无 `r32-abi:` 行 + `-ETIMEDOUT` | 消息发出去了、固件没回 | 检查是否真的 0x10（`static_assert` 已挡住编译期错误，所以更可能是 IVC 层） |
| 无 `r32-abi:` 行 + `-EINVAL/-EFAULT/-ENOMEM` | 驱动侧问题，没走到 IVC | 看 pin 的 `dev_err`；确认 handle-as-fd 没被误撤 |
| 有 `r32-abi:` 行，但 STATUS 超时 + `arm-smmu Unhandled context fault` | 控制面通了、每帧面 IOVA 写错位置 | 看 reloc pass 的越界/NULL handle 报错；确认 `dma_sync` 没漏 |
| 有 `r32-abi:` 行，ioctl 全 0，syncpt 不涨 | 与采集 ABI 无关，传感器/NVCSI 侧 | nvcsi debugfs / cil settletime |

---

## 8. 诚实的把握度评估：**35–45%**

### 已经**证明**的（不是推断）
- R32 布局全局生效（6 条文件作用域 `static_assert` 编译通过 = 数学证明）
- 消息号 0x10、`capture_channel_config` 216B、`capture_descriptor` 704B、
  `status@624`、`ch_cfg@64`、`isp_config` 168B、`isp_descriptor` 576B —— 全部就位
- 控制消息 280→264 字节仍然装得进 320 字节的 ivccontrol 帧（实测 `RX[64x320]`）
- 零 warning 编过，开关两个方向都能编，patch 字节级可复现
- DTB 五项铁律全过，且与运行中的 DTB 功能等价
- D455 与本次改动**零交集**（uvcvideo + xhci，IOMMU group 1；VI=20 / ISP=19 / RCE=4）

### 仍然**不知道**的（按危险程度排序）

1. **GoS 表退化为空 —— 头号未知数，本轮没能证伪。**
   R35 的 `capture-support.c` 把 `capture_get_gos_table()` 改成直接返回
   `count=0/table=NULL`，`nvhost_syncpt_get_gos()` 这个符号在 R35 的 `nvhost.h` 里
   **根本不存在**。于是 `vi_capture_setup()` 会给固件下发 `num_vi_gos_tables = 0`。
   缓解论据：R32 代码本身把 `gos_index` 初值设成 `GOS_INDEX_INVALID` 并容忍失败，
   `nvhost_syncpt_address()`（shim 地址）仍有效，GoS 只是 syncpt 读取的加速路径。
   **但这是推断，不是实测。** 侦察建议的"先在 JP4 侧确认 `num_vi_gos_tables` 实际是不是 0"
   我没做（需要在 JP4 引导下取证，超出本轮只读授权）。
   如果 R32 固件把 `num_vi_gos_tables==0` 当作硬错误，SETUP 会直接失败。

2. **R32 固件是否只认消息号和结构尺寸，还是还有别的隐含约定。**
   我把"线协议"归结为消息号 + 结构布局 + 每帧内存模型三件事，这个归结是从源码对比得出的，
   但固件是二进制黑盒。可能还有别的握手细节（比如某个字段的取值域、某个消息的时序要求）
   在两版之间变了而源码看不出来。

3. **reloc 语义的细节。** R32 的 reloc 表由用户态给出，我按 R32 源码逐行还原了
   "读 u64 → 拆 {offset, handle} → pin → 写回 IOVA"。但 R32 用的是
   `capture_common_pin_memory()`（每次新 attach），我用的是 R35 的 refcount 缓存表
   `capture_common_pin_and_get_iova()`。**IOVA 值应当相同**（同一 device、同一 dma_buf），
   但生命周期语义不同（R35 的映射跨帧缓存）。理论上更好，实际未验证。
   另外我加了 R32 没有的 `num_relocs <= MAX_PIN_BUFFER_PER_REQUEST(24)` 上限和 8 字节
   对齐/越界检查 —— 如果真实 relocs 超过 24 个，会被我拒掉（R32 无此限制）。
   **这是一个可能的新增失败点**，若日志里出现 `too many relocs` 就是它。

4. **ISP 侧完全没有独立验证手段。** VI 侧还有 V4L2 直采可以当探针；ISP 只有 libargus
   一条路。而 ISP 的 SETUP 消息号两边都是 0x20 —— 布局错了固件不会报错，会静默乱解析。
   我用 `static_assert` 把布局钉死了，但"钉死的是 R32 布局"和"R32 固件按 R32 布局解析"
   之间还差一个实测。

5. **`nvargus` / libargus 是否还有别的 ABI 面没打通。** 前面已经打赢了 nvmap handle-as-fd、
   ioctl 结构翻译、diag@5、legacy hsp 四仗，每一仗后面都还有一堵墙。
   这次不出图的话，下一堵墙大概率在"传感器上电/NVCSI stream 参数"或者 libargus
   自己的用户态假设上。

### 为什么是 35–45% 而不是更高

因为**已知未知数还有 5 个，其中第 1 个（GoS）是本轮明确没能消除、且能一票否决的**。
本方案把"内核和固件之间的 ABI"这一层做到了我能静态证明的极限 —— 布局、消息号、
内存模型三件事全部对齐并有编译期证据。但这条链路上还有固件黑盒行为和用户态假设两段
我无法在 Mac 上验证。

### 为什么值得部署

- 风险面**极小**：纯增量、开关可关、Image 级一键回滚、DTB 不动、D455 物理隔离、
  nvgpu 零交集（fusa-capture 只导出 8 个符号，全树只有 4 个消费者，nvgpu 一个都不引用）。
- 信息价值**极大**：`r32-abi: VI channel setup accepted` 这一行会一次性回答
  "0x10 到底能不能过"这个悬了三天的问题。哪怕不出图，卡点也会从"控制面"前移到"每帧面"
  或"传感器面"，那是完全不同的、更靠近终点的战场。

---

## 9. 没做完 / 明确不做的

1. **JP4 侧 GoS 取证**（`num_vi_gos_tables` 实际值）—— 需要在 JP4 引导下抓，本轮没做。
   这是最该补的一件事。
2. **V4L2 直采的"改前对照基线"** —— 需要给传感器上电起流，超出本轮只读授权。
   没有这个对照，部署后即使 V4L2 出图也少一半说服力（不过基线 dmesg 里从无采集痕迹，
   可以间接推定当前不出图）。
3. **`/sys/kernel/debug/camrtc/` 固件 trace 是否可读** —— 未验证。这是唯一能证明
   "固件收到并**认识**了这条消息"的一手证据，失败排查会严重依赖它。
   dmesg 里 `camchar: rtcpu character device driver loaded` 已在。
4. **TPG 模块** —— 有意关闭，见 §2.5。
5. **initrd** 未重新生成（本次不需要；若主控按惯例重跑 `build-jp5-initrd.sh`，
   注意 `full-build.sh` 会先清空 `out/final`）。

---

## 10. 回滚步骤

**软回滚（不部署，只是把源码树恢复原状）**
```
cd build/src/Linux_for_Tegra/source/public/kernel_src/kernel
patch -p1 -R < .../0004-*.patch
patch -p1 -R < .../0003-*.patch
patch -p1 -R < .../0002-*.patch
patch -p1 -R < .../0001-*.patch
# 或直接从 build/r32-capture-backport/pristine/ 覆盖回去
# （pristine/ 的基线 = R35 + capture-ioctl-compat + nvmap handle-as-fd + rce-legacy-port）
```

**一行回滚（保留 patch，只是不生效）**
删掉 `athena_defconfig` 里的 `CONFIG_TEGRA_CAPTURE_R32_ABI=y` 后重编。
预处理结果与 NVIDIA 原版逐字节相同 —— 这一点已用"关掉开关重编、零 error 零 warning"验证过。

**狗上回滚**
```
sudo cp /mnt/emmcp1/boot-jp5/Image.prev-r32capture /mnt/emmcp1/boot-jp5/Image
# 或用现成的 Image.prev-dbatch（= 部署前正在跑的那一版，sha 2f8f2552…）
sudo reboot
```
模块目录同批换回（`/lib/modules/5.10.216-tegra` 的上一份备份）。

---

## 11. 文件清单

```
build/r32-capture-backport/
├── 0001-camrtc-r32-abi-headers-and-kconfig-switch.patch     +2392 -0
├── 0002-fusa-capture-vi-r32-setup-message-and-reloc-pass.patch  +214 -0
├── 0003-fusa-capture-isp-r32-setup-message-and-reloc-pass.patch +187 -0
├── 0004-nvcsi-r32-drop-tpg-apply-gain.patch                    +16 -0
├── NOTES.md                        （本文件）
├── pristine/                       （改前原件，12 个文件）
├── r32src/                         （从 mirror 取出的 R32 参考源码，只读参考）
└── out/
    ├── Image                       f4b6a035…
    ├── tegra194-p3668-0001-p2151-0000.dtb   dcca1463…（功能等价于运行中的 8da03287…）
    ├── dtb-decompiled.dts          （铁律自检用）
    ├── modules-5.10.216-tegra.tar.gz
    ├── modules/8821cu.ko
    ├── SHA256SUMS
    └── VERMAGIC
```

**patch 应用位置**：`build/src/Linux_for_Tegra/source/public/kernel_src/kernel/`，`patch -p1`。
（路径前缀是 `nvidia/...` 和 `kernel-5.10/...`。）

**基线声明**：这些 patch 的 `pristine/` 基线是**已经打了**
`capture-ioctl-compat/0001`、`nvmap-handle-fd/0003`、`rce-legacy-port/0001`、`rce-chsetup-fix`
的源码树。不要在干净的 NVIDIA r35.6.4 上直接应用。
