#!/usr/bin/env python3
"""Stage-20：CSI 流启动时重跑一次 pad 配置 + MIPI 校准。

stage19 把 R32 原版的 CIL pad 配置补齐了（实测 `cila=0x700000 cilb=0x640000`，
与 R32 逐位一致），但仍零帧。查下来是个**交互 bug**：

  · pad 配置 + 校准挂在 `tegra194_nvcsi_finalize_poweron()`，且被
    `atomic_read(&nvcsi->on) == 1` 守卫 —— 一次开机只跑一次；
  · 补丁 0004 带了 `keepalive = true`，NVCSI 从此不掉电 ⇒
    `prepare_poweroff` 不跑 ⇒ `on` 永远是 1 ⇒ **pad 配置永不重跑**；
  · 而日志里明明有 `r32-power: group_reset (gated ON)` ——
    **相机设备组复位会把 NVCSI 寄存器清掉**，之后再没人重新配置。

R32 上不会这样：NVCSI 会在会话之间掉电（autosuspend 500ms），
每次采集前 `finalize_poweron` 都重跑一遍 pad 配置和校准。

修法：在 stage9 的 `nvcsi_r32_start_streams()` 里（它由 capture-vi 在
**VI 通道建立之后**调用，正好是每次采集前）再跑一次
`tegra_csi_mipi_calibrate(&nvcsi->csi, true)` —— 它内部就会走到
`csi5_mipi_cal()`，把 pad 配置和校准一起重做。

⚠️ 幂等：pad 配置是纯寄存器写，校准是硬件状态机，重复执行安全（R32 每次采集都做）。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/video/tegra/host/nvcsi/nvcsi-t194.c")

src = open(F).read()
if "r32-recal" in src:
    print("FATAL: 已注入过 stage20")
    sys.exit(1)
assert "r32-csistart" in src, "必须在 stage9 之后运行"

A = ("\tlist_for_each_entry(chan, &nvcsi->csi.csi_chans, list) {\n"
     "\t\tif (chan->pg_mode != 0U || chan->s_data == NULL)\n"
     "\t\t\tcontinue;\n")
n = src.count(A)
assert n == 1, "stage9 的通道遍历锚点命中 %d 次" % n

R = ('\t/*\n'
     '\t * r32-recal: 每次采集前重做 pad 配置 + MIPI 校准。\n'
     '\t *\n'
     '\t * pad 配置/校准原本挂在 finalize_poweron 且被 nvcsi->on 守卫，一次开机\n'
     '\t * 只跑一次；而补丁 0004 的 keepalive 让 NVCSI 不再掉电 ⇒ 永不重跑。\n'
     '\t * 但 r32-power 的 group_reset 会把 NVCSI 寄存器清掉 —— 之后就没人再配了。\n'
     '\t * R32 上 NVCSI 会在会话间掉电，每次采集前都重跑一遍，这里对齐该行为。\n'
     '\t */\n'
     '\t{\n'
     '\t\tint rc = tegra_csi_mipi_calibrate(&nvcsi->csi, true);\n'
     '\n'
     '\t\tdev_info(&pdev->dev, "r32-recal: pad+cal rerun rc=%d\\n", rc);\n'
     '\t}\n'
     '\n' + A)
src = src.replace(A, R, 1)

open(F, "w").write(src)
print("  ✅ nvcsi-t194.c: 流启动时重跑 pad 配置 + 校准")
print("     r32-recal %d 处" % src.count("r32-recal"))
