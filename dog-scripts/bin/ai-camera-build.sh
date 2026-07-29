#!/bin/bash
# =============================================================================
#  在 chroot（JP4 / Ubuntu 18.04 / gcc 7.5 / ROS2 Foxy）里编译 AI 相机 C++ 节点
#  在宿主（JP5）上跑: sudo /usr/local/bin/ai-camera-build.sh
#
#  刻意不用 colcon/ament —— 只有一个源文件、两个消息类型，直接 g++ 就够，
#  省掉造一整个 workspace 的麻烦（而且 chroot 里没有 colcon）。
#
#  产物: /mnt/jp4/opt/ai-camera/ai-camera-node
# =============================================================================
set -u
CHROOT=/mnt/jp4
SRC=/opt/ai-camera/ai-camera-node.cpp
OUT=/opt/ai-camera/ai-camera-node

[ -f "$CHROOT$SRC" ] || { echo "FATAL 缺 $CHROOT$SRC"; exit 78; }

chroot "$CHROOT" /bin/bash <<'INNER'
# ⚠️ 这里【不能】开 set -u —— ROS 的 setup.bash 引用了一堆未定义变量，
# set -u 会让 bash 在 source 那一行直接退出；那行又带 2>/dev/null，
# 于是连报错都看不到（表现为"构建失败但零输出"）。同一个坑在
# ai-camera-inner.sh 上已经踩过一次。
source /opt/ros2/foxy/setup.bash 2>/dev/null
R=/opt/ros2/foxy

# rclcpp 需要的一堆 include 根目录。Foxy 是"每个包一个 include 目录"的老布局，
# 全塞进来最省事（多给几个不存在的目录 g++ 只会忽略）。
INC=""
for d in "$R/include"; do INC="$INC -I$d"; done

# 链接项: rclcpp 本体 + sensor_msgs 的 C/C++ typesupport。
# ⚠️ typesupport 库必须显式给 —— 只链 rclcpp 的话运行期会报
# "type support not from this implementation"，编译期反而不报错。
LIBS="-L$R/lib -Wl,-rpath,$R/lib \
  -lrclcpp -lrcl -lrcutils -lrcpputils -lrmw -lrcl_yaml_param_parser \
  -lsensor_msgs__rosidl_typesupport_cpp -lsensor_msgs__rosidl_generator_c \
  -lsensor_msgs__rosidl_typesupport_c \
  -lstd_msgs__rosidl_typesupport_cpp -lstd_msgs__rosidl_generator_c \
  -lbuiltin_interfaces__rosidl_typesupport_cpp -lbuiltin_interfaces__rosidl_generator_c \
  -lrosidl_runtime_c -lrosidl_typesupport_cpp -lrosidl_typesupport_c \
  -lpthread"

echo "=== 编译 ==="
set -x
g++ -O3 -std=c++14 -Wall -Wextra -Wno-unused-parameter \
    $INC /opt/ai-camera/ai-camera-node.cpp -o /opt/ai-camera/ai-camera-node.tmp $LIBS
rc=$?
set +x
[ $rc -eq 0 ] || { echo "FATAL 编译失败 rc=$rc"; exit 1; }

mv -f /opt/ai-camera/ai-camera-node.tmp /opt/ai-camera/ai-camera-node
chmod 0755 /opt/ai-camera/ai-camera-node
echo "=== 产物 ==="
ls -l /opt/ai-camera/ai-camera-node
echo "=== 动态库解析自检（不能有 not found）==="
ldd /opt/ai-camera/ai-camera-node | grep -c "not found" || true
INNER
rc=$?
[ $rc -eq 0 ] && echo "✅ 构建成功" || echo "❌ 构建失败 rc=$rc"
exit $rc
