#!/usr/bin/env python3
"""Stage-19：补齐 csi5_mipi_cal 里的 CIL pad 配置 + SW reset（照 R32 原版）。

2026-07-29 拿到 **R32.5.2 的公开内核源**（`developer.download.nvidia.com/embedded/
L4T/r32_Release_v5.2/sources/T186/public_sources.tbz2`，正是狗上跑的版本）后，
拿 R32 真正的 `csi5_mipi_cal()` 一比，发现 stage6 **漏了最关键的一半**。

stage6 当时是照 `csi4_mipi_cal` 写的，并且**刻意跳过了 CIL pad 寄存器写**，
理由是"csi5 没有 phy_write helper，且 pad 配置已由 stage2 的 prod settings 负责"。
**这个假设是错的** —— R32 的 csi5 自己就有 `csi5_phy_write()`，而且 4 lane 分支里
在调 `tegra_mipi_calibration()` 之前会写四次寄存器：

    cila = (1<<E_INPUT_LP_IO0)|(1<<E_INPUT_LP_IO1)|(1<<E_INPUT_LP_CLK)
         | (0<<PD_CLK)|(0<<PD_IO0)|(0<<PD_IO1);
    cilb = (1<<E_INPUT_LP_IO0)|(1<<E_INPUT_LP_IO1)|(1<<PD_CLK)
         | (0<<PD_IO0)|(0<<PD_IO1);
    csi5_phy_write(chan, csi_port>>1, CIL_A_BASE + PAD_CONFIG_0, cila);
    csi5_phy_write(chan, csi_port>>1, CIL_B_BASE + PAD_CONFIG_0, cilb);
    csi5_phy_write(chan, csi_port>>1, CIL_A_SW_RESET, SW_RESET1_EN|SW_RESET0_EN);
    csi5_phy_write(chan, csi_port>>1, CIL_B_SW_RESET, SW_RESET1_EN|SW_RESET0_EN);

`E_INPUT_LP_*` 是 **D-PHY 低功耗输入接收器的使能位**，`PD_*` 是**下电位**。
不写这几个寄存器，接收器根本没上电 —— 与实测「NVCSI 完全听不见、
连一个中断都没有，而 VI 在空转超时」**精确吻合**。

⚠️ `csi5_registers.h` 两代**逐字节相同**（已 diff 验证），偏移可直接沿用。
⚠️ 地址算法照抄 R32：`iomem_base + CSI5_BASE_ADDRESS + CSI5_PHY_OFFSET*index + addr`
   （本机 port 4 ⇒ index=2 ⇒ 0x011000 + 0x020000 = 0x031000）。
   顺带解释了 stage15 为什么读到数据类型表：它读的是 0x30000，差了 0x1000。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c")

src = open(F).read()
if "r32-padcfg" in src:
    print("FATAL: 已注入过 stage19")
    sys.exit(1)
assert "r32-mipical" in src, "必须在 stage6 之后运行"

# ---- 1. 加 phy_write helper（R32 原版）----
A = "static int csi5_mipi_cal(struct tegra_csi_channel *chan)\n"
n = src.count(A)
assert n == 1, "csi5_mipi_cal 锚点命中 %d 次" % n

HELPER = ('#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n'
          '/* r32-padcfg: R32 原版的 PHY 寄存器写（地址算法逐字照抄）。 */\n'
          'static void r32_csi5_phy_write(struct tegra_csi_channel *chan,\n'
          '\t\tunsigned int index, unsigned int addr, u32 val)\n'
          '{\n'
          '\tstruct tegra_csi_device *csi = chan->csi;\n'
          '\n'
          '\tif (csi->iomem_base == NULL)\n'
          '\t\treturn;\n'
          '\twritel(val, csi->iomem_base +\n'
          '\t\tCSI5_BASE_ADDRESS + (CSI5_PHY_OFFSET * index) + addr);\n'
          '}\n'
          '#endif\n'
          '\n' + A)
src = src.replace(A, HELPER, 1)

# ---- 2. 在算 lane 掩码的循环里补上 pad 配置 + SW reset ----
B = ("\t\tif (num_lanes <= 2)\n"
     "\t\t\tlanes |= CSIA << csi_port;\n"
     "\t\telse\n"
     "\t\t\tlanes |= (CSIA | CSIB) << csi_port;\n"
     "\t\tnum_ports++;\n")
n = src.count(B)
assert n == 1, "stage6 的 lane 循环锚点命中 %d 次" % n

R = ('\t\t/*\n'
     '\t\t * r32-padcfg: 照 R32 原版 —— 使能 D-PHY 低功耗输入接收器\n'
     '\t\t * (E_INPUT_LP_*) 并解除下电(PD_*)，再复位 CIL。\n'
     '\t\t * stage6 当初跳过了这一段，接收器就一直没上电，表现为 NVCSI\n'
     '\t\t * 一个中断都收不到而 VI 空转超时。\n'
     '\t\t */\n'
     '\t\tif (num_lanes <= 2) {\n'
     '\t\t\tunsigned int addr;\n'
     '\n'
     '\t\t\tlanes |= CSIA << csi_port;\n'
     '\t\t\taddr = (csi_port % 2 == 0 ?\n'
     '\t\t\t\tCSI5_NVCSI_CIL_A_SW_RESET :\n'
     '\t\t\t\tCSI5_NVCSI_CIL_B_SW_RESET);\n'
     '\t\t\tr32_csi5_phy_write(chan, csi_port >> 1, addr,\n'
     '\t\t\t\tCSI5_SW_RESET1_EN | CSI5_SW_RESET0_EN);\n'
     '\t\t} else {\n'
     '\t\t\tunsigned int cila, cilb;\n'
     '\n'
     '\t\t\tlanes |= (CSIA | CSIB) << csi_port;\n'
     '\t\t\tif (num_lanes == 3) {\n'
     '\t\t\t\tcila = (0x01 << CSI5_E_INPUT_LP_IO0_SHIFT) |\n'
     '\t\t\t\t       (0x01 << CSI5_E_INPUT_LP_IO1_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_E_INPUT_LP_CLK_SHIFT) |\n'
     '\t\t\t\t       (0x01 << CSI5_PD_CLK_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_PD_IO0_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_PD_IO1_SHIFT);\n'
     '\t\t\t\tcilb = (0x01 << CSI5_E_INPUT_LP_IO0_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_E_INPUT_LP_IO1_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_E_INPUT_LP_CLK_SHIFT) |\n'
     '\t\t\t\t       (0x01 << CSI5_PD_CLK_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_PD_IO0_SHIFT) |\n'
     '\t\t\t\t       (0x01 << CSI5_PD_IO1_SHIFT);\n'
     '\t\t\t} else {\n'
     '\t\t\t\tcila = (0x01 << CSI5_E_INPUT_LP_IO0_SHIFT) |\n'
     '\t\t\t\t       (0x01 << CSI5_E_INPUT_LP_IO1_SHIFT) |\n'
     '\t\t\t\t       (0x01 << CSI5_E_INPUT_LP_CLK_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_PD_CLK_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_PD_IO0_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_PD_IO1_SHIFT);\n'
     '\t\t\t\tcilb = (0x01 << CSI5_E_INPUT_LP_IO0_SHIFT) |\n'
     '\t\t\t\t       (0x01 << CSI5_E_INPUT_LP_IO1_SHIFT) |\n'
     '\t\t\t\t       (0x01 << CSI5_PD_CLK_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_PD_IO0_SHIFT) |\n'
     '\t\t\t\t       (0x00 << CSI5_PD_IO1_SHIFT);\n'
     '\t\t\t}\n'
     '\t\t\tr32_csi5_phy_write(chan, csi_port >> 1,\n'
     '\t\t\t\tCSI5_NVCSI_CIL_A_BASE + CSI5_PAD_CONFIG_0, cila);\n'
     '\t\t\tr32_csi5_phy_write(chan, csi_port >> 1,\n'
     '\t\t\t\tCSI5_NVCSI_CIL_B_BASE + CSI5_PAD_CONFIG_0, cilb);\n'
     '\t\t\tr32_csi5_phy_write(chan, csi_port >> 1,\n'
     '\t\t\t\tCSI5_NVCSI_CIL_A_SW_RESET,\n'
     '\t\t\t\tCSI5_SW_RESET1_EN | CSI5_SW_RESET0_EN);\n'
     '\t\t\tr32_csi5_phy_write(chan, csi_port >> 1,\n'
     '\t\t\t\tCSI5_NVCSI_CIL_B_SW_RESET,\n'
     '\t\t\t\tCSI5_SW_RESET1_EN | CSI5_SW_RESET0_EN);\n'
     '\t\t\tdev_info_once(csi->dev,\n'
     '\t\t\t\t      "r32-padcfg: CIL pads on port=%u lanes=%u cila=0x%x cilb=0x%x\\n",\n'
     '\t\t\t\t      csi_port, num_lanes, cila, cilb);\n'
     '\t\t}\n'
     '\t\tnum_ports++;\n')
src = src.replace(B, R, 1)

open(F, "w").write(src)
print("  ✅ csi5_fops.c: 补齐 CIL pad 配置 + SW reset（R32 原版）")
print("     r32-padcfg %d 处 / phy_write %d 处"
      % (src.count("r32-padcfg"), src.count("r32_csi5_phy_write")))
