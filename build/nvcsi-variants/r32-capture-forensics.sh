#!/bin/bash
# 采集数据面取证 v3：dynamic debug + 完整首次尝试序列 + mipical/传感器状态
set -u
crumb() { echo "<4>R32F: $*" > /dev/kmsg; echo "── $*"; }

PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
DEV=bc00000.rtcpu
DDC=/sys/kernel/debug/dynamic_debug/control

echo "════ 0. mipical / 传感器 静态状态 ════"
echo "  mipical DT status: $(tr -d '\0' < /proc/device-tree/mipical@3990000/status 2>/dev/null || echo 无节点)"
echo "  mipical platform : $(ls -d /sys/devices/platform/3990000.mipical 2>/dev/null || echo 无设备)"
echo "  ov7251 上电痕迹  : $(dmesg | grep -c ov7251)"

crumb "step1 stop stack + arm + rebind"
systemctl stop jp5-cyberdog-stack.service; sleep 3
echo 1 > "$PARAM"
echo "$DEV" > "$DRV/unbind"; sleep 2
echo "$DEV" > "$DRV/bind"; sleep 3
echo "  ve=$(cat /sys/kernel/debug/bpmp/debug/powergate/ve/state)"

crumb "step2 enable dynamic debug (csi5/capture-vi/vi5/ov7251)"
for pat in "file csi5_fops.c +p" "file capture-vi.c +p" "file vi5_fops.c +p" "file ov7251.c +p" "file mipi_cal.c +p"; do
    echo "$pat" > $DDC 2>/dev/null || true
done

crumb "step3 mark + single capture attempt (3 frames only)"
echo "<4>R32F: ===CAPTURE-WINDOW-START===" > /dev/kmsg
timeout 25 v4l2-ctl -d /dev/video0 \
    --set-fmt-video=width=640,height=480,pixelformat=BG10 \
    --stream-mmap --stream-count=3 --stream-to=/dev/null 2>&1 | tail -2
echo "<4>R32F: ===CAPTURE-WINDOW-END===" > /dev/kmsg

echo "════ 完整首次尝试序列 ════"
dmesg | sed -n "/CAPTURE-WINDOW-START/,/CAPTURE-WINDOW-END/p" | head -60

crumb "step4 sensor probe: ov7251 streaming 寄存器(0x0100)"
# i2c bus 2 addr 0x60/0x61? 从 dmesg 找到的是 2-0061 2-0062(ov7251) 2-0036(ov13b10)
for a in 0x61 0x62; do
    v=$(i2cget -y -f 2 $a 0x01 2>/dev/null || echo ERR)
    echo "  i2c-2 $a reg0x01[高位=0x0100 mode?]: $v"
done

crumb "step5 restore"
for pat in "file csi5_fops.c -p" "file capture-vi.c -p" "file vi5_fops.c -p" "file ov7251.c -p" "file mipi_cal.c -p"; do
    echo "$pat" > $DDC 2>/dev/null || true
done
echo "$DEV" > "$DRV/unbind" 2>/dev/null; sleep 1
echo 0 > "$PARAM"
echo "$DEV" > "$DRV/bind" 2>/dev/null; sleep 2
systemctl start jp5-cyberdog-stack.service
crumb "forensics complete"
