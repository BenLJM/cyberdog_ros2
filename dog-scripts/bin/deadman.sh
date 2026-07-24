#!/bin/bash
RPM=""
for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name 2>/dev/null)" = "pwm_tach" ] && RPM=$h/rpm; done
while true; do
  { date "+%F %T"; uptime; free -m | sed -n 2p
    echo "cpu_temp=$(cat /sys/kernel/debug/bpmp/debug/soctherm/group_CPU/temp 2>/dev/null) rpm=$(cat $RPM 2>/dev/null)"
    echo ---; } >> /var/log/deadman.log
  sync
  sleep 20
done
