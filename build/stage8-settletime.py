#!/usr/bin/env python3
"""Stage-8：cil_settletime 为 0 时由内核算出来（R32 固件不会自己算）。

2026-07-29 定位：
  stage6+stage7 之后 MIPI 校准真的执行且成功了（`calibration failed -1` 消失），
  传感器也确认在发，但 NVCSI 依旧一个中断都收不到。再往下看 csi5 发给 RCE 的
  CIL 配置：

      cil_config.t_hs_settle = cil_settletime;      /* ← DT 里是 0 */
      cil_config.mipi_clock_rate = read_mipi_clk_from_dt(chan) / 1000;

  ov13b10 的 DT 写的是 `cil_settletime = "0"`，含义是【自动计算】。
  R35 的 RCE 固件收到 0 会自己按 mipi_clock_rate 推算；**R32 固件不会** ——
  R32 时代这个值是内核算好再下发的。t_hs_settle=0 意味着 CIL 的 HS 建立时间
  窗口为零，永远检测不到 HS 跳变 ⇒ 收不到任何数据、也不报错，与实测完全吻合。

  对照组就在同一棵树里：csi4_fops.c 是这么干的
      csi_settletime = tegra_csi_clk_settling_time(csi, cil_clk_mhz);
      if (!cil_settletime)          /* If cil_settletime is 0, calculate it */
              cil_settletime = tegra_csi_ths_settling_time(csi, cil_clk_mhz,
                                                           mipi_clk_mhz);
  csi5 走 RCE，所以上游把这段省掉了。

修法：门控下补上同一次计算。`tegra_csi_ths_settling_time()` 是现成的导出函数
（csi.c，声明在 media/csi.h，csi5_fops.c 已 include）。

  本机预期值：cil=204MHz（stage3 的 cil_clock_rate=204000 kHz）、
              mipi=448MHz（ov13b10 mode0 的 pix_clk_hz）
              t_hs_settle = (115*204 + 8000*204/(2*448) - 5500)/1000 = 19
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c")

src = open(F).read()
if "r32-settle" in src:
    print("FATAL: csi5_fops.c 已注入过 stage8")
    sys.exit(1)

A = ("\t/* CIL config */\n"
     "\tmemset(&cil_config, 0, sizeof(cil_config));\n")
n = src.count(A)
assert n == 1, "锚点命中 %d 次" % n

R = ('''#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)
	/*
	 * r32-settle: DT 里 cil_settletime=0 的含义是"自动计算"。R35 的 RCE 固件
	 * 会自己算，R32 固件不会（R32 时代由内核算好下发）。发 0 过去等于把 CIL 的
	 * HS 建立窗口设成零 —— 永远检测不到 HS 跳变，表现为传感器在发但 NVCSI
	 * 零中断零错误。算法与同树的 csi4_fops.c 完全一致。
	 * CIL 核心时钟取 204 MHz，与 stage3 下发的 cil_clock_rate=204000(kHz) 一致。
	 */
	if (tegra_camrtc_r32_camera_power_enabled() && cil_settletime == 0U &&
	    !chan->pg_mode && s_data != NULL) {
		u64 mipi_clk = read_mipi_clk_from_dt(chan);
		unsigned int mipi_clk_mhz = (unsigned int)(mipi_clk / 1000000ULL);

		if (mipi_clk_mhz != 0U) {
			cil_settletime = tegra_csi_ths_settling_time(csi,
					R32_CIL_CLK_MHZ, mipi_clk_mhz);
			dev_info(csi->dev,
				 "r32-settle: t_hs_settle=%u (cil=%u MHz mipi=%u MHz)\\n",
				 cil_settletime, R32_CIL_CLK_MHZ, mipi_clk_mhz);
		} else {
			dev_warn(csi->dev,
				 "r32-settle: mipi clock unknown, leaving t_hs_settle=0\\n");
		}
	}
#endif

''' + A)
src = src.replace(A, R, 1)

# 常量 + 门控 extern（挂在最后一个 #include 之后；stage6 已插过 include 块，
# 这里再追加一段独立的，互不干扰）
import re
incs = re.findall(r"(?m)^#include .*$", src)
assert incs, "找不到 include"
last = incs[-1] + "\n"
DECL = last + ('\n#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n'
               '/* stage3 下发的 CIL 核心时钟(kHz) 折成 MHz —— 两处必须一致 */\n'
               '#define R32_CIL_CLK_MHZ 204U\n'
               '#endif\n')
assert src.count(last) >= 1
src = src.replace(last, DECL, 1)

open(F, "w").write(src)
print("  ✅ csi5_fops.c: cil_settletime==0 时按 csi4 同款公式补算")
print("     r32-settle %d 处" % src.count("r32-settle"))
