#!/usr/bin/env python3
"""Stage-24：start_streams 改 once 语义 + 门控下抑制 PHY_STREAM_CLOSE。

2026-07-29 全镜头攻坚查明的机制（四个判决实验收敛）：

  | 实验 | 结果 |
  |---|---|
  | rebind → 单路 STREAMON             | ✅ 出帧（唯一可靠模式）|
  | rebind → 一路在流 + 第二路 STREAMON | ❌ 两路全坏 |
  | rebind → 一路流完 → 第二路 STREAMON | ❌ 第二路零帧（连 mask 都拿到了 0x800000000）|
  | rebind → 三路同时 STREAMON          | ❌ 全零帧 + mask=0x0 坏通道 + 24 次超时 |

真凶：**每次 vi_capture_setup 都会重跑 `nvcsi_r32_start_streams()`**（stage11 的
触发点），它做三件事：CSI nvhost 上电(stage22)、**重跑 pad 配置+MIPI 校准**(stage20)、
对**全部三个端口**重发 STREAM_SET_CONFIG + PHY_STREAM_OPEN(stage9)。
MIPI 校准要求 lane 处于 LP 态 —— 对着正在 HS 流的 lane 重校准就是打断；
对已 OPEN 的流重复 OPEN 也会把 R32 固件的流状态机搞乱。
这正是一直以来「同一次开机内不能反复做实验」「只有 rebind 后第一次可靠」的真身。

修法（keepalive 哲学，与 0004 一致）：
  ① `nvcsi_r32_start_streams()` 加 **once + mutex**：RCE 每次 resume 后只完整
     跑一遍（把三个端口全开好），之后所有调用直接跳过。并发的第二路会在锁上
     等第一路做完，天然消除竞态。
  ② 门控下 `csi5_stream_close()` **不发 PHY_STREAM_CLOSE**：端口流一旦开了就
     保持到 RCE 重启。传感器侧 STREAMOFF 正常停流（无数据而已），无害。
  ③ once 标志在 **rtcpu runtime_resume**（= RCE 固件重新 boot、流状态清零）时
     重置 —— rebind/开机都走这里，语义精确对齐。

⚠️ 全部动作都在 r32_camera_power 门控之内，门控关闭时行为等价 pristine。
"""
import sys

K = "/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia"
NVCSI = K + "/drivers/video/tegra/host/nvcsi/nvcsi-t194.c"
CSI5 = K + "/drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c"
RTCPU = K + "/drivers/platform/tegra/tegra-camera-rtcpu.c"

# ── ① nvcsi-t194.c：once 机制 ────────────────────────────────────────────────
src = open(NVCSI).read()
if "r32-once" in src:
    print("FATAL: 已注入过 stage24")
    sys.exit(1)
assert "r32-csipwr" in src, "必须在 stage22 之后运行"

# ①a 状态 + reset 导出（挂在 stage9 HELPER 注释之前）
A = ("/*\n"
     " * r32-csistart: R32 固件期待 NVCSI 由内核经 IVC 消息配置好")
n = src.count(A)
assert n == 1, "stage9 HELPER 注释锚点命中 %d 次" % n
STATE = (
    "/*\n"
    " * r32-once: start_streams 的一次性状态。\n"
    " *\n"
    " * 每次 vi_capture_setup 都重跑 start_streams(重校准+重开全部端口流)会把\n"
    " * 已在流的 lane 打断(MIPI 校准要求 LP 态)、把固件流状态机搞乱 —— 实测\n"
    " * rebind 后只有第一个流会话能出帧,第二个通道一建立连第一路也会坏。\n"
    " * 改成: RCE 每次 resume 后只完整跑一遍(三个端口全开好),之后全部跳过;\n"
    " * 并发调用在锁上等第一次做完。标志由 rtcpu runtime_resume 重置。\n"
    " */\n"
    "static DEFINE_MUTEX(r32_streams_lock);\n"
    "static bool r32_streams_done;\n"
    "\n"
    "void tegra194_nvcsi_r32_streams_reset(void)\n"
    "{\n"
    "\tmutex_lock(&r32_streams_lock);\n"
    "\tr32_streams_done = false;\n"
    "\tmutex_unlock(&r32_streams_lock);\n"
    "}\n"
    "EXPORT_SYMBOL_GPL(tegra194_nvcsi_r32_streams_reset);\n"
    "\n" + A)
src = src.replace(A, STATE, 1)

# ①b 函数体开头（stage22 注入块之前）：查 done + 上锁
A2 = "\t/*\n\t * r32-csipwr: 开流之前先走一遍 CSI 的 nvhost 上电。\n"
n = src.count(A2)
assert n == 1, "stage22 注入块锚点命中 %d 次" % n
ONCE_HEAD = (
    "\tmutex_lock(&r32_streams_lock);\n"
    "\tif (r32_streams_done) {\n"
    "\t\tmutex_unlock(&r32_streams_lock);\n"
    "\t\tdev_info_once(&pdev->dev,\n"
    "\t\t\t      \"r32-once: streams already up, skip re-run\\n\");\n"
    "\t\treturn;\n"
    "\t}\n"
    "\n" + A2)
src = src.replace(A2, ONCE_HEAD, 1)

# ①c 函数体末尾：置位 + 解锁（锚定 stage9 遍历循环的收尾三连括号）
A3 = ("\t\t\t\t i, chan->ports[i].csi_port, rc);\n"
      "\t\t}\n"
      "\t}\n"
      "}\n")
n = src.count(A3)
assert n == 1, "start_streams 函数尾锚点命中 %d 次" % n
TAIL = ("\t\t\t\t i, chan->ports[i].csi_port, rc);\n"
        "\t\t}\n"
        "\t}\n"
        "\n"
        "\tr32_streams_done = true;\n"
        "\tmutex_unlock(&r32_streams_lock);\n"
        "\tdev_info(&pdev->dev,\n"
        "\t\t \"r32-once: streams started (one-shot until RCE resume)\\n\");\n"
        "}\n")
src = src.replace(A3, TAIL, 1)

if "#include <linux/mutex.h>" not in src:
    inc = "#include <linux/module.h>"
    if inc in src:
        src = src.replace(inc, inc + "\n#include <linux/mutex.h>", 1)

open(NVCSI, "w").write(src)
print("  ✅ nvcsi-t194.c: start_streams once 化 + reset 导出（r32-once %d 处）"
      % src.count("r32-once"))

# ── ② csi5_fops.c：抑制 R32 版 PHY_STREAM_CLOSE ─────────────────────────────
# 门控下的 close 早已被 stage3 分派到自建的 csi5_stream_close_r32()（R32 语义
# fire-and-forget）—— 抑制点就在它体内：直接 return，不发消息。
src = open(CSI5).read()
assert "r32-once" not in src
A4 = ("\tmemset(&msg, 0, sizeof(msg));\n"
      "\tmsg.header.msg_id = CAPTURE_PHY_STREAM_CLOSE_REQ;\n"
      "\tmsg.header.channel_id = R32_TEMP_CHANNEL_ID;\n")
n = src.count(A4)
assert n == 1, "csi5_stream_close_r32 锚点命中 %d 次" % n
R4 = ("\t/*\n"
      "\t * r32-once: keepalive —— 不发 PHY_STREAM_CLOSE。\n"
      "\t * 端口流由 start_streams 一次性开好并保持到 RCE 重启;\n"
      "\t * 传感器侧 STREAMOFF 正常停流(线上无数据而已)。若在这里关流,\n"
      "\t * 下一次 STREAMON 因 once 不再重开 ⇒ 永久零帧。\n"
      "\t */\n"
      "\tdev_info_once(chan->csi->dev,\n"
      "\t\t      \"r32-once: PHY_STREAM_CLOSE suppressed (keepalive)\\n\");\n"
      "\tif (true)\n"
      "\t\treturn;\n"
      "\n" + A4)
src = src.replace(A4, R4, 1)

open(CSI5, "w").write(src)
print("  ✅ csi5_fops.c: 门控下抑制 PHY_STREAM_CLOSE（r32-once %d 处）"
      % src.count("r32-once"))

# ── ③ rtcpu runtime_resume：group_busy 门控块里重置 once 标志 ────────────────
src = open(RTCPU).read()
assert "r32-once" not in src
A5 = ("\tif (r32_camera_power) {\n"
      "\t\tdev_info(dev, \"r32-power: group_busy (gated ON)\\n\");\n")
n = src.count(A5)
assert n == 1, "gate 的 group_busy 块锚点命中 %d 次" % n
R5 = ("\tif (r32_camera_power) {\n"
      "\t\t/* r32-once: RCE 重新 boot ⇒ 流状态清零, start_streams 需重跑一遍 */\n"
      "\t\ttegra194_nvcsi_r32_streams_reset();\n"
      "\t\tdev_info(dev, \"r32-power: group_busy (gated ON)\\n\");\n")
src = src.replace(A5, R5, 1)

if "void tegra194_nvcsi_r32_streams_reset(void);" not in src:
    A6 = "static bool r32_camera_power;\n"
    n = src.count(A6)
    assert n == 1, "r32_camera_power 声明锚点命中 %d 次" % n
    src = src.replace(
        A6,
        "void tegra194_nvcsi_r32_streams_reset(void);\t/* r32-once: 定义在 nvcsi-t194.c */\n"
        + A6, 1)

open(RTCPU, "w").write(src)
print("  ✅ tegra-camera-rtcpu.c: runtime_resume 时重置 once（r32-once %d 处)"
      % src.count("r32-once"))
