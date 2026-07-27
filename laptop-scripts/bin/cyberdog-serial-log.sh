#!/bin/bash
# 解析狗的串口设备并起记录器。
# 优先用 by-id 稳定路径（Tegra 模块序列号烧在 efuse 里，重启不变）；
# ttyACM0 这个编号会随插拔顺序漂，只当兜底。
set -u

BYID="/dev/serial/by-id/usb-NVIDIA_Linux_for_Tegra_1421621045904-if02"
FALLBACK="/dev/ttyACM0"
LOG="/var/log/cyberdog-serial/console.log"

DEV="$BYID"
if [ ! -e "$BYID" ] && [ -e "$FALLBACK" ]; then
    DEV="$FALLBACK"
fi

exec /usr/local/bin/cyberdog-serial-log.py "$DEV" "$LOG"
