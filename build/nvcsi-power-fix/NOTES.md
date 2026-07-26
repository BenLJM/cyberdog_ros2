# NVCSI 上电/时钟时序修复 — 分析 + 补丁

**日期**：2026-07-26
**任务**：AI 头顶相机（ov13b10）走 argus 真实采集路径时 RCE 崩在
`rce-noc / Host read timeout at address 303cc (0x15a303cc)`，追 NVCSI 上电时序。
**产物**：`patches/0001..0004` + `new/`（新增 dtsi）+ `pristine/`（改前原件）
**状态**：**补丁已产出并通过 DTB 编译验证，但已从共享源码树回退（未构建内核、未部署）。**

---

## 0. 一句话结论

**NVCSI 所在的 `ve` 电源域在 JP5 上是永久断电的、且挂在它下面的设备数量是 0，
`nvcsi`/`nvcsilp` 时钟 enable_cnt 全 0。**
R35 把「谁给 VI/ISP/NVCSI 上电」这件事整体从内核挪进了 RCE 固件；
我们跑的是**不可刷写的 R32 固件**，它不会自己上电，它假定内核已经上好了。
所以 RCE 一碰 NVCSI 寄存器就撞到死总线 → NOC 读超时。

**把握度：70–80% 能消掉这次 NOC 崩溃**；能不能直接出图另说（见 §6 Stage 2）。

---

## 1. `0x15a303cc` 到底是什么寄存器

`nvcsi@15a00000`，`reg` 长度 `0x50000`（R32 soc-base 原文）。偏移 = **`0x303cc`**。

NVCSI 的地址布局（三处独立证据互相印证）：

| 证据 | 内容 |
|---|---|
| `nvcsi-t194.c`（R32） | `PHY_OFFSET 0x10000`，`CIL_A_SW_RESET 0x11024`，`CIL_B_SW_RESET 0x110b0` |
| `csi5_registers.h`（R32/R35 都有） | `CSI5_TEGRA_CSI_STREAM_0_BASE 0x10000` / `_STREAM_2_BASE 0x20000` / **`_STREAM_4_BASE 0x30000`** |
| 狗上活 DT `nvcsi/prod-settings/prod` | 偏移表 `0x11018 / 0x21018 / 0x31018 / 0x41018`，步长 0x10000，共 4 个 PHY brick |
| `deskew.c`（R32 t194 表） | `STREAM_0_ERROR_STATUS2VI_MASK 0x101e4`、`STREAM_1_... 0x181e4`、`PHY_0_CILA_INTR_STATUS 0x10400`、`PHY_0_CIL_PHY_CTRL_0 0x11000` |

推出的 brick 内部布局：
```
brick_n 基址 = 0x10000 * (n+1)          n = 0..3  (A/B, C/D, E/F, G/H)
  +0x0000 .. +0x03ff   NVCSI_STREAM_(2n)   偶数 stream 寄存器页（1 KiB）
  +0x0400 .. +0x07ff   PHY_n CIL_A 中断页
  +0x0800 .. +0x0bff   PHY_n CIL_B 中断页
  +0x1000 ..           CIL_PHY_CTRL / CIL_A / CIL_B 配置（SW_RESET=+0x1024/+0x10b0）
  +0x8000 .. +0x83ff   NVCSI_STREAM_(2n+1) 奇数 stream 寄存器页
```

⇒ **`0x303cc` = brick #2（CSI brick C/D）+ `0x3cc` = `NVCSI_STREAM_4` 寄存器页内偏移 0x3cc。**

**这正是 AI 相机那一路。** 狗上活 DT：
```
/proc/device-tree/host1x@13e00000/nvcsi@15a00000/channel@2/ports/port@0/endpoint@4/port-index = 4
```
（ov13b10 在 R32 的 `tegra194-camera-ov13b10.dtsi` 里就是 `port-index = <4>; bus-width = <4>`，
4 lane 挂 brick C。）

> ⚠️ 诚实边界：**寄存器的具体名字**（stream 页 +0x3cc 叫什么）在 R32/R35 两棵树的公开
> 头文件里都没有——NVIDIA 只在 `deskew.c`/`csi5_registers.h` 里散落了十几个偏移，
> 完整的 NVCSI 寄存器 spec 只在 T194 TRM 里。**但这不影响判断**：NOC 的
> "Host read timeout" 不是"值不对"，是"目标根本没应答"，任何偏移都一样。
> 关键信息是 **哪个 brick**（=哪路相机），而这一点是确定的。

---

## 2. 谁给 NVCSI 上电 —— R32 vs R35 的分水岭

### 2.1 DT 层（`tegra194-soc-base.dtsi`）

| 节点 | R32（athena 真源码树） | R35（我们在跑的） |
|---|---|---|
| `nvcsi@15a00000` | `reg` + **`power-domains = VE`** + **`resets = NVCSI`** + clocks **`nvcsi, nvcsilp`** + `interrupts` + `num-ports=6` | **只有 `clocks = <nvcsi>`**，别的全没了 |
| `vi@15c10000` | `reg` + **`power-domains = VE`** + `resets = VI, TSCTNVI` + clocks `vi, vi-const, nvcsi, nvcsilp` | `reg` + `clocks = <vi>`，无 power-domains / resets |
| `vi-thi@15f00000` | `reg` + **`power-domains = VE`** + clocks `vi, vi-const` | **只有 compatible** |
| `isp@14800000` | `reg` + **`power-domains = ISPA`** + `resets = ISP` | 无 reg / 无 power-domains / 无 resets |

### 2.2 驱动层

`rtcpu` 节点两代都写着 `nvidia,camera-devices = <&isp &vi &nvcsi>`，
但**只有 R32 真的用它**：

```
R32  drivers/platform/tegra/rtcpu/device-group.c
       camrtc_device_group_busy()  -> nvhost_module_busy(isp/vi/nvcsi)
       camrtc_device_group_idle()  -> nvhost_module_idle(...)
       camrtc_device_group_reset() -> nvhost_module_reset(..., false)
R32  drivers/platform/tegra/tegra-camera-rtcpu.c
       runtime_resume()  : camrtc_device_group_busy()  再 tegra_camrtc_boot()
       runtime_suspend() : camrtc_device_group_idle()
       poweron()         : camrtc_device_group_reset() 在 deassert_resets 之前
```

**R35 把这三个函数的定义整个删了**（`device-group.h` 里还留着声明，`device-group.c` 只剩
140 行，到 `camrtc_device_get_byname` 就结束），`tegra-camera-rtcpu.c` 里三处调用也一并删掉。

同样被删的还有 `nvcsi-t194.c` 的一大半（R32 500 行 → R35 245 行）：
`ioremap` NVCSI aperture、`nvcsi_apply_prod()`、`tegra_csi_mipi_calibrate()`、
`tegra194_nvcsi_finalize_poweron/prepare_poweroff`、`tegra194_nvcsi_cil_sw_reset()`、
deskew debugfs —— **全部移交给 R35 的 RCE 固件自己通过 BPMP 干**。

以及 `t194.c` 的设备描述：

| 字段 | R32 `t19_nvcsi_info` | R35 |
|---|---|---|
| clocks | `nvcsi 400M` + **`nvcsilp 204M`** | 只有 `nvcsi 400M` |
| `finalize_poweron` / `prepare_poweroff` | 有（prod + MIPI cal） | 无 |
| `poweron_reset` / `keepalive` | true / true | 无 |

`t19_vi5_info` 同样：R32 有 `vi, vi-const, nvcsi, nvcsilp` 四个时钟 + `keepalive` +
`poweron_reset`，R35 只剩 `vi` + `emc`。

---

## 3. 上机取证（只读，未触发采集，未重启栈）

```
$ ssh mi@10.0.0.219 'sudo cat /sys/kernel/debug/pm_genpd/pm_genpd_summary'
   ...
   ve                              off-0           <-- 下面一个设备都没有
   sax                             off-0
   ...
   ispa                            off-0           <-- 下面一个设备都没有
```
对照组：同一份输出里 `nvdecb / nvenca / vic / pvaa …` 每个域下面都列着
`/devices/platform/13e10000.host1x/...  suspended`。**`ve` 和 `ispa` 是空的。**
=> 内核里**没有任何设备**能把这两个域唤醒，它们永远是断电的。这是结构性事实，
不需要"跑一次 argus 再看"来确认。

```
$ grep -iE 'nvcsi|mipi' /sys/kernel/debug/clk/clk_summary
    pll_nvcsi          0  0  0  942000000
       nvcsi           0  0  0  314000000      <-- enable_cnt=0 prepare_cnt=0
    mipi_cal           0  0  0   19200000
       nvcsilp         0  0  0  204000000      <-- enable_cnt=0 prepare_cnt=0
```

```
$ ls /proc/device-tree/host1x@13e00000/nvcsi@15a00000/
#address-cells  channel@0  channel@1  channel@2  clock-names  clocks
compatible  name  num-channels  phandle  prod-settings  #size-cells
   -> 没有 reg / 没有 power-domains / 没有 resets / 没有 interrupts
$ cat .../clock-names        -> "nvcsi"（只有一个）
$ ls /sys/devices/platform/13e10000.host1x/ | grep nvcsi
   13e10000.host1x:nvcsi@15a00000     <-- 冒号命名 = 该节点没有 reg
$ cat /sys/devices/platform/13e10000.host1x/15c10000.vi/power/runtime_status
   suspended
```

**结论**：RCE 去读 `0x15a303cc` 的那一刻，NVCSI 处在
「VE 域断电 + nvcsi/nvcsilp 时钟未使能 + NVCSI reset 未由内核释放」的状态。
NOC 读超时是这三者中任意一个的必然结果。

---

## 4. 修法（Stage 1，本目录的补丁）

严格按 R32 的契约恢复，**全部包在 `CONFIG_TEGRA_CAPTURE_R32_ABI` 里**
（该开关已在 `athena_defconfig:357` = y，和 `build/r32-capture-backport/` 同一个门），
`=n` 时预处理结果与 NVIDIA 原版逐字节相同。

| 补丁 | 文件 | 改法 |
|---|---|---|
| `0001` | `hardware/.../jakku/kernel-dts/tegra194-p3668-0001-p2151-0000.dts` | 末尾 `#include "tegra194-mi-k91-camera-power.dtsi"`（放在 rtcpu-legacy 之后） |
| （新文件） | `new/.../tegra194-mi-k91-camera-power.dtsi` | `&nvcsi` 加 `power-domains=VE / resets=NVCSI / clocks=nvcsi,nvcsilp`；`&vi` 加 `power-domains=VE / resets=VI,TSCTNVI / clocks=vi,vi-const,nvcsi,nvcsilp`；`&vi_thi` 加 `power-domains=VE / clocks=vi,vi-const`；`&isp` 加 `power-domains=ISPA / resets=ISP` |
| `0002` | `kernel/nvidia/drivers/platform/tegra/rtcpu/device-group.c` | 把 R32 的 `camrtc_device_group_busy/idle/reset` **逐字原样**补回（R35 头文件里声明还在，是 NVIDIA 自己留的空壳） |
| `0003` | `kernel/nvidia/drivers/platform/tegra/tegra-camera-rtcpu.c` | `runtime_resume` 里 boot 前 `..._busy()`、失败回滚 `..._idle()`；`runtime_suspend` 里 `..._idle()`；`tegra_camrtc_poweron()` 里 deassert_resets 之前 `..._reset()` —— 位置与 R32 完全一致 |
| `0004` | `kernel/nvidia/drivers/video/tegra/host/t194/t194.c` | `t19_nvcsi_info` 加 `nvcsilp 204MHz` + `poweron_reset` + `keepalive`；`t19_vi5_info` 加 `vi-const / nvcsi / nvcsilp` |

**故意没做的事**：没有给 `nvcsi` / `isp` 加回 `reg`。加 `reg` 会把 platform device
改名（`13e10000.host1x:nvcsi@15a00000` → `15a00000.nvcsi`），是 Stage 2 才需要的
（内核侧 prod settings 要 ioremap 才能写）。Stage 1 只解决供电/时钟/复位。

### 应用方法（主控在 E 批次统一构建时执行）

```bash
SRC=/Users/ben/projects/cyberdog/build/src/Linux_for_Tegra/source/public/kernel_src
FIX=/Users/ben/projects/cyberdog/build/nvcsi-power-fix
cp $FIX/new/hardware/nvidia/platform/t19x/jakku/kernel-dts/tegra194-mi-k91-camera-power.dtsi \
   $SRC/hardware/nvidia/platform/t19x/jakku/kernel-dts/
cd $SRC && for p in $FIX/patches/*.patch; do patch -p1 < "$p"; done
# 回退： for p in $(ls -r $FIX/patches/*.patch); do patch -R -p1 < "$p"; done
#        rm $SRC/hardware/.../tegra194-mi-k91-camera-power.dtsi
```

---

## 5. 已做的验证（实测，不是推理）

1. **四个补丁在真树上 `patch -p1 --dry-run` 全部干净应用**（无 fuzz、无 offset）。
2. **DTB 真编译过**：`make -j6 O=/tmp/kb dtbs` rc=0，产出
   `tegra194-p3668-0001-p2151-0000.dtb`，反编译核对：
   - `nvcsi`: `clocks = <0x04 0x51 0x04 0x52>`（81=NVCSI, 82=NVCSILP）、
     `power-domains = <0x04 0x0c>`（12=VE）、`resets = <0x04 0x2b>`（43=NVCSI）✓
   - `vi`: clocks `0xa6/0xc4/0x51/0x52`（166 VI,196 VI_CONST,81,82）、
     `power-domains 0x0c`、`resets 0x70 0x61`（112 VI,97 TSCTNVI）✓
   - `vi-thi`: `power-domains 0x0c` + `vi/vi-const` ✓
   - `isp`: `power-domains 0x05`（5=ISPA）+ `resets 0x24`（36=ISP）✓
3. **与当前部署中的 DTB 逐行 diff**：除 buildtime 外，我的改动**只落在这 4 个节点**，
   26 行增删，没有任何其它节点被动到。DTB 五铁律复核：`map3` 出现 0 次、
   `diag@5` disabled、legacy hsp 四邮箱在、aonclk 两条在。
4. **改动已从共享源码树完全回退**，`/tmp/kb` 里的 DTB 也重新编译回未修改版本，
   E 批次不会被我夹带。

> ⚠️ **未做**：没有编译内核 Image（任务禁止），所以 `0002/0003/0004` 三个 C 补丁
> **只做了人工核对 + API 签名核对，没有真编译过**。核对项：
> `nvhost_module_busy/idle/reset` 在 R35 `include/linux/nvhost.h:470-473` 签名一致；
> `NVHOST_MODULE_MAX_CLOCKS = 8`（nvcsi 1→2、vi 2→5，都不溢出）；
> `device-group.c` 已经 `#include "drivers/video/tegra/host/nvhost_acm.h"`；
> `rtcpu->camera_devices` 字段在 R35 `tegra-camera-rtcpu.c:235` 存在。
> **E 批次第一次构建时要盯 `-Werror`。**

---

## 6. Stage 2（如果 Stage 1 消掉了 NOC 超时但仍然没有图像）

R32 内核在 NVCSI 上电后还干了两件 R35 内核完全不干的事，
这两件不会造成 NOC 超时，但会造成 **PHY 不锁 / 无帧 / CSI 错误**：

1. **prod settings**：`nvcsi-t194.c: nvcsi_apply_prod()`
   → `tegra_prod_set_by_name(&nvcsi->io, "prod" / "prod_c_dphy_mode", ...)`。
   DT 里那张 `prod-settings` 表（`0x11018…0x410b8`，我们的 DTB 里**已经有**）
   现在**没有任何人去写它**。
2. **MIPI 校准**：`tegra_csi_mipi_calibrate(&nvcsi->csi, true)`。
   R35 仍然保留了 `drivers/media/platform/tegra/mipical/mipi_cal.c` 和
   `tegra_csi_mipi_calibrate()`（`camera/csi/csi.c:1087`），只是 nvcsi 不再调它。

R32 的关键**顺序**（`tegra194_nvcsi_finalize_poweron` 里的原话注释）：
> "rtcpu resets nvcsi registers, so we set prod settings **after** rtcpu has
> finished resetting the registers, which happens during rtcpu's poweron call"

即：**必须等 `tegra_camrtc_is_rtcpu_powered()` 为真之后**才写 prod，否则被 RCE 覆盖。
R32 用 `kthread_run(nvcsi_prod_apply_thread)` + 125ms 轮询实现。

Stage 2 需要：
- DT：给 `&nvcsi` 加回 `reg = <0x0 0x15a00000 0x0 0x00050000>`（注意会改设备名）
- `nvcsi-t194.c`：回移 `ioremap` + `prod_list` + `nvcsi_apply_prod` +
  `nvcsi_prod_apply_thread` + `finalize_poweron/prepare_poweroff`
- `t194.c`：`.finalize_poweron/.prepare_poweroff` 指回去

**建议先只上 Stage 1**，看 dmesg 里 `r32-abi: ... setup accepted` 标记是否出现、
`rce-noc` 是否消失，再决定要不要 Stage 2。这样出问题时归因是单一的。

---

## 7. 风险与回滚

| 风险 | 评估 | 缓解 |
|---|---|---|
| DTB 与 Image 不配套部署 | **低危**：`nvhost_module_init()` 找不到时钟只 `dev_err` 后 `continue`（`nvhost_acm.c:910`），不是致命 | 仍应两者同批部署 |
| 给 `&vi` 加 `power-domains` 后 VI 反而起不来 | 相机链现在本来就是死的，无回归空间；但 VI 也被 `tegra-capture-vi` 用 | 回滚 = 撤 4 个补丁重编 |
| `.keepalive`/`.poweron_reset` 让 NVCSI 常驻不下电 | 功耗上升（VE 域），热管理已根治过，可接受 | 需要的话去掉 `keepalive` 单项 |
| VE 域上电后 RCE 与内核抢 NVCSI 寄存器 | R32 原本就是这个并发模型（RCE 复位寄存器 → 内核后写 prod），我们只是恢复它 | — |
| 我的 C 补丁没真编译过 | **中危** | E 批次首次构建盯 `-Werror` |

**回滚件**：`pristine/` 是四个被改文件的改前原件（与共享树当前状态逐字节一致）。

---

## 8. 顺手发现的、和本任务无关但要报的事

`build/src/.../jakku/kernel-dts/common/tegra194-p2151-0000.dtsi`
的 mtime 是 **2026-07-26 11:30**（我这次作业开始之后），内容把
`synaptics_dsx@20` 从 `status="disabled"` 改成了 `"okay"`，
并改了 `synaptics,irq-gpio` 的 flag（`0x2002`→`0x2008`，IRQF_ONESHOT|TRIGGER_LOW）、
加了 `synaptics,cap-button-codes`。

**这是别的并发 agent 正在编辑共享源码树**，不是我改的，我也没有回退它。
但它意味着：**E 批次统一构建出来的 DTB 会顺带把触摸板节点点亮**。
主控如果不知情，需要确认这是有意为之。
（我这边验证时的 DTB diff 已经把这条隔离出来了，见 §5.3。）
