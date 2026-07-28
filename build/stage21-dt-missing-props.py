#!/usr/bin/env python3
"""Stage-21：补回出厂 DTB 里有、我们缺的三个相机节点属性（纯 DTB 改动）。

内核侧已用 R32.5.2 官方源逐函数比对完毕、还原完整，于是转去逐节点比对 DTB。
把出厂 `tegra194-mi-k91.dtb` 与运行时 `/proc/device-tree` 的属性集合做差，
在**关键节点**上找到三处缺失：

| 节点 | 出厂有、我们缺 | 出厂值 |
|---|---|---|
| `nvcsi@15a00000` | `interrupts` | `<0x00 0x77 0x04>` |
| `nvcsi@15a00000` | `num-ports`   | `<0x06>` |
| `isp@14800000`   | `reg`         | `<0x00 0x14800000 0x00 0x10000>` |

（clocks / resets / power-domains / prod 的**值**两边逐字节一致，已核对；
 `rtcpu` 的 `nvidia,camera-devices` 也在，指向 isp/vi/nvcsi 三个设备。）

R32 的**内核驱动**不读 `num-ports`，也不 `platform_get_irq()` ——
但这些属性会随 DT 一起被 RCE 侧看到（`nvidia,camera-devices` 指过去的就是这些节点），
而 R32 固件正是靠自己解析这些节点来接管硬件的。ISP 的 `reg` 更是与当年
nvcsi 的情况完全平行：R35 因为"RCE 自己管"把 MMIO 窗口删了，stage2 补回了 nvcsi 的，
**没人补 ISP 的**。

⚠️ 纯 DTB 改动，不动内核。三条都只是把出厂值原样加回去。
"""
import sys

CPD = ("/work/src/Linux_for_Tegra/source/public/kernel_src/hardware/nvidia/"
       "platform/t19x/jakku/kernel-dts/tegra194-mi-k91-camera-power.dtsi")

s = open(CPD).read()
if "stage21" in s:
    print("FATAL: 已注入过 stage21")
    sys.exit(1)
assert "&nvcsi {" in s, "必须在变体脚本的 DTB 段之后运行（camera-power.dtsi 要已被改过）"

s += '''
/* ---------------------------------------------------------------------------
 * stage21: 补回出厂 DTB 里有、我们缺的三个属性。
 *
 * 内核侧已用 R32.5.2 官方源逐函数比对完毕(还原完整、仍零帧)，转去逐节点比对
 * DTB，在关键节点上找到这三处缺失。clocks/resets/power-domains/prod 的【值】
 * 两边逐字节一致，rtcpu 的 nvidia,camera-devices 也在 —— 只差这三条。
 *
 * R32 的内核驱动不读 num-ports 也不 platform_get_irq()，但这些属性会随 DT 被
 * RCE 侧看到(nvidia,camera-devices 指过去的正是这些节点)，而 R32 固件是靠自己
 * 解析节点来接管硬件的。
 *
 * ISP 的 reg 与当年 nvcsi 的情况完全平行：R35 因为"RCE 自己管"删掉了 MMIO 窗口，
 * stage2 补回了 nvcsi 的，没人补 ISP 的。
 * ------------------------------------------------------------------------- */
&nvcsi {
\t/* 出厂: interrupts = <0x00 0x77 0x04>;  num-ports = <0x06>; */
\tinterrupts = <0 0x77 0x04>;
\tnum-ports = <6>;
};

&{/host1x@13e00000/isp@14800000} {
\t/* 出厂: reg = <0x00 0x14800000 0x00 0x10000>; */
\treg = <0x0 0x14800000 0x0 0x00010000>;
};
'''
open(CPD, "w").write(s)
print("  ✅ camera-power.dtsi: 补回 nvcsi interrupts/num-ports + isp reg")
print("     stage21 标记 %d 处" % s.count("stage21"))
