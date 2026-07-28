#!/bin/bash
# =============================================================================
#  R32 真采集实验 v2 —— 域上电状态下打 V4L2 直采（E2 内核上执行）
#
#  历史：0726 同样的采集尝试死在 `rce-noc Host read timeout at 0x15a303cc`——
#  那是 RCE 在【域断电】时读 NVCSI stream4 的必然结果。
#  现在：R32 电源契约先把 ve/ispa 上电，再打同样的采集。
#
#  胜负手判据（NOTES §7.4 C 层）：
#    dmesg 出现 `r32-abi: VI channel setup accepted` = 0x10 控制面通了
#
#  保护：hung_task_panic=1 armed；每步 kmsg 面包屑；DEFAULT 已是 jp5(good)。
#  修正 v1 缺陷：restore 先 unbind(此时 param 仍=1, group_idle 会执行释放引用)
#  再关 param，不再泄漏 busy 引用。
# =============================================================================
set -u
crumb() { echo "<4>R32CAP: $*" > /dev/kmsg; echo "── $*"; }

PGVE=/sys/kernel/debug/bpmp/debug/powergate/ve/state
PGISPA=/sys/kernel/debug/bpmp/debug/powergate/ispa/state
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
DEV=bc00000.rtcpu

# v4l2-ctl 在宿主还是 chroot
V4L2=""
command -v v4l2-ctl >/dev/null && V4L2="v4l2-ctl"
[ -z "$V4L2" ] && [ -x /mnt/jp4/usr/bin/v4l2-ctl ] && V4L2="chroot /mnt/jp4 v4l2-ctl"
[ -n "$V4L2" ] || { echo "FATAL: 找不到 v4l2-ctl"; exit 1; }
echo "v4l2-ctl = $V4L2"

MARK_BEFORE=$(dmesg | grep -c "r32-abi:" || true)
NOC_BEFORE=$(dmesg | grep -ci "rce-noc" || true)

crumb "step1 stop stack"
systemctl stop jp5-cyberdog-stack.service; sleep 3

crumb "step2 arm param=1"
echo 1 > "$PARAM"

crumb "step3 rtcpu rebind (power domains up + fresh RCE)"
echo "$DEV" > "$DRV/unbind"; sleep 2
echo "$DEV" > "$DRV/bind"; sleep 3
echo "  ve=$(cat $PGVE) ispa=$(cat $PGISPA)  (都应为 1)"
[ "$(cat $PGVE)" = "1" ] || { echo "FATAL: VE 没上电，中止采集"; exit 1; }

crumb "step4 CAPTURE ATTEMPT video0 ov7251 640x480 BG10 x10 frames"
timeout 45 $V4L2 -d /dev/video0 \
    --set-fmt-video=width=640,height=480,pixelformat=BG10 \
    --stream-mmap --stream-count=10 --stream-to=/dev/null 2>&1 | tail -4
RC=$?
crumb "step5 capture rc=$RC -- SURVIVED"

echo "════ 取证 ════"
echo "  --- 胜负手：r32-abi 标记（此前从未出现过）---"
dmesg | grep "r32-abi:" | tail -6 || echo "  (无)"
echo "  r32-abi 标记数: before=$MARK_BEFORE now=$(dmesg | grep -c 'r32-abi:' || true)"
echo "  --- 崩溃指纹 ---"
echo "  rce-noc: before=$NOC_BEFORE now=$(dmesg | grep -ci rce-noc || true)"
echo "  oops=$(dmesg | grep -c 'Unable to handle')  smmu=$(dmesg | grep -ci 'context fault')"
echo "  RTCPU gone bad: $(dmesg | grep -ci 'gone bad')"
echo "  --- 采集路径 dmesg 尾部 ---"
dmesg | grep -iE "vi |capture|nvcsi|rce|rtcpu" | tail -12

crumb "step6 restore: unbind FIRST (param still 1 -> group_idle releases refs)"
echo "$DEV" > "$DRV/unbind" 2>/dev/null; sleep 1
echo 0 > "$PARAM"
echo "$DEV" > "$DRV/bind" 2>/dev/null; sleep 2
echo "  restore 后 ve=$(cat $PGVE) ispa=$(cat $PGISPA)  (应回 0)"

crumb "step7 restart stack"
systemctl start jp5-cyberdog-stack.service
crumb "experiment v2 complete"
