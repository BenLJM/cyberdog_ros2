#!/bin/bash
# 部署 R32 采集驱动回移后的验收检查（只读）。
# 用法（在 Mac 上）: bash verify-after-deploy.sh > after.txt ; diff MANIFEST.txt after.txt
# 判据见任务返回文本。退出码非 0 = 出现红线回归。
DOG=${DOG:-mi@10.0.0.219}
RED=0

ssh $DOG 'sudo dmesg' > /tmp/dmesg-after.txt

say() { printf '%-34s %s\n' "$1" "$2"; }
red() { RED=1; printf '%-34s %s  <<< 红线\n' "$1" "$2"; }

# ---------- A. 红线：不得回归的既有能力 ----------
n=$(ssh $DOG 'ls /dev/video* 2>/dev/null | wc -l'); [ "$n" = 9 ] && say VIDEO_NODES "$n (期望 9)" || red VIDEO_NODES "$n (期望 9)"
n=$(ssh $DOG 'ls /dev/v4l-subdev* 2>/dev/null | wc -l'); [ "$n" = 6 ] && say SUBDEVS "$n (期望 6)" || red SUBDEVS "$n (期望 6)"
n=$(grep -c 'tegra-capture-vi: subdev.*bound' /tmp/dmesg-after.txt); [ "$n" -ge 6 ] && say VI_BOUND_SUBDEVS "$n (期望 >=6)" || red VI_BOUND_SUBDEVS "$n (期望 >=6)"
n=$(ssh $DOG 'ls /sys/class/video4linux/video3/name >/dev/null 2>&1 && cat /sys/class/video4linux/video3/name'); case "$n" in *RealSense*) say D455_VIDEO3 "$n";; *) red D455_VIDEO3 "$n";; esac
n=$(ssh $DOG 'lsmod | grep -c "^nvgpu"'); [ "$n" = 1 ] && say NVGPU_LOADED yes || red NVGPU_LOADED no
n=$(ssh $DOG 'lsmod | awk "/^nvmap/{print \$3}"'); [ "$n" -ge 1 ] 2>/dev/null && say NVMAP_USERS "$n (nvgpu 仍挂着)" || red NVMAP_USERS "$n"
n=$(ssh $DOG 'lsmod | grep -c snd_soc_rt5680'); [ "$n" = 1 ] && say AUDIO_RT5680 yes || red AUDIO_RT5680 no
n=$(ssh $DOG 'ls /sys/class/thermal/ | grep -c thermal_zone'); say THERMAL_ZONES "$n (期望 >=6)"
n=$(grep -c 'Unhandled context fault' /tmp/dmesg-after.txt); [ "$n" = 0 ] && say SMMU_FAULTS 0 || red SMMU_FAULTS "$n"
n=$(grep -ciE 'BUG:|Unable to handle kernel|Call trace' /tmp/dmesg-after.txt); [ "$n" = 0 ] && say KERNEL_OOPS 0 || red KERNEL_OOPS "$n"

# ---------- B. 回移是否装上了 ----------
say RCE_FW "$(grep -o 'firmware version cpu=rce cmd=[0-9]* sha1=[0-9a-f]*' /tmp/dmesg-after.txt)"
say VI_CH_DEVS "$(ssh $DOG 'ls /dev/capture-vi-channel* 2>/dev/null | wc -l') (基线 36)"
say ISP_CH_DEVS "$(ssh $DOG 'ls /dev/capture-isp-channel* 2>/dev/null | wc -l') (基线 64)"
say IVC_CHANNELS "$(grep -c 'ivc-bus:' /tmp/dmesg-after.txt) (基线 5; diag@5 必须仍缺席)"
say DIAG5_PRESENT "$(grep -c 'ivc-bus:diag@5' /tmp/dmesg-after.txt) (必须 0)"

# ---------- C. 端到端探针（真正的成败判据）----------
echo "--- V4L2 直采探针（不需要 chroot，最快的成败信号）---"
ssh $DOG 'sudo timeout 20 v4l2-ctl -d /dev/video0 --set-fmt-video=width=640,height=480,pixelformat=BG10 --stream-mmap --stream-count=10 --stream-to=/dev/null 2>&1 | tail -5'
echo "--- 采集期间新增 dmesg ---"
ssh $DOG 'sudo dmesg | tail -40'

exit $RED
