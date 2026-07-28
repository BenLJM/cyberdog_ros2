#!/usr/bin/env python3
# =============================================================================
#  给 extlinux 的 LABEL jp5 加 hung_task panic 参数（零内核零 DTB，与 ramoops 同法）
#
#  目的：把「probe 挂死」变成「panic → ramoops 记录现场 → panic=15 热重启 → 自动恢复」，
#        实现**无人干预**的内核实验闭环。
#
#  为什么是 hung_task 而不是 softlockup：
#    softlockup_panic 编译时就是 1（CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y），
#    而变体 B 炸掉时**并没有**自己热重启（4 分钟死寂）——
#    说明它不是「CPU 卡在内核态不调度」，而是 **D 状态永久等待**
#    （wait_for_completion / mutex 之类），那归 hung_task 检测器管，
#    而 hung_task_panic 默认是 0。
#
#  为什么必须走 cmdline 而不是 sysctl：
#    probe 挂死发生在 userspace 之前，那时 sysctl 根本还没跑。
#
#  时序可行性：hung_task_init() 是 subsys_initcall(level 4)，
#    驱动 probe 多在 device_initcall(level 6) —— khungtaskd 先启动，抓得到。
#
#  误报风险：6 次历史开机 + 本次，dmesg/黑匣子里 hung_task 命中全为 0。
# =============================================================================
import re
import shutil
import sys

CONF = "/mnt/emmcp1/boot/extlinux/extlinux.conf"
BAK = CONF + ".pre-hungtask"
ADD = ["hung_task_panic=1", "hung_task_timeout_secs=60"]

src = open(CONF).read()

# 只动 LABEL jp5 这一段
m = re.search(r"(?ms)^(LABEL jp5\b.*?)(?=^LABEL |\Z)", src)
if not m:
    print("FATAL: 找不到 LABEL jp5")
    sys.exit(1)
block = m.group(1)

if all(a.split("=")[0] in block for a in ADD):
    print("参数已存在，无需改动")
    sys.exit(0)

lines = block.split("\n")
done = False
for i, ln in enumerate(lines):
    if ln.strip().startswith("APPEND"):
        add = " ".join(a for a in ADD if a.split("=")[0] not in ln)
        lines[i] = ln.rstrip() + " " + add
        done = True
        break
if not done:
    print("FATAL: LABEL jp5 段里没有 APPEND 行")
    sys.exit(1)

newblock = "\n".join(lines)
out = src[: m.start(1)] + newblock + src[m.end(1) :]

shutil.copy2(CONF, BAK)
open(CONF, "w").write(out)

# 复核：只有 jp5 段被改，别的 LABEL 一行都不能动
old_labels = re.findall(r"(?ms)^(LABEL (?!jp5)\w+.*?)(?=^LABEL |\Z)", src)
new_labels = re.findall(r"(?ms)^(LABEL (?!jp5)\w+.*?)(?=^LABEL |\Z)", out)
print("备份     : %s" % BAK)
print("其它 LABEL 未被改动: %s" % (old_labels == new_labels))
print("DEFAULT  : %s" % (re.search(r"^DEFAULT\s+(\S+)", out, re.M).group(1)))
print("新 APPEND 尾部:")
print("  ..." + [l for l in newblock.split("\n") if l.strip().startswith("APPEND")][0][-120:])
