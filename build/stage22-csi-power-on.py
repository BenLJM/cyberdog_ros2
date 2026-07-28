#!/usr/bin/env python3
"""Stage-22：开 CSI 流之前先走一遍 CSI/VI 的 nvhost 上电（JP4 直接对照得出）。

2026-07-29 用**自恢复的 JP4 在线对照实验**（同一块板、同一颗 RCE 固件，
唯一变量是内核）ftrace 两边的内核相机函数，得到直接 A/B：

| 函数 | JP4(工作) | JP5(不工作) |
|---|---|---|
| `vi_capture_ivc_status_callback` | **324** | **0** ← 帧完成回调 |
| `tegra_csi_s_power` / `tegra_csi_power` | **74 / 74** | **0 / 0** |
| `csi5_power_on` / `csi5_power_off` | **19 / 18** | **0 / 0** |
| `vi5_power_on` / `vi5_power_off` | **38 / 54** | **0 / 0** |
| `tegra_channel_open` | 38 | 19（两边都有）|

⇒ **JP4 上采集期间会反复走 CSI 的 nvhost 上电链，JP5 上一次都不走。**

`csi5_power_on()` 两代**完全相同**，就是 `nvhost_module_busy(csi->pdev)` ——
nvhost 的「把设备真正拉起来」调用：它会走 runtime-PM 的 poweron 路径，
从而触发 `tegra194_nvcsi_finalize_poweron()`（也就是 stage2 的 prod + 校准，
以及 stage19 的 CIL pad 配置）**在采集当下**执行。

我们的 stage9/11 手工补了「开流」（`tegra_csi_start_streaming`），
**但漏了「上电」** —— 而 R32 的顺序是先上电再开流。

修法：在 `nvcsi_r32_start_streams()` 里，开流之前先调
`csi->fops->csi_power_on(csi)`，收尾时不配对 power_off（保持 keepalive 语义，
与补丁 0004 一致；`nvhost_module_busy` 的引用计数由 nvhost 自己管）。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/video/tegra/host/nvcsi/nvcsi-t194.c")

src = open(F).read()
if "r32-csipwr" in src:
    print("FATAL: 已注入过 stage22")
    sys.exit(1)
assert "r32-csistart" in src, "必须在 stage9 之后运行"

# 挂在 stage20 的重跑校准之前（若无 stage20 则挂在通道遍历之前）
A20 = ("\t{\n"
       "\t\tint rc = tegra_csi_mipi_calibrate(&nvcsi->csi, true);\n")
A9 = ("\tlist_for_each_entry(chan, &nvcsi->csi.csi_chans, list) {\n"
      "\t\tif (chan->pg_mode != 0U || chan->s_data == NULL)\n"
      "\t\t\tcontinue;\n")

if src.count(A20) == 1:
    A, where = A20, "stage20 重跑校准之前"
else:
    n = src.count(A9)
    assert n == 1, "找不到挂点（stage20 锚点 %d 次 / stage9 锚点 %d 次）" % (
        src.count(A20), n)
    A, where = A9, "stage9 通道遍历之前"

R = ('\t/*\n'
     '\t * r32-csipwr: 开流之前先走一遍 CSI 的 nvhost 上电。\n'
     '\t *\n'
     '\t * JP4 在线对照(ftrace 同场景 A/B)显示: 采集期间 JP4 会反复调\n'
     '\t * tegra_csi_s_power → csi5_power_on(=nvhost_module_busy)，JP5 一次都不调。\n'
     '\t * 而 csi5_power_on 两代实现完全相同 —— 它会走 runtime-PM 的 poweron，\n'
     '\t * 从而让 finalize_poweron(stage2 的 prod+校准、stage19 的 CIL pad 配置)\n'
     '\t * 在【采集当下】执行。stage9/11 只补了"开流"，漏了"上电"，\n'
     '\t * 而 R32 的顺序是先上电再开流。\n'
     '\t * 不配对 power_off：保持 keepalive 语义(与补丁 0004 一致)，\n'
     '\t * nvhost_module_busy 的引用计数由 nvhost 自己管。\n'
     '\t */\n'
     '\tif (nvcsi->csi.fops != NULL && nvcsi->csi.fops->csi_power_on != NULL) {\n'
     '\t\tint prc = nvcsi->csi.fops->csi_power_on(&nvcsi->csi);\n'
     '\n'
     '\t\tdev_info(&pdev->dev, "r32-csipwr: csi_power_on rc=%d\\n", prc);\n'
     '\t}\n'
     '\n' + A)
src = src.replace(A, R, 1)

open(F, "w").write(src)
print("  ✅ nvcsi-t194.c: 开流前补 CSI nvhost 上电（挂在 %s）" % where)
print("     r32-csipwr %d 处" % src.count("r32-csipwr"))
