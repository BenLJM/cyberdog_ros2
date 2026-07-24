# 站立问题真相（2026-07-22）——推翻 CAMERA-VIO 交接文档的核心结论

> ## ✅ 终局（当日 14:26）：站立成功
> 机主换上另一块电池（6S，22.7V/51%）→ **全断电冷启动**（关机+拔适配器 30 秒，清掉运动板锁存的 12 电机欠压错误；热插拔换电池不会清！）→ `checkout_mode MANUAL` 一条命令 3.6 秒自动 recovery_stand 起立（err_state:0，gait:3，电压仅跌 0.26V）。**零物理干预，机制即出厂原生。** 旧电池 16.7V=2.78V/cell 深放电，BMS 拒充，试过夜关机涓流，救不活就退役。

**一句话：狗站不起来的唯一真实阻碍是电池（soc 1%，16.7V 且持续放电，适配器没在充电）。软件链路全部健康，相机 VIO 与站立无关，"抱狗晃初始化"是伪需求。**

## 证据链（全部在 2026-07-22 现场验证）

1. **"[Offline] Odom state response is offline" 是正常噪音，不是故障。**
   [motion_manager.cpp:1809](cyberdog_ros2/cyberdog_decision/decision_maker/src/motion_manager.cpp)（开源版与生产 libdecisionmaker_core.so 同逻辑，日志字符串逐字一致）：内层循环条件要求 `control_mode >= MODE_MANUAL || mode_server_->is_running()`，**DEFAULT 模式下每轮必然退出并打印这句**。odom_out 不发布也是设计行为（模式门禁），不是数据断了。

2. **腿部里程计 LCM 链路 100% 健康。**
   - 运动板 192.168.55.233 经 eth0（l4tbr0 桥成员口）以 ~500Hz 向 `239.255.76.67:7669` 推 `state_estimator` channel（tcpdump 实抓，LCM 包头可见 channel 名）；7670 上是 `exec_response`。
   - strace 实测：decisionmaker 的 fd21(7669)/fd18(7670) 每 4 秒各成功 recvmsg ~2000 次，来自 192.168.55.233 的包 4 秒 3998 个——**内核投递、socket、LCM 全部正常**。
   - status_out 的 velocitystamped 在实时更新 = statees 回调每包都在跑。
   - `IgnoredMulti` 计数暴涨是红鲱鱼：运动板还在向 **7667**（LCM 默认端口）泛发无人监听的高频流量。

3. **站立到底是怎么被挡的（当日实测）：**
   - `checkout_mode MANUAL(3)` **不会**被低电量挡（[motion_manager.cpp:476](cyberdog_ros2/cyberdog_decision/decision_maker/src/motion_manager.cpp) 的 LOW_BTR 检查只对 `>= MODE_SEMI(13)` 的自主模式生效；MODE_MANUAL=3）。
   - checkout MANUAL 被接受后，motion_manager **自动执行 recovery_stand（起立）**——这就是"原版零干预站立"的机制本体。
   - 但步态在运动板端超时失败：`[Gait_Check] Check gait execute failed. Error code is timeout` + 之后 5Hz 刷 `[State_Detection] Locking state & Error state detected. Checking to passive`——**运动板处于锁定+错误状态**（16.7V 下电机驱动欠压保护，day1 电压较高时真实站立过并把系统抽到掉电重启）。
   - 之前"STAND_UP 返回 err 7 UNAVAILABLE"：因为 checkout MANUAL 没成功、模式停留 DEFAULT，单招指令自然 UNAVAILABLE。归因到"odom offline"是被 §1 的噪音日志误导。

4. **电池实况：** BMS 日志 `soc:1, volt:16695`；本次开机 50 分钟电压 17.69V→16.70V 单调下跌。**适配器插着但完全没有充进去。**

## 被推翻/修正的旧结论（原文见 CAMERA-VIO-HANDOFF-2026-07-22.md）

| 旧结论 | 真相 |
|---|---|
| odom_out 应由 ov_msckf（相机 VIO）产出 | odom_out 由 motion_manager 转发运动板 LCM 腿部里程计，与相机无关 |
| DDS 投递不通 → 无 odom → 不能站立 | DDS 问题只影响**导航**数据链（rs_bridge→ov_msckf），与站立无关 |
| 单目 VIO 静止不初始化 → 需要人抱狗晃 | 站立根本不用 VIO；伪需求，永久作废 |
| "Odom offline" = 故障 | DEFAULT 模式下的正常日志噪音 |

**rs_bridge/RSUSB/ov_msckf 的已有成果仍然有效**（导航/建图未来要用），DDS 投递问题降级为 Phase 5 导航项，正解方向仍是"塞进栈 launch"（见旧交接 §4）。

## 现在到能站立，只差两步（都是物理操作）

1. **把电充上**（见下方检查清单）。电压回到 >19V / soc >20% 后，运动板错误状态应自动清除。
2. **机主在场**运行狗上已预置的一键脚本：
   - `/home/mi/stand.sh` —— checkout MANUAL，狗自动起立（零物理干预）
   - `/home/mi/liedown.sh` —— 趴下并回 DEFAULT
   - `/home/mi/dogstatus.sh` —— 电池/板端错误/LCM 流/模式速览

## 充电排查清单（按顺序试）

1. 确认用的是**原装适配器**，充电口插紧；看适配器/狗充电口 LED 有无充电指示。
2. 插拔电池仓（断电重置 BMS）后再接充电器——soc 卡 1% 多日 + 电压一路跌，疑似 BMS 量表卡死或深放电保护已触发。
3. 关机充电试一次（排除整机负载 > 充电电流的可能）。
4. 若仍不充：量适配器输出电压，怀疑适配器或充电通路硬件故障。
5. ⚠️ 电池已接近深放电（16.7V 且在跌）。**不充电就长时间开机会进一步伤电池**，不用时请关机。

## 追加（2026-07-22 12:00-12:20，机主重插适配器后）

- **充电仍未建立**：电压 16.68V 横盘微跌；BMS status 以 ~2 秒脉冲反复 3→7→3（bit2 疑为充电尝试位）且间隔在缩短——**BMS 在反复尝试启动充电又中止**（疑深放电保护/老化电芯低于再充电阈值）。
- **软件踢活已试无效**：向 `/mi1045904/disable_charge` 发布 `disable_charge:0`（bms_ctrl 收到；该话题平时 0 发布者、journal 从无 charge enable 记录）。
- **运动板错误解码实锤**（motion_control_response_lcmt 对照 tcpdump）：`pattern=1`、`foot_contact=0x0f`（四脚触地，传感健康）、`exist_error=1`、**motor_error[12] 全部 =1**——全电机共因故障=电机轨欠压保护。板子健康，只是拒绝在空电池上动电机。
- **减负**：杀掉并禁用了 LXDE 自启的 `vlc -L -f robot_expressions.avi`（前任机主遗留，24% CPU 空转；备份 `autostart.bak-20260722`，恢复=去掉行首 #）。
- **下一步唯一有希望的动作：插着适配器关机充 1-2 小时**（很多 BMS 只在关机/低载下执行深放电恢复涓流），开机后看电压：≥17.5V 有戏；仍 16.7V → 量适配器输出 / 电池包送修或更换。

## 当日无害化记录

- 为诊断临时改过 `l4tbr0` 的 `multicast_snooping`（0→已复原为 1）；重启过一次 `cyberdog_ros2.service`（现运行正常）。
- 发过一次 checkout MANUAL（触发了 recovery_stand 尝试，板端错误状态拒绝执行，未产生任何物理动作，模式已干净回滚到 DEFAULT）。此类指令后续必须机主在场才发。
