#!/usr/bin/env python3
"""把 R32 相机上电契约改成「运行时开关，默认关」，注入 tegra-camera-rtcpu.c。

用精确字符串锚定，不用行号/patch 上下文（那两样在这棵树上已经漂过一次）。
每处替换都断言命中次数，命中数不对就整体失败，绝不半途而废。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/platform/tegra/tegra-camera-rtcpu.c")

src = open(F).read()
if "r32_camera_power" in src:
    print("FATAL: 已经注入过，树不干净")
    sys.exit(1)

# ── ① 模块参数定义（放在 include 区之后）────────────────────────────────────
A1 = '#include <linux/tegra-rtcpu-coverage.h>\n'
DEF = A1 + '''
#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)
/*
 * R32 相机上电契约 —— 运行时开关，默认关闭。
 *
 * 2026-07-27 的「变体 B」把 camrtc_device_group_busy()/reset() 无条件调用，
 * 结果内核在 probe 阶段挂死：狗连 T+19.4s 都没到（USB gadget 根本没出现），
 * 只能靠机主拔电 + RCM 重刷救回来。
 *
 * 两个事实决定了这里不能无条件调用：
 *  1. 这些调用点跑在 rtcpu 的 probe 路径上，即 device_initcall。
 *     所有 initcall 都在 initrd 的 /init 之前跑完（dmesg: "jp5-init: up" @ ~5.6s），
 *     所以挂死发生在 initrd **之前** —— initrd 里的自动回滚守卫
 *     (sbin/jp5-autorevert-hook) 永远看不到它，没有任何自动回来的路。
 *  2. TEGRA_CAMERA_RTCPU 在 Kconfig 里是 bool 不是 tristate，
 *     所以也没法靠「编成模块」把 probe 推迟到 userspace。
 *
 * 于是把危险路径关在一个可写的模块参数后面，默认关。内核永远起得来；
 * 危险动作由 userspace 在 initrd 守卫早就干完活之后再武装：
 *
 *     echo 1 > /sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
 *
 * 万一挂死：hung_task_panic=1（extlinux APPEND）把它变成 panic，
 * ramoops 记下 call trace，panic=15 热重启，而参数回到默认 0 ——
 * 狗自己就回来了，现场还留着。
 */
static bool r32_camera_power;
module_param_named(r32_camera_power, r32_camera_power, bool, 0644);
MODULE_PARM_DESC(r32_camera_power,
	"Apply R32 camera power contract (isp/vi/nvcsi busy+reset). Default off.");
#endif
'''
assert src.count(A1) == 1, "锚点①命中 %d 次" % src.count(A1)
src = src.replace(A1, DEF, 1)

# ── ② poweron: deassert_resets 之前做 group_reset ───────────────────────────
A2 = ("\t\tcamrtc_clk_group_adjust_fast(rtcpu->clocks);\n"
      "\n\tret = tegra_camrtc_deassert_resets(dev);")
NEW2 = ("\t\tcamrtc_clk_group_adjust_fast(rtcpu->clocks);\n"
        "\n"
        "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
        "\t/* R32 parity：在 RCE 出复位之前先复位 isp/vi/nvcsi。位置与 R32 完全一致。*/\n"
        "\tif (r32_camera_power) {\n"
        "\t\tdev_info(dev, \"r32-power: group_reset (gated ON)\\n\");\n"
        "\t\tcamrtc_device_group_reset(rtcpu->camera_devices);\n"
        "\t}\n"
        "#endif\n"
        "\n\tret = tegra_camrtc_deassert_resets(dev);")
assert src.count(A2) == 1, "锚点②命中 %d 次" % src.count(A2)
src = src.replace(A2, NEW2, 1)

# ── ③ runtime_suspend: group_idle ──────────────────────────────────────────
A3 = "\tcamrtc_clk_group_adjust_slow(rtcpu->clocks);\n"
NEW3 = (A3 +
        "\n#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
        "\tif (r32_camera_power) {\n"
        "\t\tdev_info(dev, \"r32-power: group_idle (gated ON)\\n\");\n"
        "\t\tcamrtc_device_group_idle(rtcpu->camera_devices);\n"
        "\t}\n"
        "#endif\n")
assert src.count(A3) == 1, "锚点③命中 %d 次" % src.count(A3)
src = src.replace(A3, NEW3, 1)

# ── ④ runtime_resume: boot 之前 group_busy ─────────────────────────────────
A4 = ("static int tegra_cam_rtcpu_runtime_resume(struct device *dev)\n"
      "{\n"
      "\tint err;\n"
      "\n"
      "\ttegra_camrtc_pm_start(dev, \"runtime_resume\");\n")
NEW4 = ("static int tegra_cam_rtcpu_runtime_resume(struct device *dev)\n"
        "{\n"
        "\tint err;\n"
        "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
        "\tstruct tegra_cam_rtcpu *rtcpu = dev_get_drvdata(dev);\n"
        "#endif\n"
        "\n"
        "\ttegra_camrtc_pm_start(dev, \"runtime_resume\");\n"
        "\n"
        "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
        "\t/*\n"
        "\t * R32 parity：在 boot RCE 之前把 nvidia,camera-devices = <&isp &vi &nvcsi>\n"
        "\t * 里的设备上电。R35 删掉这段是因为它自己的 RCE 固件会经 BPMP 上电，\n"
        "\t * 而出厂 R32 固件不会 —— 少了这一步，RCE 第一次读 NVCSI 就撞死总线：\n"
        "\t *   rce-noc / Host read timeout at address 303cc\n"
        "\t */\n"
        "\tif (r32_camera_power) {\n"
        "\t\tdev_info(dev, \"r32-power: group_busy (gated ON)\\n\");\n"
        "\t\terr = camrtc_device_group_busy(rtcpu->camera_devices);\n"
        "\t\tif (err < 0) {\n"
        "\t\t\ttegra_camrtc_pm_done(dev, \"runtime_resume\", err);\n"
        "\t\t\treturn err;\n"
        "\t\t}\n"
        "\t}\n"
        "#endif\n")
assert src.count(A4) == 1, "锚点④命中 %d 次" % src.count(A4)
src = src.replace(A4, NEW4, 1)

open(F, "w").write(src)
print("✅ 四处注入全部命中并写回")
for k in ("r32_camera_power", "group_busy (gated ON)", "group_reset (gated ON)",
          "group_idle (gated ON)"):
    print("   %-28s %d 处" % (k, src.count(k)))
