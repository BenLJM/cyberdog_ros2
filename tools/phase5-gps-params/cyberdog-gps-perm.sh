#!/bin/bash
# CyberDog JP5 (2026-07-26): BCM4775 nstandby sysfs 属性权限。
# 只管 nstandby —— /dev/ttyTHS0 由 99-cyberdog-gps.rules(udev) + jp5-factory-sysinit.sh 负责,
# 这里不重复设, 免得两条路互相覆盖模式位。
# 为什么不用 udev: nstandby 是 platform 设备的 sysfs 属性, 实测 udev RUN 对它不生效
# (udevadm trigger --action=add 后属主没变), 所以用 systemd oneshot。
N=/sys/devices/platform/bcm4775/nstandby
if [ -e "$N" ]; then chown mi:mi "$N"; chmod 0660 "$N"; fi
exit 0
