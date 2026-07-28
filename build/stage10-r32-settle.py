#!/usr/bin/env python3
"""Stage-10：把 settle time 的补算挪到 stage3 自己那条 R32 路径上。

stage8 打在了上游的 csi5_stream_set_config（R35 路径）上，但 stage3 另建了一份
R32 语义的配置函数，实际发消息的是它 —— 实测日志里 `settle=0` 且没有任何
`r32-settle` 输出，就是这个原因（stage9 让消息真的发出去之后才暴露出来）。

stage3 里那行：
    unsigned int cil_settletime = read_settle_time_from_dt(chan);
DT 给的是 0（"自动计算"的约定）。R35 的 RCE 固件会自己算，R32 固件不会 ——
t_hs_settle=0 等于把 CIL 的 HS 建立窗口设成零，永远检测不到 HS 跳变。

这里补上与 csi4_fops.c 完全相同的算法（`tegra_csi_ths_settling_time()`，
同树现成的导出函数）。R32_CIL_CLK_MHZ 由 stage8 定义在同一文件里。
    本机预期：cil=204MHz、mipi=448MHz ⇒ t_hs_settle = 19
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c")

src = open(F).read()
if "r32-settle2" in src:
    print("FATAL: 已注入过 stage10")
    sys.exit(1)
assert "r32-csi5" in src, "必须在 stage3 之后运行"

# ⚠️ 必须插在【声明区之后】的第一条语句处：直接跟在
#    `unsigned int cil_settletime = ...;` 后面会把语句混进声明区，
#    触发 -Werror=declaration-after-statement（本项目踩过两次）。
A = ("\t/* Brick config -- R32 verbatim */\n"
     "\tmemset(&brick_config, 0, sizeof(brick_config));\n")
n = src.count(A)
assert n == 1, "stage3 首条语句锚点命中 %d 次" % n

R = ('\t/*\n'
     '\t * r32-settle2: DT 里 cil_settletime=0 的含义是"自动计算"。R35 的 RCE\n'
     '\t * 固件会自己算，R32 固件不会 —— 发 0 过去 = CIL 的 HS 建立窗口为零，\n'
     '\t * 永远检测不到 HS 跳变。算法与同树的 csi4_fops.c 一致；两个时钟都取\n'
     '\t * stage3 自己的来源，保证与同一条消息里下发的值自洽。\n'
     '\t */\n'
     '\tif (cil_settletime == 0U && chan->pg_mode == 0U && s_data != NULL) {\n'
     '\t\tunsigned int mipi_mhz =\n'
     '\t\t\t(unsigned int)(r32_read_pixel_clk(chan) / 1000000ULL);\n'
     '\n'
     '\t\tif (mipi_mhz != 0U)\n'
     '\t\t\tcil_settletime = tegra_csi_ths_settling_time(chan->csi,\n'
     '\t\t\t\t\tR32_NVCSI_CIL_CLOCK_RATE / 1000U, mipi_mhz);\n'
     '\t}\n'
     '\n' + A)
src = src.replace(A, R, 1)

open(F, "w").write(src)
print("  ✅ csi5_fops.c: stage3 的 R32 路径补上 settle time 计算")
print("     r32-settle2 %d 处" % src.count("r32-settle2"))
