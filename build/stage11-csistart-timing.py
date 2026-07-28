#!/usr/bin/env python3
"""Stage-11：把 stage9 的 CSI 流启动挪到【VI 采集通道建立之后】。

stage9 把 tegra_csi_start_streaming() 挂在 nvcsi_finalize_poweron（prod+校准之后），
实测消息确实发出去了且参数正确：
    r32-csi5: STREAM_SET_CONFIG stream=4 port=4 lanes=4 settle=19 mipi=448000kHz
但同时引入回归 —— 随后的 ISP 通道建立开始超时：
    tegra194-isp5: isp capture control message timed out
    tegra194-isp5: isp capture setup failed

原因：这些 CSI 消息用的是 R32_TEMP_CHANNEL_ID（stage3 的 R32 语义），在【采集通道
还不存在】时就发给 RCE，把固件置于一个后续通道建立会超时的状态。R32 的真实顺序是
**先建采集通道、再开 CSI 流**。

修法：
  1. 从两条校准路径里撤掉 stage9 的调用；
  2. 把 helper 改成可导出（用 probe 时存下的 pdev），由 capture-vi.c 的
     vi_capture_setup() 成功之后调用一次。
"""
import re
import sys

NV = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
      "drivers/video/tegra/host/nvcsi/nvcsi-t194.c")
CV = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
      "drivers/media/platform/tegra/camera/fusa-capture/capture-vi.c")

src = open(NV).read()
if "r32_csistart_after_setup" in src:
    print("FATAL: 已注入过 stage11")
    sys.exit(1)
assert "r32-csistart" in src, "必须在 stage9 之后运行"

# ---- 1. 撤掉校准路径里的两处调用 ----
# ⚠️ 必须【先删两个 tab 的那条】：单 tab 版本是它的子串，反过来 count 会数出 2 次。
for a in ("\t\tnvcsi_r32_start_streams(pdev);\n",
          "\tnvcsi_r32_start_streams(pdev);\n"):
    n = src.count(a)
    assert n == 1, "stage9 调用点命中 %d 次: %r" % (n, a)
    src = src.replace(a, "", 1)

# ---- 2. 记住 pdev，并导出一个无参入口 ----
A = "static void nvcsi_r32_start_streams(struct platform_device *pdev)\n"
assert src.count(A) == 1
src = src.replace(
    A,
    "/* r32_csistart_after_setup: 由 capture-vi.c 在 VI 通道建立成功后调用 —— \n"
    " * 必须晚于通道建立，早于它 RCE 会让后续 ISP 通道建立超时（stage9 实测）。*/\n"
    "static struct platform_device *r32_nvcsi_pdev;\n"
    "\n" + A, 1)

# finalize_poweron 里存下 pdev（门控之后、任何 early-return 之前）
B = ("\tif (!tegra_camrtc_r32_camera_power_enabled())\n"
     "\t\treturn 0;\n"
     "\tif (atomic_read(&nvcsi->on) == 1)\n"
     "\t\treturn 0;\n")
n = src.count(B)
assert n == 1, "finalize_poweron 门控锚点命中 %d 次" % n
src = src.replace(
    B,
    "\tif (!tegra_camrtc_r32_camera_power_enabled())\n"
    "\t\treturn 0;\n"
    "\tr32_nvcsi_pdev = pdev;\n"
    "\tif (atomic_read(&nvcsi->on) == 1)\n"
    "\t\treturn 0;\n", 1)

# 导出入口（放在 finalize_poweron 之前）
C = "int tegra194_nvcsi_finalize_poweron(struct platform_device *pdev)\n"
assert src.count(C) == 1
src = src.replace(
    C,
    "void tegra194_nvcsi_r32_start_streams(void)\n"
    "{\n"
    "\tif (!tegra_camrtc_r32_camera_power_enabled())\n"
    "\t\treturn;\n"
    "\tif (r32_nvcsi_pdev == NULL)\n"
    "\t\treturn;\n"
    "\tnvcsi_r32_start_streams(r32_nvcsi_pdev);\n"
    "}\n"
    "EXPORT_SYMBOL_GPL(tegra194_nvcsi_r32_start_streams);\n"
    "\n" + C, 1)
open(NV, "w").write(src)
print("  ✅ nvcsi-t194.c: 调用点撤除 + 导出 tegra194_nvcsi_r32_start_streams()")

# ---- 3. capture-vi.c：通道建立成功后调用一次 ----
cv = open(CV).read()
assert "r32_csistart_after_setup" not in cv
A2 = "\tcapture->channel_id = resp_msg->channel_setup_resp.channel_id;\n"
n = cv.count(A2)
assert n == 1, "capture-vi 通道建立成功锚点命中 %d 次" % n
cv = cv.replace(
    A2,
    A2 +
    "\n"
    "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
    "\t/*\n"
    "\t * r32_csistart_after_setup: R32 固件期待 NVCSI 由内核经独立 IVC 消息\n"
    "\t * 配置(R35 改成把 csi_stream 塞进 CAPTURE_CHANNEL_SETUP 让 RCE 自己配，\n"
    "\t * 所以 argus 路径下内核 csi5 从不被调用)。顺序很要紧：必须在采集通道\n"
    "\t * 建立【之后】—— 在此之前发会让后续 ISP 通道建立超时(stage9 实测)。\n"
    "\t */\n"
    "\tif (tegra_camrtc_r32_camera_power_enabled())\n"
    "\t\ttegra194_nvcsi_r32_start_streams();\n"
    "#endif\n", 1)

incs = re.findall(r"(?m)^#include .*$", cv)
assert incs
last = incs[-1] + "\n"
cv = cv.replace(
    last,
    last + "\n#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
           "void tegra194_nvcsi_r32_start_streams(void);\n"
           "#endif\n", 1)
open(CV, "w").write(cv)
print("  ✅ capture-vi.c: 通道建立成功后触发 CSI 流启动")
print("     r32_csistart_after_setup %d 处" % cv.count("r32_csistart_after_setup"))
