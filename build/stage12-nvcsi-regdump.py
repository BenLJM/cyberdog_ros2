#!/usr/bin/env python3
"""Stage-12：加一个 debugfs 把 NVCSI 的接收端寄存器 dump 出来。

为什么需要它：
  到 stage11 为止，链路上每一环都验证正确（传感器 streaming、MIPI 校准成功、
  CSI 配置参数与时序全对、ISP/VI 通道 accepted、RCE 握手、描述符 IOVA+sync），
  但仍然零帧。手上唯一的"接收端"证据是 RCE 的 ftrace 三计数全 0 ——
  **而那三个计数本身可疑**：
    · stage3 为对齐 R32 语义把 csi5 的 error_config 设成了全零（错误通知本就关着）
    · rtcpu_vinotify_* 的解码依赖 RCE 的 trace 记录格式，R32 固件未必按 R35 的发
  需要一个【不依赖 RCE、不依赖 trace 解码】的独立测量：直接读 NVCSI 的寄存器，
  看接收端到底有没有看到 HS 跳变 / 报没报错。

  从用户态读不了：CONFIG_STRICT_DEVMEM=y 挡住了 /dev/mem。所以只能加 debugfs。

映射关系（csi5_hw_init 里写死的）：
    stream 0 → iomem_base + 0x10000
    stream 2 → iomem_base + 0x20000
    stream 4 → iomem_base + 0x30000   ← ov13b10 主相机走这个（tegra_sinterface=serial_e）
块内偏移沿用同 IP 家族的 csi4_registers.h：
    0x90 ERROR_STATUS2VI_MASK   0x94 ERROR_STATUS2VI_VC0
    0xa4 INTR_STATUS            0xac ERR_INTR_STATUS

⚠️ 只在门控打开时暴露；读寄存器要求设备已上电（rtcpu 起来之后再读）。
⚠️ 纯读，不写任何寄存器。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/video/tegra/host/nvcsi/nvcsi-t194.c")

src = open(F).read()
if "r32-regdump" in src:
    print("FATAL: 已注入过 stage12")
    sys.exit(1)
assert "r32-stage2" in src, "必须在 stage2 之后运行（要用 nvcsi->io / nvcsi->dir）"

A = "int tegra194_nvcsi_finalize_poweron(struct platform_device *pdev)\n"
n = src.count(A)
assert n == 1, "finalize_poweron 锚点命中 %d 次" % n

R = '''/* ---------------------------------------------------------------------------
 *  r32-regdump: NVCSI 接收端寄存器只读快照
 *
 *  到 stage11 为止链路每一环都验证正确却仍零帧，而唯一的接收端证据（RCE ftrace
 *  三计数）本身可疑：stage3 把 error_config 置零=错误通知关着，且 vinotify 的
 *  trace 记录格式 R32 固件未必按 R35 发。这里提供一个不依赖 RCE、不依赖 trace
 *  解码的独立测量 —— 直接读 NVCSI 自己的状态寄存器。
 *
 *  用法（门控打开、rtcpu 起来之后）：
 *      cat /sys/kernel/debug/r32-nvcsi-regdump
 * ------------------------------------------------------------------------- */
static bool r32_regdump_created;
static const u32 r32_stream_base[3] = { 0x10000, 0x20000, 0x30000 };
static const u32 r32_stream_id[3]   = { 0, 2, 4 };

static int nvcsi_r32_regdump_show(struct seq_file *s, void *data)
{
	struct t194_nvcsi *nvcsi = s->private;
	unsigned int i, off;

	if (nvcsi == NULL || nvcsi->io == NULL) {
		seq_puts(s, "nvcsi io not mapped (需要 stage2 的 reg 属性)\\n");
		return 0;
	}
	if (!tegra_camrtc_r32_camera_power_enabled()) {
		seq_puts(s, "gate off — 先 echo 1 > .../r32_camera_power\\n");
		return 0;
	}

	for (i = 0; i < ARRAY_SIZE(r32_stream_base); i++) {
		void __iomem *b = nvcsi->io + r32_stream_base[i];

		seq_printf(s, "=== stream %u (base 0x%05x) ===\\n",
			   r32_stream_id[i], r32_stream_base[i]);
		seq_printf(s, "  ERROR_STATUS2VI_MASK(0x90) = 0x%08x\\n",
			   readl(b + 0x90));
		seq_printf(s, "  ERROR_STATUS2VI_VC0 (0x94) = 0x%08x\\n",
			   readl(b + 0x94));
		seq_printf(s, "  INTR_STATUS         (0xa4) = 0x%08x\\n",
			   readl(b + 0xa4));
		seq_printf(s, "  ERR_INTR_STATUS     (0xac) = 0x%08x\\n",
			   readl(b + 0xac));
		seq_puts(s, "  --- raw 0x000..0x0fc ---\\n");
		for (off = 0; off < 0x100; off += 0x10)
			seq_printf(s,
				   "  +0x%03x: %08x %08x %08x %08x\\n", off,
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

# 在 finalize_poweron 里（存 pdev 那处之后）懒创建 debugfs 文件，只建一次
B = "\tif (!tegra_camrtc_r32_camera_power_enabled())\n\t\treturn 0;\n"
n = src.count(B)
assert n >= 1, "门控锚点没找到"
src = src.replace(
    B,
    B +
    "\tif (!r32_regdump_created) {\n"
    "\t\t/* 挂在 debugfs 顶层：nvcsi->dir 在本树里并不由本驱动填 */\n"
    "\t\t(void)debugfs_create_file(\"r32-nvcsi-regdump\", 0400, NULL,\n"
    "\t\t\t\t\t  nvcsi, &nvcsi_r32_regdump_fops);\n"
    "\t\tr32_regdump_created = true;\n"
    "\t}\n", 1)

open(F, "w").write(src)

print("  ✅ nvcsi-t194.c: 加 debugfs r32-regdump（只读）")
print("     r32-regdump %d 处" % src.count("r32-regdump"))
