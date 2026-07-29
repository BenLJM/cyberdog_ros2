#!/bin/bash
# =============================================================================
#  在 chroot 里编译「出厂人体检测 SDK 验证程序」
#  宿主上跑: sudo /usr/local/bin/body-detect-build.sh
#  产物:     /mnt/jp4/opt/ai-camera/body-detect-probe
# =============================================================================
set -u
CHROOT=/mnt/jp4
[ -f "$CHROOT/opt/ai-camera/body-detect-probe.cpp" ] || { echo "FATAL 缺源码"; exit 78; }

chroot "$CHROOT" /bin/bash <<'INNER'
# ⚠️ 不能开 set -u —— ROS 的 setup.bash 会让 bash 在 source 那行静默退出。
# 这个坑在 ai-camera-inner.sh 和 ai-camera-build.sh 上各踩过一次。
R=/opt/ros2/cyberdog
set -x
# ⚠️ --disable-new-dtags: 默认的 RUNPATH **不作用于传递依赖**,
# libContentMotionAPI.so 自己还要 libresizeconvertion.so, 只有真 RPATH 才传得下去。
# (即便如此运行时仍建议显式给 LD_LIBRARY_PATH, 见下面的运行说明。)
g++ -O2 -std=c++14 -Wall \
    -I$R/include \
    /opt/ai-camera/body-detect-probe.cpp \
    -o /opt/ai-camera/body-detect-probe.tmp \
    -L$R/lib -Wl,-rpath,$R/lib -Wl,--disable-new-dtags \
    -lbody_detect_api -lContentMotionAPI -lpthread
rc=$?
set +x
[ $rc -eq 0 ] || { echo "FATAL 编译失败 rc=$rc"; exit 1; }
mv -f /opt/ai-camera/body-detect-probe.tmp /opt/ai-camera/body-detect-probe
chmod 0755 /opt/ai-camera/body-detect-probe
echo "=== 产物 ==="; ls -l /opt/ai-camera/body-detect-probe
INNER
rc=$?
cat <<'RUN'

=== 运行方式（必须给这两个环境变量）===
sudo chroot /mnt/jp4 /bin/bash -c "
  export LD_LIBRARY_PATH=/opt/ros2/cyberdog/lib:/usr/lib/aarch64-linux-gnu:/usr/local/cuda/lib64
  export LD_PRELOAD=/opt/nvgpu-r32-shim.so
  /opt/ai-camera/body-detect-probe [可选的 P6 PPM 文件]"

  LD_PRELOAD 的垫片是 JP5 上跑 R32 用户态的前提（nvgpu ALLOC_AS 等 ioctl 翻译）。
RUN
exit $rc
