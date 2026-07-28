#!/bin/bash
# =============================================================================
#  R32 相机电源契约 —— 运行时实验（变体 C2 内核上执行）
#
#  设计：每步先往 /dev/kmsg 打 <4> 面包屑再动手。万一挂死：
#    hung_task_panic=1 → panic → ramoops 记下【面包屑+call trace】→ panic=15 热重启
#    → DEFAULT 已是 jp5(good) → 狗自动回来 → 黑匣子里有完整现场。全程零人工。
# =============================================================================
set -u
crumb() { echo "<4>R32EXP: $*" > /dev/kmsg; echo "── $*"; }

PGVE=/sys/kernel/debug/bpmp/debug/powergate/ve/state
PGISPA=/sys/kernel/debug/bpmp/debug/powergate/ispa/state
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power

echo "════ 实验前状态 ════"
echo "  ve=$(cat $PGVE) ispa=$(cat $PGISPA) param=$(cat $PARAM)"
echo "  rtcpu 设备与驱动:"
ls -d /sys/bus/platform/drivers/tegra186-cam-rtcpu 2>/dev/null || ls /sys/bus/platform/drivers/ | grep -i rtcpu
DRV=$(ls -d /sys/bus/platform/drivers/*rtcpu* 2>/dev/null | head -1)
DEV=$(ls "$DRV" | grep -E "^[0-9a-f]+\.rtcpu" | head -1)
echo "  DRV=$DRV DEV=$DEV"
[ -n "$DEV" ] || { echo "FATAL: 找不到 rtcpu 设备"; exit 1; }

crumb "step1 stopping factory stack"
systemctl stop jp5-cyberdog-stack.service
sleep 3

crumb "step2 arming r32_camera_power=1"
echo 1 > "$PARAM"
echo "  param=$(cat $PARAM)"

crumb "step3 unbinding $DEV"
echo "$DEV" > "$DRV/unbind"
sleep 2
echo "  unbind 后 ve=$(cat $PGVE) ispa=$(cat $PGISPA)"

crumb "step4 REBIND $DEV -- R32 power contract ACTIVE from here"
echo "$DEV" > "$DRV/bind"
RC=$?
crumb "step5 rebind returned rc=$RC -- SURVIVED"
sleep 3

echo "════ 实验后取证 ════"
echo "  ve=$(cat $PGVE) ispa=$(cat $PGISPA)   ← ve=1 即 R32 契约真的把域上电了"
echo "  --- r32-power / rtcpu / rce 相关 dmesg ---"
dmesg | grep -iE "r32-power|rtcpu|camrtc|rce" | tail -20
echo "  --- genpd ---"
grep -E "^(ve|ispa) " /sys/kernel/debug/pm_genpd/pm_genpd_summary | tr -s " "
echo "  --- 时钟 ---"
grep -E "^\s+(nvcsi|nvcsilp|vi|vi_const)\s" /sys/kernel/debug/clk/clk_summary | tr -s " " | cut -d" " -f1-5
echo "  --- 崩溃指纹 ---"
echo "  oops=$(dmesg | grep -c 'Unable to handle')  noc=$(dmesg | grep -ci rce-noc)  smmu=$(dmesg | grep -ci 'context fault')"

crumb "step6 restore: param=0 + rebind clean"
echo 0 > "$PARAM"
echo "$DEV" > "$DRV/unbind" 2>/dev/null; sleep 1
echo "$DEV" > "$DRV/bind" 2>/dev/null; sleep 2

crumb "step7 restarting factory stack"
systemctl start jp5-cyberdog-stack.service
crumb "experiment complete"
echo "════ 完成 ════"
echo "  ve=$(cat $PGVE) ispa=$(cat $PGISPA) param=$(cat $PARAM)"
