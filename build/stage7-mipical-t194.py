#!/usr/bin/env python3
"""Stage-7：恢复 T194 的 MIPI 校准 SoC ops（stage6 之后露出来的最后一层空桩）。

2026-07-29 定位链的终点：
  stage6 把 csi5_mipi_cal 补成真实现后，lane 掩码算得完全正确
  （ov13b10: lanes=0x3000000 = CSIE|CSIF，port4 四通道），但：

      t194-nvcsi: r32-mipical: calibrating lanes=0x3000000 cphy=0
      t194-nvcsi: calibration failed with -1 error

  再往下追，R35 把 T194 的整条校准路【全部做成了空桩】：

      static int tegra_mipical_no_op(struct tegra_mipi *mipi, int lanes_info)
      {  return -1;  }

      static const struct tegra_mipi_soc tegra19x_mipi_soc = {
              .pad_enable   = &tegra_mipi_bias_pad_no_op,
              .pad_disable  = &tegra_mipi_bias_pad_no_op,
              .cil_sw_reset = NULL,
              .calibrate    = &tegra_mipical_no_op,      ← 恒返回 -1
      };

  原因同前：R35 让 RCE 固件做校准，所以内核侧全掏空。狗跑的 R32 固件不做。

  而 mipi_cal.c 自己的注释就写着：
      "For t19x, the register space is same as t18x, except that there was a
       shift in the DSI address space of 8"
  —— T186 那份真实现 `tegra_mipical_using_prod` 对 T194 本就适用，
  tegra19x_mipi_soc 里的 csi_base / dsi_base / total_cillanes 也已经是对的。

修法：把 t19x 的四个 ops 换成 t18x 的真实现。硬件与 DT 侧都已就位
（mipical@3990000 status=okay、驱动 tegra_mipi_cal 已绑定、prod-settings 齐全）。

⚠️ 这是编译期开关而非运行时门控（结构体是 const static）。但实际调用面仍受门控约束：
   · calibrate  只经 csi5_mipi_cal 进入，那里查 tegra_camrtc_r32_camera_power_enabled()
   · pad_enable/disable 只经 tegra_csi_mipi_calibrate 进入，同样在门控路径上
   · 另一个理论调用方是 DSI（dc/dsi.c），但 t19x 的 total_dsilanes=0 且本机无 DSI 屏
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/mipical/mipi_cal.c")

src = open(F).read()
if "r32-mipisoc" in src:
    print("FATAL: mipi_cal.c 已注入过 stage7")
    sys.exit(1)

# ---- 1. t19x 的 ops 换成 t18x 的真实现 ----
A = ("\t.pad_enable = &tegra_mipi_bias_pad_no_op,\n"
     "\t.pad_disable = &tegra_mipi_bias_pad_no_op,\n"
     "\t.cil_sw_reset = NULL,\n"
     "\t.calibrate = &tegra_mipical_no_op,\n")
n = src.count(A)
assert n == 1, "t19x ops 锚点命中 %d 次（应为 1，只有 tegra19x_mipi_soc 用空桩）" % n

R = ("#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
     "\t/*\n"
     "\t * r32-mipisoc: R35 把 T194 的 MIPI 校准整条路做成了空桩(RCE 固件代劳)，\n"
     "\t * 但本机跑的是不做校准的 R32 固件 —— 空桩会让 tegra_mipi_calibration()\n"
     "\t * 恒返回 -1，D-PHY 焊盘永远没校准，表现为传感器在发但 NVCSI 零中断。\n"
     "\t * 本文件自己的注释写明 t19x 的寄存器空间与 t18x 相同(仅 DSI 偏移 8)，\n"
     "\t * 故直接用 t18x 的真实现；csi_base/dsi_base/total_cillanes 保持 t19x 自己的值。\n"
     "\t */\n"
     "\t.pad_enable = &_t18x_tegra_mipi_bias_pad_enable,\n"
     "\t.pad_disable = &_t18x_tegra_mipi_bias_pad_disable,\n"
     "\t.cil_sw_reset = &nvcsi_cil_sw_reset,\n"
     "\t.calibrate = &tegra_mipical_using_prod,\n"
     "#else\n"
     + A +
     "#endif\n")
src = src.replace(A, R, 1)

# ---- 2. 空桩函数加 __maybe_unused（换掉后它们在本配置下没人引用了）----
for old, new in [
    ("static int tegra_mipical_no_op(struct tegra_mipi *mipi, int lanes_info)",
     "static int __maybe_unused tegra_mipical_no_op(struct tegra_mipi *mipi,\n"
     "\t\t\t\t\t      int lanes_info)"),
    ("static int tegra_mipi_bias_pad_no_op(struct tegra_mipi *mipi)",
     "static int __maybe_unused tegra_mipi_bias_pad_no_op(struct tegra_mipi *mipi)"),
]:
    c = src.count(old)
    assert c == 1, "空桩定义锚点命中 %d 次: %s" % (c, old[:50])
    src = src.replace(old, new, 1)

# ---- 3. 运行时可见性：让 "r32-mipisoc" 真的进二进制并能在 dmesg 里确认 ----
# （注释里的标记不会进 Image，构建脚本的符号断言查的是 Image）
C_A = ("\ttrace_mipical(\"lanes\", lanes);\n"
       "\tif (mipi->soc->calibrate)\n")
c = src.count(C_A)
assert c == 1, "tegra_mipi_calibration 锚点命中 %d 次" % c
src = src.replace(
    C_A,
    "\ttrace_mipical(\"lanes\", lanes);\n"
    "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
    "\tpr_info_once(\"r32-mipisoc: real T194 calibration ops active\\n\");\n"
    "#endif\n"
    "\tif (mipi->soc->calibrate)\n", 1)

open(F, "w").write(src)
print("  ✅ mipi_cal.c: tegra19x_mipi_soc 换回 t18x 真实现")
print("     r32-mipisoc %d 处 / __maybe_unused %d 处"
      % (src.count("r32-mipisoc"), src.count("__maybe_unused")))
