# /params 产线个体标定备份（这台狗，序列号见 camera/log.txt）

**不可再生资产。** 这是 2021-08-27 产线标定台上做的个体标定，eMMC p12 分区坏了
就永久没了 —— 2026-07-29 之前本地零副本。

## 内容

| 文件 | 说明 |
|---|---|
| `camera/camera_AI.yaml` | 主摄 MEI 内参 @1280×960 |
| `camera/camera_left.yaml` / `camera_right.yaml` | 双鱼眼 MEI 内参 @640×480 |
| `camera/extrinsics_stereo.yaml` | **双鱼眼外参，基线 t_x=-79.93mm**（双目 VIO 的家底）|
| `camera/extrinsics_LeftAI.yaml` / `extrinsics_ColorAI.yaml` | 左鱼眼↔主摄 / Color↔主摄 |
| `camera/*.png` | 产线标定用的棋盘原图（5 张）+ 检验结果图 |
| `camera/log.txt` | 标定日志（含棋盘规格、检验 flag 全 1） |
| `audio/ai_status.toml` | 小爱开关状态 |
| `audio/token.toml.REDACTED` | ⚠️ 原文件含小米云 OAuth 凭证，已移出仓库（见下） |

## ⚠️ 凭证处理

原 `audio/token.toml` 含小米云 `token_access` / `token_fresh` / `token_deviceid`。
已移到 `assets/params-backup-SECRETS/`（`.gitignore` 排除，**绝不入库**），
这里只留脱敏的结构说明供逆向参考。**任何公开发布前都要再查一遍这个目录。**

## 恢复方式

```bash
# 只读校验（不要直接往狗上写，先确认目标分区）
shasum -a 256 -c SHA256SUMS.txt
```

## ⚠️ 个体性警告

这些是**这一台狗**的标定值，与 `share/athena_tracking/config/camera_AI.yaml`
里那份通用参考差别巨大（主摄 xi 连符号都不同）。**别把它当成 CyberDog 通用参数发布**，
别人的狗必须用他们自己 `/params` 里的值。
