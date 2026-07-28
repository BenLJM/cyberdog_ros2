#!/bin/bash
# Stage-2 终极实验：prod + MIPI 校准就位后，能不能出真帧
set -u
crumb() { echo "<4>R32G: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
DEV=bc00000.rtcpu

echo "════ 0. Stage-2 静态就位检查 ════"
echo "  mipical DT : $(tr -d '\0' < /proc/device-tree/mipical@3990000/status 2>/dev/null)"
echo "  mipical dev: $(ls -d /sys/devices/platform/3990000.mipical 2>/dev/null || echo 无)"
echo "  nvcsi 设备 : $(ls /sys/devices/platform/13e10000.host1x/ 2>/dev/null | grep nvcsi; ls -d /sys/devices/platform/15a00000.nvcsi 2>/dev/null || true)"
echo "  探针日志   : $(dmesg | grep -c r32-stage2) 条 r32-stage2"
dmesg | grep "r32-stage2" | head -3

crumb "step1 stop stack + arm + rebind (prod thread + mipi cal will fire)"
systemctl stop jp5-cyberdog-stack.service; sleep 3
echo 1 > "$PARAM"
echo "$DEV" > "$DRV/unbind"; sleep 2
echo "$DEV" > "$DRV/bind"; sleep 2
echo "  ve=$(cat /sys/kernel/debug/bpmp/debug/powergate/ve/state)"
# 给 prod 线程时间(rtcpu poweron ~120ms + 校准)
sleep 4
echo "  --- rebind 后的 stage2 日志 ---"
dmesg | grep -E "r32-power|r32-stage2|mipical|mipi_cal" | tail -8

crumb "step2 CAPTURE 10 frames to file"
rm -f /tmp/frames.raw
echo "<4>R32G: ===CAP-START===" > /dev/kmsg
timeout 40 v4l2-ctl -d /dev/video0 \
    --set-fmt-video=width=640,height=480,pixelformat=BG10 \
    --stream-mmap --stream-count=10 --stream-to=/tmp/frames.raw 2>&1 | tail -3
echo "<4>R32G: ===CAP-END===" > /dev/kmsg

echo "════ 判决 ════"
SZ=$(stat -c %s /tmp/frames.raw 2>/dev/null || echo 0)
echo "  帧文件大小 : $SZ 字节   (10 帧 640x480x2B ≈ 6144000; 0=没出帧)"
echo "  --- 采集窗口日志 ---"
dmesg | sed -n "/===CAP-START===/,/===CAP-END===/p" | grep -vE "===CAP" | head -12
echo "  timeout 次数: $(dmesg | sed -n '/===CAP-START===/,/===CAP-END===/p' | grep -c 'timed out' || true)"
if [ "$SZ" -gt 0 ]; then
    echo "  🏆🏆🏆 有数据！前 64 字节："
    xxd -l 64 /tmp/frames.raw
    echo "  非零字节数(前1MB): $(head -c 1048576 /tmp/frames.raw | tr -d '\0' | wc -c)"
fi

crumb "step3 restore (unbind first, then param=0)"
echo "$DEV" > "$DRV/unbind" 2>/dev/null; sleep 1
echo 0 > "$PARAM"
echo "$DEV" > "$DRV/bind" 2>/dev/null; sleep 2
systemctl start jp5-cyberdog-stack.service
crumb "frames experiment complete"
