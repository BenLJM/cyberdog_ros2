#!/bin/bash
# 在 chroot(JP4 rootfs) 内运行原厂栈 — 由 JP5 host 的 jp5-cyberdog-stack.service 调用
#
# 【观测性】出厂节点的诊断信息(CAM_ERR / printf / argus 报错)全打 stdout，而：
#   · systemd 经 `chroot … su - mi -c` 拿不到 stdout(无 tty) → journal 里只有 2 行
#   · rcl 文件日志(~/.ros/log/*.log)被 spdlog 缓冲，低产量节点一直是 0 字节
# 所以这里直接把 stdout/stderr 落盘。用 exec 重定向而非 `| tee`：保持单进程语义，
# systemd 的主 PID 跟踪与 KillMode=mixed 不受影响。
STACK_LOG=/tmp/jp5-stack.log
[ -f "$STACK_LOG" ] && mv -f "$STACK_LOG" "$STACK_LOG.prev"   # 留一代，崩溃重启后还能看现场
exec >"$STACK_LOG" 2>&1

export ROS_DOMAIN_ID=42 ROS_VERSION=2 ROS_PYTHON_VERSION=3 ROS_DISTRO=foxy
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml

# 【AI 相机 / EGL】两处必须同时成立，缺一个 camera_server 就 abort：
#  1) 不能设 DISPLAY。出厂脚本设 DISPLAY=:0，但 JP5 上没有 X 服务器 —— GLVND 见到
#     DISPLAY 就走 X11 平台，eglGetDisplay 直接返回 EGL_NO_DISPLAY(日志里那句
#     "No protocol specified")。不设则走 headless 平台。
#  2) nvgpu ALLOC_AS 的 ABI 翻译层。R32 用户态发 16 字节的 struct
#     nvgpu_alloc_as_args，R35 内核只认 64 字节 → ENOTTY → eglInitialize
#     报 EGL_BAD_ACCESS → argus createCameraProvider 失败 → assert 崩溃。
#     shim 只拦这一个 ioctl，其余原样放行。源码见仓库 dog-scripts/src/。
[ -f /opt/nvgpu-r32-shim.so ] && export LD_PRELOAD=/opt/nvgpu-r32-shim.so
export LD_LIBRARY_PATH=/opt/librealsense-2.55.1/lib:/opt/lrs-shim:/opt/ros2/foxy/lib:/opt/ros2/cyberdog/lib:/usr/local/lib
source /opt/ros2/foxy/setup.bash
source /opt/ros2/cyberdog/setup.bash
source /opt/lrs-wrapper/local_setup.bash
exec ros2 launch athena_bringup lc_bringup_launch.py
