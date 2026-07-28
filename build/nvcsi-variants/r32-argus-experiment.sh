#!/bin/bash
# =============================================================================
#  路线 A：用真正的目标用户态(argus/nvargus)验证 —— reloc pass 自动生效
#
#  2026-07-28 发现：r32_reloc_vi_capture_request_buffers_locked() 只挂在
#  VI_CAPTURE_REQUEST **ioctl** 分支上，那是 chroot 里 argus 走的路；
#  v4l2-ctl 走内核内部 vi_capture_request()，绕过了 reloc pass。
#  这是工程真正要支持的场景(出厂 ROS2 相机节点用的就是 argus)。
#
#  ⚠️ 红线：不对 active 的 camera_server 调 configure。这里只起 nvargus-daemon，
#     用 argus 自带的最小测试程序取流，不碰出厂 ROS2 节点。
# =============================================================================
set -u
crumb() { echo "<4>R32ARG: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
DEV=bc00000.rtcpu
CH=/mnt/jp4

echo "════ 0. chroot 里的 argus 家当 ════"
ls $CH/usr/bin/argus_camera $CH/usr/sbin/nvargus-daemon 2>/dev/null
ls $CH/usr/src/jetson_multimedia_api/argus/ 2>/dev/null | head -3
for b in nvgstcapture-1.0 argus_camera; do
  [ -x "$CH/usr/bin/$b" ] && echo "  ✅ $b"
done
echo "  nvargus-daemon: $(chroot $CH systemctl is-enabled nvargus-daemon 2>/dev/null || echo n/a)"

crumb "step1 stop stack, arm r32 power, rebind rtcpu"
systemctl stop jp5-cyberdog-stack.service 2>/dev/null; sleep 3
echo 1 > "$PARAM"
echo "$DEV" > "$DRV/unbind"; sleep 2
echo "$DEV" > "$DRV/bind"; sleep 3
echo "  ve=$(cat /sys/kernel/debug/bpmp/debug/powergate/ve/state) ispa=$(cat /sys/kernel/debug/bpmp/debug/powergate/ispa/state)"

crumb "step2 start nvargus-daemon inside chroot"
chroot $CH /bin/bash -lc 'pkill -f nvargus-daemon; sleep 1; (nvargus-daemon >/tmp/nvargus.log 2>&1 &) ; sleep 6; pgrep -f nvargus-daemon >/dev/null && echo "  nvargus-daemon 起来了 pid=$(pgrep -f nvargus-daemon|head -1)" || echo "  ⚠️ nvargus-daemon 没起来"'

crumb "step3 ===ARGUS-CAPTURE-START==="
# argus 的最小取流：优先 nvgstcapture，其次 argus_camera
rm -f $CH/tmp/argus-shot.jpg
chroot $CH /bin/bash -lc '
export DISPLAY=
if [ -x /usr/bin/nvgstcapture-1.0 ]; then
    timeout 40 nvgstcapture-1.0 --automate --capture-auto --image-res=2 \
        --file-name=/tmp/argus-shot --sensor-id=0 2>&1 | tail -15
else
    echo "  (无 nvgstcapture，尝试 argus_camera)"
    timeout 40 argus_camera --device=0 --duration=3 2>&1 | tail -15
fi'
crumb "step4 ===ARGUS-CAPTURE-END==="

echo "════ 判决 ════"
ls -l $CH/tmp/argus-shot* 2>/dev/null && echo "  🏆 有图像文件！" || echo "  无图像文件"
echo "── r32-abi / reloc / 超时 ──"
dmesg | sed -n "/===ARGUS-CAPTURE-START===/,/===ARGUS-CAPTURE-END===/p" | \
    grep -iE "r32-abi|r32-vi5|r32-csi5|reloc|timed out|VINOTIFY|gone bad|rce-noc" | head -14
echo "── 超时次数: $(dmesg | sed -n '/===ARGUS-CAPTURE-START===/,/===ARGUS-CAPTURE-END===/p' | grep -c 'timed out' || true) ──"
echo "── nvargus 日志尾部 ──"
tail -12 $CH/tmp/nvargus.log 2>/dev/null

crumb "step5 restore"
chroot $CH /bin/bash -lc 'pkill -f nvargus-daemon' 2>/dev/null
echo "$DEV" > "$DRV/unbind" 2>/dev/null; sleep 1
echo 0 > "$PARAM"
echo "$DEV" > "$DRV/bind" 2>/dev/null; sleep 2
systemctl start jp5-cyberdog-stack.service
crumb "argus experiment complete"
