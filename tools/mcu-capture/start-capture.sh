#!/bin/bash
# MCU power-gating capture (review D7) — run on the STOCK system, then trigger
# stand/motion (factory tool, paired app, or stock ROS 2 action), then Ctrl-C.
# Goal: learn what enables the head/body/rear MCU USB links (they are absent at idle).
set -u
D=/home/mi/mcu-capture/capture-$(date +%Y%m%d-%H%M%S)
mkdir -p "$D"
udevadm monitor --kernel --udev --property > "$D/udev.log" 2>&1 &
U=$!
sudo dmesg -wT > "$D/dmesg.log" 2>&1 &
DM=$!
( while true; do echo "$(date +%T.%3N)  tty:[$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tr '\n' ' ')] usb:[$(lsusb | wc -l)]"; sleep 0.5; done ) > "$D/ttyusb-timeline.log" 2>&1 &
T=$!
lsusb > "$D/lsusb-before.txt"
echo "Capturing to $D"
echo ">>> NOW trigger stand / motion on the stock stack. Ctrl-C here when done. <<<"
trap 'kill $U $DM $T 2>/dev/null; lsusb > "$D/lsusb-after.txt"; echo; echo "saved: $D"; ls -la "$D"; exit 0' INT
wait
