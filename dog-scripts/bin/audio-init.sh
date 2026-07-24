#!/bin/bash
# CyberDog 声卡初始化 v2 (2026-07-25)
# 声卡就绪后:回放 codec 寄存器 + 恢复金标准控件状态 + 摆好基础路由
#
# v2 修掉 v1 的"说谎"问题:v1 无条件 exit 0 且所有步骤 2>/dev/null,
# 于是 python 回放失败、alsactl restore 失败、amixer 失败,systemd 一律显示成功。
# 声卡注册链是刚修好的旧账,慢一次就静默失声而监控全绿。
set -u
RC=0
log() { echo "audio-init: $*"; }          # 走 journal,不再吞掉

# 1. 等声卡注册(最多 60s)
ok=0
for i in $(seq 1 30); do
    if grep -q jetsonxaviernxa /proc/asound/cards 2>/dev/null; then ok=1; break; fi
    sleep 2
done
if [ "$ok" != 1 ]; then
    log "FATAL: 等了 60s 声卡 jetsonxaviernxa 仍未注册 —— /proc/asound/cards:"
    cat /proc/asound/cards 2>&1 | sed 's/^/audio-init:   /'
    exit 1
fi
log "声卡已注册(等待 $((i*2))s)"

# 2. 回放 RT5680 的 753 个寄存器(JP4 金标准)
if [ -r /home/mi/rt5680-regs.txt ]; then
    if python3 /home/mi/rt5680-replay.py /home/mi/rt5680-regs.txt >/tmp/audio-init-replay.log 2>&1; then
        log "RT5680 寄存器回放 OK"
    else
        log "ERROR: RT5680 寄存器回放失败(rc=$?),末尾:"
        tail -5 /tmp/audio-init-replay.log 2>/dev/null | sed 's/^/audio-init:   /'
        RC=1
    fi
else
    log "ERROR: 找不到 /home/mi/rt5680-regs.txt"; RC=1
fi

# 3. 恢复金标准控件状态(按名,numid 会错位)
if [ -r /etc/cyberdog-audio-golden.state ]; then
    if alsactl restore 1 -f /etc/cyberdog-audio-golden.state 2>/tmp/audio-init-alsactl.log; then
        log "ALSA 金标准状态恢复 OK"
    else
        log "ERROR: alsactl restore 失败:"
        head -5 /tmp/audio-init-alsactl.log 2>/dev/null | sed 's/^/audio-init:   /'
        RC=1
    fi
else
    log "ERROR: 找不到 /etc/cyberdog-audio-golden.state"; RC=1
fi

# 4. 基础路由
if amixer -c 1 cset name="I2S3 FSYNC Width" 15 >/dev/null 2>&1; then
    log "I2S3 FSYNC Width=15 OK"
else
    log "ERROR: 设置 I2S3 FSYNC Width 失败"; RC=1
fi

[ "$RC" = 0 ] && log "全部完成" || log "完成但有失败项(rc=$RC)"
exit "$RC"
