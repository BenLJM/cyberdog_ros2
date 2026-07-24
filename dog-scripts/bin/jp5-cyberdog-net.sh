#!/bin/bash
# CyberDog JP5 内部网络: 确保 l4tbr0 完整就绪(不依赖nv脚本) + eth0并桥 + LCM组播路由 + can0
for i in $(seq 60); do ip link show l4tbr0 &>/dev/null && break; sleep 1; done
ip link set l4tbr0 up 2>/dev/null || true
ip addr replace 192.168.55.1/24 dev l4tbr0 2>/dev/null || true
nmcli device set eth0 managed no 2>/dev/null || true
ip link set eth0 up 2>/dev/null || true
ip link set eth0 master l4tbr0 2>/dev/null || true
ip route replace 224.0.0.0/4 dev l4tbr0 2>/dev/null || true
ip link set can0 up type can bitrate 1000000 2>/dev/null || true
[ -e /sys/bus/platform/devices/realsense_switch/state ] && echo enabled > /sys/bus/platform/devices/realsense_switch/state 2>/dev/null || true
echo enabled > /sys/bus/platform/devices/gps_switch/state 2>/dev/null || true
exit 0
