#!/bin/bash
# CyberDog JP5: 在 chroot 里跑出厂的蓝牙 GATT 服务(手机 App 连接通道)
#
# 唯一的移植阻塞曾是 chroot 内没有 /run/dbus —— gattserver 通过 D-Bus 跟宿主的
# bluetoothd 通信(org.bluez 的 GattManager1 / LEAdvertisingManager1)。
# 该 bind 已加进 jp5-chroot-prep.sh,本脚本只负责用出厂环境变量拉起 gattserver。
set -u
exec /usr/sbin/chroot /mnt/jp4 /bin/bash -c '
# systemd 不带 HOME,而 ROS2 的 rcl_logging_spdlog 要用它展开 ~/.ros/log,
# 缺了会 rcutils_expand_user failed -> Failed to initialize logging -> 直接退出。
# 出厂 unit 是 User=root(systemd 自动给 HOME=/root),chroot 包装会丢掉,必须显式给。
export HOME=/root
export ROS_DOMAIN_ID=42 ROS_VERSION=2 ROS_PYTHON_VERSION=3 ROS_DISTRO=foxy
export LD_LIBRARY_PATH=/opt/ros2/foxy/lib:/opt/ros2/cyberdog/lib
export PYTHONPATH=/opt/ros2/foxy/lib/python3.6/site-packages:/opt/ros2/cyberdog/lib/python3.6/site-packages
export AMENT_PREFIX_PATH=/opt/ros2/foxy:/opt/ros2/cyberdog
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml
exec /opt/ros2/foxy/bin/ros2 run bluetooth gattserver
'
