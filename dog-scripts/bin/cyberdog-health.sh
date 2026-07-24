#!/bin/bash
# CyberDog 长稳基线采集器 (2026-07-25)
# 只读 /proc /sys,只写一个 TSV。目的:把"没发现崩溃"这种基于一次 26 分钟引导快照的
# 结论,换成真实的多小时曲线。三条判据:
#   MemAvailable 单调下降 = 泄漏 / 某节点 RSS 单调增长 = 定位到节点 / 温度爬升 = 散热退化
set -u
OUT=/var/log/cyberdog-health.tsv
WATCH="decisionmaker athena_audio pulseaudio camera_server"

[ -s "$OUT" ] || printf "ts\tuptime_s\tload1\tmem_avail_kb\tcpu_c\tgpu_c\tfan_rpm\tcpu_khz\tthrottled\t%s\n" \
    "$(for p in $WATCH; do printf "rss_%s\t" "$p"; done)" > "$OUT"

while true; do
    up=$(cut -d. -f1 /proc/uptime)
    l1=$(cut -d' ' -f1 /proc/loadavg)
    ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    cc=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null); cc=$((${cc:-0}/1000))
    gc=$(cat /sys/class/thermal/thermal_zone1/temp 2>/dev/null); gc=$((${gc:-0}/1000))
    rpm=$(cat /sys/class/hwmon/hwmon*/rpm 2>/dev/null | head -1)
    khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    thr=$(grep -c THERMAL-THROTTLE /var/log/fanboy.log 2>/dev/null || echo 0)
    line="$(date +%s)\t$up\t$l1\t$ma\t$cc\t$gc\t${rpm:-0}\t${khz:-0}\t$thr"
    for p in $WATCH; do
        pid=$(pgrep -x "$p" 2>/dev/null | head -1)
        r=0; [ -n "$pid" ] && r=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null)
        line="$line\t${r:-0}"
    done
    printf "%b\n" "$line" >> "$OUT"
    # 防止无限增长:超过 20000 行(约 14 天)裁掉前半
    n=$(wc -l < "$OUT"); [ "$n" -gt 20000 ] && { tail -10000 "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"; }
    sleep 60
done
