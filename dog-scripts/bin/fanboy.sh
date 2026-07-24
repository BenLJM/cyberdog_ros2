#!/bin/bash
# CyberDog JP5 温控守护 v2  (2026-07-25)
#
# 硬件事实:这块板子 PWM 极性是反的 —— pwm=0 → 全速(~4258rpm),pwm=255 → 最慢(~882rpm)。
#   这不是 bug。通用 pwm-fan.c 走内核路径时由 DTB 里降序的 cooling-levels 补偿,
#   端到端是自洽的。**绝对不要去"修"极性。**
#   附带好处:PWM 失能/驱动没起 = 全速 = fail-safe。
#
# v2 相对 v1 修掉的三个缺陷:
#   1. hwmon 路径只在启动时枚举一次 → 改成每轮重新枚举(设备重新绑定后 v1 会写到不存在的路径)
#   2. 读温失败时默认 60000(=按 60°C 吹 pwm=40) → 改成 **默认全速**,任何失败路径都往安全侧倒
#   3. 92°C 的保命动作只有 pkill cc1plus/make(编译专用,对 ROS2 机器人负载完全无效)
#      → 改成通用的 cpufreq 封顶 + 迟滞恢复(运行时生效、不持久化、可自恢复)
#
# 与内核原生保护的关系:内核有 90.5°C 被动降频 + 96°C critical(已实测注册成功),
#   本脚本是它之外的第二道,不是唯一一道。

set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TS=/sys/kernel/debug/bpmp/debug/soctherm/group_CPU/temp
LOG=/var/log/fanboy.log
PWM_FULL=0          # 反极性:0 = 全速
THROTTLE_ON=92      # 达到即封顶 CPU 频率
THROTTLE_OFF=82     # 降到此值以下才解除(迟滞,防抖)
THROTTLE_KHZ=1190400
throttled=0

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }

# 每轮重新枚举风扇 —— 设备重新绑定/驱动重载后路径会变
fans() {
    for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name" 2>/dev/null)" = "pwmfan" ] && echo "$h/pwm1"
    done
}

set_fan() {
    local p="$1" n=0
    for f in $(fans); do echo "$p" > "$f" 2>/dev/null && n=$((n+1)); done
    # 一个风扇都没找到是严重情况:内核侧无人控风扇,而我们也写不进去
    [ "$n" = 0 ] && log "WARN: 找不到任何 pwmfan hwmon 节点 —— 风扇不在本脚本控制下"
    return 0
}

# 恢复目标必须是 nvpmodel 当前功耗模式的上限,不是 cpuinfo_max_freq。
# 15W_6CORE 模式下 scaling_max=1420800 而 cpuinfo_max=1907200 —— 用后者恢复
# 会把频率顶到超出功耗预算,降温反而变过热。BASE 在未封顶时每轮刷新,
# 这样 nvpmodel 模式被改了也能自动跟上。
BASE_KHZ=""

cpu_cap() {   # $1 = 频率(kHz) 或 "base"
    local tgt="$1"
    [ "$tgt" = base ] && tgt="$BASE_KHZ"
    [ -n "$tgt" ] || return 0
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -w "$c/scaling_max_freq" ] || continue
        echo "$tgt" > "$c/scaling_max_freq" 2>/dev/null
    done
}

log "fanboy v2 启动 (反极性: 0=全速; 迟滞封顶 ${THROTTLE_ON}→${THROTTLE_OFF}°C)"

while true; do
    t=$(cat "$TS" 2>/dev/null)

    # ---- 失败即全速(v1 在这里默认 60°C,是把机器交给运气) ----
    case "$t" in
        ''|*[!0-9]*)
            set_fan "$PWM_FULL"
            log "读温失败(值='${t}') —— 已按 fail-safe 拉满风扇"
            sleep 10
            continue
            ;;
    esac
    c=$((t/1000))

    # ---- 风扇曲线(反极性:数值越小越快) ----
    if   [ "$c" -ge 70 ]; then p=0
    elif [ "$c" -ge 65 ]; then p=20
    elif [ "$c" -ge 60 ]; then p=40
    elif [ "$c" -ge 50 ]; then p=100
    else                       p=160
    fi
    set_fan "$p"

    # ---- 通用保命阀:CPU 频率封顶 + 迟滞恢复 ----
    if [ "$throttled" = 0 ]; then
        # 未封顶时持续跟踪 nvpmodel 的实际上限,作为恢复目标
        b=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
        case "$b" in ''|*[!0-9]*) ;; *) BASE_KHZ="$b" ;; esac
    fi
    if [ "$throttled" = 0 ] && [ "$c" -ge "$THROTTLE_ON" ]; then
        cpu_cap "$THROTTLE_KHZ"; throttled=1
        log "THERMAL-THROTTLE ${c}C —— CPU 频率封顶 ${THROTTLE_KHZ}kHz (恢复目标 ${BASE_KHZ}kHz)"
    elif [ "$throttled" = 1 ] && [ "$c" -le "$THROTTLE_OFF" ]; then
        cpu_cap base; throttled=0
        log "THERMAL-RECOVER ${c}C —— CPU 频率恢复到 ${BASE_KHZ}kHz"
    fi

    sleep 10
done
