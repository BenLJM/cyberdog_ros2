#!/usr/bin/env python3
"""Stage-23：VI 侧也补上 nvhost 上电（A/B 表里剩下的那一条）。

JP4 ↔ JP5 函数级 A/B 里，CSI 侧的缺口已由 stage22 补上，还剩 VI 侧：

    vi5_power_on / vi5_power_off    JP4 = 38 / 54      JP5 = 0 / 0

R32 的 `vi5_power_on()` 本质是：
    nvhost_module_add_client(vi->ndev, &chan->video);
    tegra_vi5_power_on(vi);
—— 即对 VI 的 nvhost 设备做上电。R35 里 `vi5_power_on` 还在（挂在 `vi_fops` 上），
但它吃 `struct tegra_channel *`（v4l2 通道），argus 的 fusa-capture 路径没有这东西。

好在 `struct tegra_vi_channel` 里有 `ndev`（VI nvhost platform_device），
可以直接对它做 `nvhost_module_busy()` —— 与 R32 的净效果一致：
让 VI 设备在采集期间真正处于 busy/上电态，而不是靠 keepalive 悬着。

挂点选 `vi_capture_setup()` 里通道建立成功之后（与 stage11 触发 CSI 开流同一处，
顺序：VI 上电 → CSI 上电(stage22) → CSI 开流(stage9/11)）。
不配对 idle：与 stage22 同理，保持 keepalive 语义。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/fusa-capture/capture-vi.c")

src = open(F).read()
if "r32-vipwr" in src:
    print("FATAL: 已注入过 stage23")
    sys.exit(1)
assert "r32_csistart_after_setup" in src, "必须在 stage11 之后运行"

A = ("\tif (tegra_camrtc_r32_camera_power_enabled())\n"
     "\t\ttegra194_nvcsi_r32_start_streams();\n")
n = src.count(A)
assert n == 1, "stage11 的触发点锚点命中 %d 次" % n

R = ('\tif (tegra_camrtc_r32_camera_power_enabled()) {\n'
     '\t\t/*\n'
     '\t\t * r32-vipwr: 先把 VI 的 nvhost 设备拉成 busy(上电)，再开 CSI 流。\n'
     '\t\t *\n'
     '\t\t * JP4 在线对照显示采集期间 vi5_power_on/off 各跑 38/54 次，JP5 为 0 ——\n'
     '\t\t * R32 的 vi5_power_on 本质就是对 VI 的 nvhost 设备上电。R35 里该函数\n'
     '\t\t * 还在但吃 struct tegra_channel*(v4l2 通道)，argus 的 fusa-capture\n'
     '\t\t * 路径没有它；而 tegra_vi_channel 里有 ndev，可直接 nvhost_module_busy。\n'
     '\t\t * 顺序: VI 上电 → CSI 上电(stage22) → CSI 开流(stage9/11)。\n'
     '\t\t */\n'
     '\t\tif (chan->ndev != NULL) {\n'
     '\t\t\tint vrc = nvhost_module_busy(chan->ndev);\n'
     '\n'
     '\t\t\tdev_info_once(chan->dev,\n'
     '\t\t\t\t      "r32-vipwr: vi nvhost_module_busy rc=%d\\n", vrc);\n'
     '\t\t}\n'
     '\t\ttegra194_nvcsi_r32_start_streams();\n'
     '\t}\n')
src = src.replace(A, R, 1)

# nvhost_module_busy 来自 nvhost_acm.h —— capture-vi.c 本来就 include 了它
assert '#include "nvhost_acm.h"' in src, "capture-vi.c 没有 include nvhost_acm.h"

open(F, "w").write(src)
print("  ✅ capture-vi.c: 通道建立后先给 VI 上电再开 CSI 流")
print("     r32-vipwr %d 处" % src.count("r32-vipwr"))
