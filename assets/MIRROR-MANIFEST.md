# 镜像清单 —— 用它精确重建 build/mirror（4.7G，不入库）

2026-07-30 实测 8 个上游**全部存活**，所以这 4.7G 是可再生的，
备份策略 = 记录 URL + 精确 commit，而不是拷贝二进制。

重建：`bash assets/mirror-restore.sh`

| 镜像 | 上游 | HEAD commit | 大小 |
|---|---|---|---|
| `8821cu-20210916.git` | https://github.com/morrownr/8821cu-20210916 | `7f63a9da2e8e` |  16M |
| `athena_l4t_jakku_dts.git` | https://github.com/zbwu/athena_l4t_jakku_dts | `83797c4385f6` | 284K |
| `athena_l4t_kernel.git` | https://github.com/zbwu/athena_l4t_kernel | `82f7a6d3f933` | 4.1G |
| `athena_l4t_nvidia.git` | https://github.com/zbwu/athena_l4t_nvidia | `70143ba0d5e3` |  57M |
| `athena_l4t_sdk.git` | https://github.com/zbwu/athena_l4t_sdk | `6b4b06aa9916` | 152M |
| `cyberdog_tegra_kernel.git` | https://github.com/MiRoboticsLab/cyberdog_tegra_kernel | `e289231f79e3` | 178M |

## 非 git 件

| 文件 | 来源 | sha256 | 大小 |
|---|---|---|---|
| `public_sources_r35.6.4.tbz2` | NVIDIA L4T r35.6.4 公开源码包 | `a4d8c6ff82e43261` | 189M |
