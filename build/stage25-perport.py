#!/usr/bin/env python3
"""Stage-25：CSI 端口消息按端口位图幂等（补 stage24 没盖住的第二入口）。

stage24 的 once 只盖住了批量入口 `nvcsi_r32_start_streams()`。但 v4l2 每条通道
STREAMON 时还会走 per-channel 入口：
    tegra_channel_set_stream → csi5_start_streaming
      → csi5_stream_set_config_r32 + csi5_stream_open_r32
对**已经开好流的端口重复发** SET_CONFIG/OPEN。实测竞态后果：
三路 20 秒并发时主摄+鱼眼A 满速 29.8fps，**鱼眼B 0 帧零错误**
（port0/port1 同一 CIL brick，重复 SET_CONFIG 扰动 brick 配置）。

修法：两张原子位图（cfg/open 各一张），**每个端口的每种消息全局只发一次**，
不论从哪个入口进来；RCE resume 时随 stage24 的 reset 一起清零。
claim 用 atomic_fetch_or —— 并发时只有一个赢家发消息，输家直接返回 0。
"""
import sys

K = "/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia"
CSI5 = K + "/drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c"
NVCSI = K + "/drivers/video/tegra/host/nvcsi/nvcsi-t194.c"

src = open(CSI5).read()
if "r32-perport" in src:
    print("FATAL: 已注入过 stage25")
    sys.exit(1)
assert "r32-once" in src, "必须在 stage24 之后运行"

# ── ① 位图 + claim + reset（挂在 csi5_stream_open_r32 之前）────────────────
A = ("static int csi5_stream_open_r32(struct tegra_csi_channel *chan, u32 stream_id,\n"
     "\tu32 csi_port)\n")
n = src.count(A)
assert n == 1, "open_r32 函数头锚点命中 %d 次" % n
STATE = (
    "/*\n"
    " * r32-perport: CSI 端口消息的按端口幂等位图。\n"
    " *\n"
    " * SET_CONFIG/OPEN 有两个入口(nvcsi 的批量 start_streams + v4l2 每通道的\n"
    " * csi5_start_streaming)。对已在流的端口重复发这两条消息会扰动同 brick 的\n"
    " * 邻端口(实测三路并发时 port1 的鱼眼 0 帧零错误)。这里保证:\n"
    " * 每个端口的每种消息在 RCE 一个生命周期内全局只发一次。\n"
    " * claim 用 atomic_fetch_or, 并发时只有一个赢家发消息。\n"
    " */\n"
    "static atomic_t r32_ports_cfg = ATOMIC_INIT(0);\n"
    "static atomic_t r32_ports_open = ATOMIC_INIT(0);\n"
    "\n"
    "void tegra194_csi5_r32_ports_reset(void)\n"
    "{\n"
    "\tatomic_set(&r32_ports_cfg, 0);\n"
    "\tatomic_set(&r32_ports_open, 0);\n"
    "}\n"
    "EXPORT_SYMBOL_GPL(tegra194_csi5_r32_ports_reset);\n"
    "\n"
    "static bool r32_port_claim(atomic_t *map, u32 csi_port)\n"
    "{\n"
    "\tu32 bit = 1u << (csi_port & 31u);\n"
    "\n"
    "\treturn (((u32)atomic_fetch_or((int)bit, map)) & bit) == 0u;\n"
    "}\n"
    "\n" + A)
src = src.replace(A, STATE, 1)

# ── ② open_r32 幂等（声明后、memset 前）────────────────────────────────────
A2 = ("\tmemset(&msg, 0, sizeof(msg));\n"
      "\tmsg.header.msg_id = CAPTURE_PHY_STREAM_OPEN_REQ;\n"
      "\tmsg.header.channel_id = R32_TEMP_CHANNEL_ID;\n")
n = src.count(A2)
assert n == 1, "open_r32 体锚点命中 %d 次" % n
R2 = ("\tif (!r32_port_claim(&r32_ports_open, csi_port)) {\n"
      "\t\tdev_info_once(chan->csi->dev,\n"
      "\t\t\t      \"r32-perport: OPEN already sent, skip\\n\");\n"
      "\t\treturn 0;\n"
      "\t}\n"
      "\n" + A2)
src = src.replace(A2, R2, 1)

# ── ③ set_config_r32 幂等（声明后第一条语句 = stage3 的 brick memset）───────
A3 = ("\t/* Brick config -- R32 verbatim */\n"
      "\tmemset(&brick_config, 0, sizeof(brick_config));\n")
n = src.count(A3)
assert n == 1, "set_config_r32 体锚点命中 %d 次" % n
R3 = ("\tif (!r32_port_claim(&r32_ports_cfg, csi_port)) {\n"
      "\t\tdev_info_once(chan->csi->dev,\n"
      "\t\t\t      \"r32-perport: SET_CONFIG already sent, skip\\n\");\n"
      "\t\treturn 0;\n"
      "\t}\n"
      "\n" + A3)
src = src.replace(A3, R3, 1)

if "#include <linux/atomic.h>" not in src:
    import re
    incs = re.findall(r"(?m)^#include .*$", src)
    assert incs
    last = incs[-1] + "\n"
    src = src.replace(last, last + "#include <linux/atomic.h>\t/* r32-perport */\n", 1)

open(CSI5, "w").write(src)
print("  ✅ csi5_fops.c: SET_CONFIG/OPEN 按端口幂等（r32-perport %d 处）"
      % src.count("r32-perport"))

# ── ④ RCE resume 的 reset 链上挂端口位图清零 ────────────────────────────────
src = open(NVCSI).read()
assert "r32-perport" not in src
A4 = ("void tegra194_nvcsi_r32_streams_reset(void)\n"
      "{\n"
      "\tmutex_lock(&r32_streams_lock);\n"
      "\tr32_streams_done = false;\n"
      "\tmutex_unlock(&r32_streams_lock);\n"
      "}\n")
n = src.count(A4)
assert n == 1, "stage24 reset 函数锚点命中 %d 次" % n
R4 = ("void tegra194_csi5_r32_ports_reset(void);\t/* r32-perport: 定义在 csi5_fops.c */\n"
      "\n"
      "void tegra194_nvcsi_r32_streams_reset(void)\n"
      "{\n"
      "\tmutex_lock(&r32_streams_lock);\n"
      "\tr32_streams_done = false;\n"
      "\tmutex_unlock(&r32_streams_lock);\n"
      "\ttegra194_csi5_r32_ports_reset();\t/* r32-perport */\n"
      "}\n")
src = src.replace(A4, R4, 1)
open(NVCSI, "w").write(src)
print("  ✅ nvcsi-t194.c: reset 链挂上端口位图清零（r32-perport %d 处）"
      % src.count("r32-perport"))
