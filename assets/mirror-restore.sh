#!/bin/bash
# 从 MIRROR-MANIFEST.md 重建 build/mirror（4.7G）。上游 2026-07-30 实测全部存活。
set -euo pipefail
D=build/mirror; mkdir -p "$D"
clone() { [ -d "$D/$2" ] || git clone --mirror "$1" "$D/$2"; }
clone https://github.com/zbwu/athena_l4t_kernel        athena_l4t_kernel.git
clone https://github.com/zbwu/athena_l4t_sdk           athena_l4t_sdk.git
clone https://github.com/zbwu/athena_l4t_nvidia        athena_l4t_nvidia.git
clone https://github.com/zbwu/athena_l4t_jakku_dts     athena_l4t_jakku_dts.git
clone https://github.com/MiRoboticsLab/cyberdog_tegra_kernel cyberdog_tegra_kernel.git
clone https://github.com/morrownr/8821cu-20210916      8821cu-20210916.git
echo "⚠️ public_sources_r35.6.4.tbz2 需从 NVIDIA 开发者站单独下载（见 MANIFEST 的 sha256 校验）"
echo "重建完成后请用 MANIFEST 里的 commit 核对。"
