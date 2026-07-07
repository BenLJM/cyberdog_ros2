#!/bin/bash
# CyberDog mirror-now downloads (review D3.3 / runbook §2b+§3) — on-dog FIRST copy.
# Rationale: JP5 EOL Q3 2026 + Xiaomi CDN longevity unknown; the x86 host copy
# and backup-SSD copy come later (rsync this whole dir). Sequential, resumable
# (wget -c) — safe to re-run until it reports FAIL=0.
cd "$(dirname "$0")"
LOG=fetch.log
exec >> "$LOG" 2>&1
echo "=== run $(date -Is) ==="
FAIL=0

need_space() { # arg: required GB free on /
  local free
  free=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
  if [ "$free" -lt "$1" ]; then echo "!! only ${free}G free, need $1G — stopping"; exit 9; fi
}

get() { # args: url outfile
  echo "--- $(date -Is) fetch: $2"
  wget -c -nv -O "$2" "$1" || { echo "!! FAILED: $1"; FAIL=1; return 1; }
}

mkdir -p firmware nvidia wheels repos

# 1. Xiaomi V1.0.0.94 — THE critical artifact (5.06 GB)
need_space 30
get "http://cdn.cnbj2m.fds.api.mi-img.com/cyberdog-package/build/athena_foxy_2022.01.14_emmc_nvme_V1.0.0.94_release_b1b4a851ca.tgz" \
    firmware/athena_foxy_2022.01.14_emmc_nvme_V1.0.0.94_release_b1b4a851ca.tgz
echo "b1b4a851ca59c19956b0039de316ee41  firmware/athena_foxy_2022.01.14_emmc_nvme_V1.0.0.94_release_b1b4a851ca.tgz" > firmware/V94.md5
if md5sum -c firmware/V94.md5; then echo "*** V1.0.0.94 MD5 OK ***"; else echo "!! V1.0.0.94 MD5 MISMATCH"; FAIL=1; fi

# 2. NVIDIA Jetson Linux r35.6.4 trio (JP 5.1.6 — final for Xavier NX)
need_space 25
get "https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.4/release/jetson_linux_r35.6.4_aarch64.tbz2" \
    nvidia/Jetson_Linux_R35.6.4_aarch64.tbz2
get "https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.4/release/tegra_linux_sample-root-filesystem_r35.6.4_aarch64.tbz2" \
    nvidia/Tegra_Linux_Sample-Root-Filesystem_R35.6.4_aarch64.tbz2
get "https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.4/sources/public_sources.tbz2" \
    nvidia/public_sources_r35.6.4.tbz2

# 3. NVIDIA r32.5.2 recovery pair (factory-reset toolchain)
get "https://developer.nvidia.com/embedded/l4t/r32_release_v5.2/t186/jetson_linux_r32.5.2_aarch64.tbz2" \
    nvidia/Jetson_Linux_R32.5.2_aarch64.tbz2
get "https://developer.nvidia.com/embedded/l4t/r32_release_v5.2/t186/tegra_linux_sample-root-filesystem_r32.5.2_aarch64.tbz2" \
    nvidia/Tegra_Linux_Sample-Root-Filesystem_R32.5.2_aarch64.tbz2

# 4. Final JP5 cp38 wheels (Jetson Zoo is bot-walled — keep our own)
get "https://developer.download.nvidia.com/compute/redist/jp/v512/pytorch/torch-2.1.0a0+41361538.nv23.06-cp38-cp38-linux_aarch64.whl" \
    "wheels/torch-2.1.0a0+41361538.nv23.06-cp38-cp38-linux_aarch64.whl"
ORT_URL=$(curl -s https://api.github.com/repos/ykawa2/onnxruntime-gpu-for-jetson/releases \
          | grep -o 'https://[^"]*\.whl' | head -1)
if [ -n "$ORT_URL" ]; then
  get "$ORT_URL" "wheels/$(basename "$ORT_URL")"
else
  echo "!! onnxruntime wheel URL not resolved from ykawa2 releases"; FAIL=1
fi

# 5. Xiaomi V1.0.0.66 secondary baseline (5.08 GB)
need_space 15
get "https://cdn.cnbj2m.fds.api.mi-img.com/cyberdog-package/build/athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.20210824_release_bbcc37a86a.tgz" \
    firmware/athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.20210824_release_bbcc37a86a.tgz

# 6. Git mirrors — small repos first, kernel trees last
mir() {
  local u=$1 d="repos/$(basename "$1").git"
  if [ -d "$d" ]; then
    echo "--- refresh mirror $d"
    git -C "$d" remote update --prune >/dev/null 2>&1 || echo "!! refresh failed: $u"
    return
  fi
  echo "--- $(date -Is) mirror: $u"
  git clone --mirror -q "$u" "$d" || { echo "!! FAILED mirror: $u"; FAIL=1; }
}
for r in \
  https://github.com/morrownr/8821cu-20210916 \
  https://github.com/zbwu/athena_l4t_sdk \
  https://github.com/zbwu/athena_l4t_jakku_dts \
  https://github.com/zbwu/cyberdog_misc \
  https://github.com/zbwu/athena_locomotion \
  https://github.com/zbwu/athena_motorcontrol \
  https://github.com/zbwu/GD32_SPINE \
  https://github.com/MiRoboticsLab/cyberdog_motor_sdk \
  https://github.com/MiRoboticsLab/cyberdog_ws \
  https://github.com/MiRoboticsLab/cyberdog_locomotion \
  https://github.com/MiRoboticsLab/cyberdog_ros2 \
  https://github.com/zbwu/athena_l4t_nvidia \
  https://github.com/zbwu/athena_l4t_kernel \
  https://github.com/MiRoboticsLab/cyberdog_tegra_kernel ; do
  need_space 12
  mir "$r"
done

# 7. Checksums over payload files
find firmware nvidia wheels -type f ! -name '*.md5' -print0 | xargs -0 sha256sum > SHA256SUMS
echo "=== done $(date -Is) — FAIL=$FAIL ==="
df -h / | tail -1
du -sh firmware nvidia wheels repos
exit $FAIL
