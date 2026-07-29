# 救援手册（动手前必读）

> 2026-07-30 建立。原则：**任何可能改变机器状态的动作之前，先确认对应那条恢复路径是活的。**

## 一、恢复路径总表

| 出问题的东西 | 恢复手段 | 状态 | 代价 |
|---|---|---|---|
| **JP5 内核/DTB 起不来** | `boot-jp5/` 下 11 份 `Image.prev-*` + 对应 dtb，改 extlinux 指回去 | ✅ 现成 | 分钟级 |
| **改坏 extlinux / 内核 initcall 前挂死** | RCM 裸机刷写（`--boot recovery` 读写 eMMC APP 分区） | ✅ 实战成功两次 | ~103 秒写回，全程 ~1 小时 |
| **QSPI / 引导器损坏** | `build/qspi-backup-factory.bin`（32MB，本机出厂 QSPI 全片） | ✅ **已入库** | 需 RCM |
| **`/params` 产线标定丢失** | `assets/params-backup/`（含 SHA256SUMS） | ✅ 已入库 | 秒级 |
| **`build/mirror` 4.7G 内核源丢失** | `assets/mirror-restore.sh` 重新 clone | ✅ 上游 8/8 存活（2026-07-30 实测） | 带宽/时间 |
| **`cyberdog_ros2` 开源件丢失** | 上游 `MiRoboticsLab/cyberdog_ros2`（实测 200） | ✅ 可再生 | 秒级 |
| **出厂 rootfs（chroot）损坏** | 狗上 `nvme0n1p1` 是 JP4 原始系统，未被改动 | ✅ 双系统本身就是备份 | — |
| 🔴 **运动板固件损坏** | **无恢复手段**（Dreame 加密镜像，不可重建） | ❌ **不可逆** | 换板 |

## 二、🔴 运动板：唯一没有恢复路径的部件

固件包 `p2151_update-*.img` 是 PKCS#7 **envelopedData（加密）**，内容读不出来、
改不了、重建不了。**运动板一旦刷坏，没有任何软件手段能救回来。**

因此对运动板的规矩：

1. **先存档再接触** —— `tools/motion/mb-snapshot.sh`（纯只读：ping/端口/被动 LCM/宿主侧信息）。
   已有存档：`assets/mb-snapshot-2026-07-30/`
2. **只读侦察（SSH 登入）需要机主明确同意**——登入本身无害，但属于"接触运动板"。
3. **绝不刷写运动板固件。** 官方 `cyberdog_motor_sdk` 走的是运行时开发通道，
   不动固件；那条路可以走，刷固件那条路不走。
4. **绝不 kill 工厂控制器**（`cyberdog_locomotion` 的部署脚本会 `kill -9` 它并顶上去
   —— 那份代码官方自己写着"1 代未经充分测试"）。

## 三、机密防呆

- `assets/params-backup-SECRETS/`（小米云 OAuth token）**永不入库**，`.gitignore` 排除。
- `.githooks/pre-commit` 是自动闸门：路径黑名单 + 内容特征双检。
  已实测：故意暂存凭证会被拦（退出码 1），正常提交放行（0）。
  启用方式：`git config core.hooksPath .githooks`（本仓已配）。
- 由来：2026-07-30 一次 `git add -f assets/` 把 token 强制加进暂存区
  （**`-f` 会覆盖 `.gitignore`**），当场发现撤掉，未进历史。

## 四、动手前的检查清单

```bash
# 1. 恢复链在不在
ssh mi@10.0.0.219 "sudo mountpoint -q /mnt/emmcp1 || sudo mount /dev/mmcblk0p1 /mnt/emmcp1; \
                   sudo ls /mnt/emmcp1/boot-jp5/ | grep -c '^Image.prev'"   # 应 ≥ 2

# 2. 关键资产在不在库里
git ls-files build/qspi-backup-factory.bin assets/params-backup | wc -l      # 应 ≥ 18

# 3. 凭证闸门活着
.githooks/pre-commit >/dev/null 2>&1; echo $?                                # 干净暂存区应 0
```

## 五、已知的救援陷阱（都踩过）

- RCM 会话**一次性**：`lsusb` 还看得到但已失效，必须**真断电**（看 Device 号变没变）。
- 必须加 `--no-systemimg` 和 `NO_RECOVERY_IMG=1`。
- 自制 initramfs **必须 root 打包**，否则丢 `/dev/console` 导致 init 不执行。
- 🔴 **串口救援是假的**：笔记本上那个 `/dev/ttyACM0` 是 USB gadget（T+19.4s 才存在），
  够不着 extlinux 菜单。所谓"三重安全网"**实为两重**。
- 上电时风扇自然满速转 1 秒，别当成自己的信号。
- **拔电前先拔 USB**，否则会进 RCM。
