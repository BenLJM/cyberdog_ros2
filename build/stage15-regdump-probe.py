#!/usr/bin/env python3
"""Stage-15：NVCSI 接收端寄存器 debugfs（重做版，建在 probe 而非握手路径）。

stage12 的想法是对的、实现的挂点是错的：它把 `debugfs_create_file()` 挂在
`tegra194_nvcsi_finalize_poweron()` 里 —— 那条路径是被 RCE 握手计时的，
分配内存 + 取互斥锁把它拖慢之后，后续消息超时，变体 Q 因此出现
`vi capture set config failed` 回归。

本版改挂 `t194_nvcsi_late_probe()`（冷路径，只在驱动 probe 时跑一次），
读的时候再检查门控与 io 映射。

要回答的问题（到目前为止唯一还没拿到一手证据的）：
    **接收端到底有没有在物理层看到任何跳变？**
其余各层都已验证正确或排除：发射侧逐寄存器、MIPI 校准、CIL 低功耗时钟(0004)、
NVCSI 数据路时钟(314MHz=BPMP 硬上限)、CSI 流配置、VI 包匹配(one-hot)、
描述符布局、消息 ABI、RCE 握手与 trace 解码。

映射（`csi5_hw_init` 里写死的）：
    stream 0 → +0x10000    stream 2 → +0x20000    stream 4 → +0x30000
块内偏移沿用同 IP 家族的 `csi4_registers.h`。

⚠️ 纯读，不写任何寄存器；读之前查门控，避免在未上电时访问。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/video/tegra/host/nvcsi/nvcsi-t194.c")

src = open(F).read()
if "r32-nvcsi-regdump" in src:
    print("FATAL: 已注入过 stage15")
    sys.exit(1)
assert "r32-stage2" in src, "必须在 stage2 之后运行（要用 nvcsi->io）"

# ---- 1. seq_file 实现（放在 late_probe 之前）----
A = "int t194_nvcsi_late_probe(struct platform_device *pdev)\n"
n = src.count(A)
assert n == 1, "late_probe 锚点命中 %d 次" % n

R = '''/* ---------------------------------------------------------------------------
 *  r32-nvcsi-regdump：NVCSI 接收端寄存器只读快照
 *
 *  到目前为止唯一还没拿到一手证据的问题：接收端到底有没有在物理层看到跳变。
 *  （其余各层都已验证正确或排除。）
 *
 *  ⚠️ 建在 probe 这条冷路径上 —— stage12 把它挂在 finalize_poweron，
 *     那条路径被 RCE 握手计时，拖慢后直接引入 VI 回归。
 *
 *  用法（门控打开、rtcpu 起来之后）：
 *      cat /sys/kernel/debug/r32-nvcsi-regdump
 * ------------------------------------------------------------------------- */
static const u32 r32_rd_base[3] = { 0x10000, 0x20000, 0x30000 };
static const u32 r32_rd_sid[3]  = { 0, 2, 4 };

static int nvcsi_r32_regdump_show(struct seq_file *s, void *data)
{
	struct t194_nvcsi *nvcsi = s->private;
	unsigned int i, off;

	if (nvcsi == NULL || nvcsi->io == NULL) {
		seq_puts(s, "nvcsi io not mapped\\n");
		return 0;
	}
	if (!tegra_camrtc_r32_camera_power_enabled()) {
		seq_puts(s, "gate off\\n");
		return 0;
	}

	for (i = 0; i < ARRAY_SIZE(r32_rd_base); i++) {
		void __iomem *b = nvcsi->io + r32_rd_base[i];

		seq_printf(s, "=== stream %u (base 0x%05x) ===\\n",
			   r32_rd_sid[i], r32_rd_base[i]);
		for (off = 0; off < 0x100; off += 0x10)
			seq_printf(s, "  +0x%03x: %08x %08x %08x %08x\\n", off,
				   readl(b + off), readl(b + off + 4),
				   readl(b + off + 8), readl(b + off + 12));
	}
	return 0;
}

static int nvcsi_r32_regdump_open(struct inode *inode, struct file *file)
{
	return single_open(file, nvcsi_r32_regdump_show, inode->i_private);
}

static const struct file_operations nvcsi_r32_regdump_fops = {
	.owner = THIS_MODULE,
	.open = nvcsi_r32_regdump_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

''' + A
src = src.replace(A, R, 1)

# ---- 2. late_probe 末尾创建（冷路径）----
B = ("\tnvcsi->pdev = pdev;\n"
     "\tnvcsi->csi.fops = &csi5_fops;\n")
n = src.count(B)
assert n == 1, "late_probe 内部锚点命中 %d 次" % n
src = src.replace(
    B,
    B +
    "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
    "\t/* r32-nvcsi-regdump: 冷路径创建，读的时候再查门控。 */\n"
    "\t(void)debugfs_create_file(\"r32-nvcsi-regdump\", 0400, NULL,\n"
    "\t\t\t\t  nvcsi, &nvcsi_r32_regdump_fops);\n"
    "#endif\n", 1)

open(F, "w").write(src)
print("  ✅ nvcsi-t194.c: debugfs 建在 late_probe（冷路径）")
print("     r32-nvcsi-regdump %d 处" % src.count("r32-nvcsi-regdump"))
