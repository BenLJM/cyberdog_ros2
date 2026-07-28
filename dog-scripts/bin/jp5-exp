#!/usr/bin/env python3
# =============================================================================
#  jp5-exp —— 一次性内核实验启动项 管理工具
#  部署路径: /usr/local/bin/jp5-exp   (0755, 狗上以 root 跑)
#
#  用法:
#    jp5-exp arm <Image路径> [DTB路径]   把实验内核装上膛并把 DEFAULT 指向 jp5-exp
#    jp5-exp disarm                      把 DEFAULT 拨回 jp5
#    jp5-exp status                      看当前状态
#
#  机制（与 initrd-exp 里的 flip-back 是一对）:
#    · LABEL jp5-exp 用独立的 Image.exp / dtb.exp / initrd-exp，好路径三件套永不被碰
#    · initrd-exp 的守卫在 pivot 可写后第一时间把 DEFAULT 拨回 jp5（一次性消费）
#    · 实验内核挂死(initrd 之后) → 拔电一次 → 下次启动就是 good 内核，零 RCM
#  边界（诚实声明）:
#    · initrd 之前就挂死的内核不受保护（DEFAULT 已消费不掉）→ 只测运行时门控内核
#      （变体 C 已实证：门控内核的 initcall 能全部跑完）
# =============================================================================
import hashlib
import re
import shutil
import subprocess
import sys

P1 = "/mnt/emmcp1"
CONF = P1 + "/boot/extlinux/extlinux.conf"
BOOT = P1 + "/boot-jp5"
MARK = "jp5exp=1"


def sha(p, n=16):
    h = hashlib.sha256()
    try:
        with open(p, "rb") as f:
            for c in iter(lambda: f.read(1 << 20), b""):
                h.update(c)
        return h.hexdigest()[:n]
    except OSError:
        return "(缺失)"


def mount_p1():
    subprocess.run(["mountpoint", "-q", P1], check=False)
    r = subprocess.run(["mountpoint", "-q", P1])
    if r.returncode != 0:
        subprocess.run(["mkdir", "-p", P1], check=True)
        subprocess.run(["mount", "/dev/mmcblk0p1", P1], check=True)


def read_conf():
    return open(CONF).read()


def write_conf(new):
    """原子写 + 回读校验。extlinux 是引导命脉，写坏 = RCM。"""
    tmp = CONF + ".tmp-exp"
    with open(tmp, "w") as f:
        f.write(new)
    shutil.move(tmp, CONF)
    subprocess.run(["sync"], check=True)
    back = open(CONF).read()
    if back != new:
        print("FATAL: 回读与写入不一致(eMMC 只读或坏了?)")
        sys.exit(1)


def jp5_append(src):
    m = re.search(r"(?ms)^LABEL jp5\s*?$(.*?)(?=^LABEL |\Z)", src)
    if not m:
        print("FATAL: 找不到 LABEL jp5")
        sys.exit(1)
    for ln in m.group(1).splitlines():
        if ln.strip().startswith("APPEND"):
            return ln.strip()[len("APPEND"):].strip()
    print("FATAL: LABEL jp5 里没有 APPEND")
    sys.exit(1)


def ensure_exp_label(src):
    """jp5-exp 段不存在则追加；存在则把 APPEND 刷新成 jp5 当前值 + 标记。
    这样以后 jp5 的 APPEND 变了（比如又加了参数），arm 时会自动跟上。"""
    append = jp5_append(src) + " " + MARK
    block = ("\nLABEL jp5-exp\n"
             "      MENU LABEL JP5 one-shot EXPERIMENT (auto-flips back)\n"
             "      LINUX  /boot-jp5/Image.exp\n"
             "      FDT    /boot-jp5/dtb.exp\n"
             "      INITRD /boot-jp5/initrd-exp\n"
             "      APPEND " + append + "\n")
    if "LABEL jp5-exp" not in src:
        if not src.endswith("\n"):
            src += "\n"
        return src + block
    # 刷新 APPEND
    def repl(m):
        body = m.group(0)
        return re.sub(r"(?m)^(\s*APPEND ).*$", lambda mm: mm.group(1) + append, body)
    return re.sub(r"(?ms)^LABEL jp5-exp\s*?$.*?(?=^LABEL |\Z)", repl, src)


def set_default(src, target):
    new, n = re.subn(r"(?m)^DEFAULT\s+\S+\s*$", "DEFAULT " + target, src)
    if n != 1:
        print("FATAL: DEFAULT 行匹配了 %d 次" % n)
        sys.exit(1)
    return new


def current_default(src):
    m = re.search(r"(?m)^DEFAULT\s+(\S+)", src)
    return m.group(1) if m else "?"


def status():
    src = read_conf()
    print("DEFAULT      : %s" % current_default(src))
    print("jp5-exp 段    : %s" % ("存在" if "LABEL jp5-exp" in src else "无"))
    for f in ("Image", "tegra194-mi-k91.dtb", "initrd",
              "Image.exp", "dtb.exp", "initrd-exp"):
        print("  %-22s %s" % (f, sha(BOOT + "/" + f)))
    r = subprocess.run(["dmesg"], capture_output=True, text=True)
    hits = [l for l in r.stdout.splitlines() if "jp5-exp" in l or MARK in l]
    if hits:
        print("本次开机的 exp 痕迹:")
        for l in hits[-3:]:
            print("  " + l.strip())


def arm(image, dtb=None):
    for f in (image,) + ((dtb,) if dtb else ()):
        try:
            open(f, "rb").close()
        except OSError:
            print("FATAL: 打不开 %s" % f)
            sys.exit(1)
    # 部署三件套（好路径的三件永不被碰）
    shutil.copy2(image, BOOT + "/Image.exp")
    shutil.copy2(dtb if dtb else BOOT + "/tegra194-mi-k91.dtb", BOOT + "/dtb.exp")
    # initrd-exp 必须已就位（由部署流程放好，本工具不生成它）
    if sha(BOOT + "/initrd-exp") == "(缺失)":
        print("FATAL: /boot-jp5/initrd-exp 不存在 —— 先部署带 flip-back 的 initrd")
        sys.exit(1)
    src = ensure_exp_label(read_conf())
    src = set_default(src, "jp5-exp")
    write_conf(src)
    print("✅ 已装上膛：")
    print("   Image.exp  = %s  (%s)" % (sha(BOOT + "/Image.exp"), image))
    print("   dtb.exp    = %s" % sha(BOOT + "/dtb.exp"))
    print("   initrd-exp = %s" % sha(BOOT + "/initrd-exp"))
    print("   DEFAULT    = jp5-exp   (initrd-exp 会在下次启动第一时间拨回 jp5)")
    print("下一步: reboot。挂死的话拔电一次即回 good 内核。")


def disarm():
    src = read_conf()
    src = set_default(src, "jp5")
    write_conf(src)
    print("✅ DEFAULT 已拨回 jp5")


def main():
    mount_p1()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "arm":
        if len(sys.argv) < 3:
            print("用法: jp5-exp arm <Image路径> [DTB路径]")
            sys.exit(2)
        arm(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif cmd == "disarm":
        disarm()
    elif cmd == "status":
        status()
    else:
        print("用法: jp5-exp <arm|disarm|status>")
        sys.exit(2)


if __name__ == "__main__":
    main()
