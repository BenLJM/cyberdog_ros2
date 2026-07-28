#!/bin/bash
# 在 chroot(JP4 rootfs) 内编译 R32 用户态兼容垫片，产物 /opt/nvgpu-r32-shim.so
#
# 必须在 chroot 内编译：要链 JP4 的 glibc(Ubuntu 18.04 / gcc 7.5)，
# 用宿主 JP5 的 gcc 9.4 编出来的 .so 会带上 GLIBC_2.29+ 的符号需求，在 chroot 里加载失败。
#
# 用法: sudo bash nvgpu-r32-shim-build.sh [源码路径]
#   源码默认取仓库里的 dog-scripts/src/nvgpu-r32-shim.c(需先 scp 到狗上)
set -euo pipefail

SRC=${1:-/tmp/nvgpu-r32-shim.c}
CH=/mnt/jp4
OUT=/opt/nvgpu-r32-shim.so

[ -f "$SRC" ] || { echo "FATAL: 源码不存在: $SRC"; exit 1; }
mountpoint -q "$CH" || { echo "FATAL: $CH 未挂载,先跑 jp5-chroot-prep.sh"; exit 1; }

cp -f "$SRC" "$CH/tmp/nvgpu-r32-shim.c"
chroot "$CH" /bin/bash -c '
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
  gcc -shared -fPIC -O2 -Wall -o '"$OUT"'.new /tmp/nvgpu-r32-shim.c -ldl'

# 装载自检：确认 .so 在 chroot 里能被 ld.so 真正加载(不只是编译通过)
chroot "$CH" /bin/bash -c '
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
  LD_PRELOAD='"$OUT"'.new /bin/true' \
  || { echo "FATAL: 新 .so 加载失败,不替换旧件"; rm -f "$CH$OUT.new"; exit 1; }

mv -f "$CH$OUT.new" "$CH$OUT"
echo "✅ 已构建 $CH$OUT"

# 功能自检：EGL + CUDA 两条链路都要活(这正是垫片存在的理由)
if [ -f "$CH/tmp/cuda-probe.py" ]; then
    echo "--- CUDA 自检 ---"
    chroot "$CH" /bin/bash -c '
      export PATH=/usr/bin:/bin:/usr/sbin:/sbin
      env -u DISPLAY LD_PRELOAD='"$OUT"' python3 /tmp/cuda-probe.py' | tail -3
fi
