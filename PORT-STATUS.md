# CyberDog JetPack 4 → 5 移植：权威现状

**最后更新 2026-07-25**（本文件取代 `cyberdog_ros2/PHASE5_STATUS.md`，后者的核心结论"相机被 RCE 固件锁死、必须动 QSPI"**已被推翻**，见下）

---

## 架构（实际路线，与原计划不同）

原计划是 ROS2 Humble 原生化（Phase 6–10）。**实际走的是另一条路且已既成事实**：

> **JP5 内核（5.10.216-tegra / L4T r35.6.4）+ chroot 跑 JP4 出厂 ROS2 Foxy 栈**

JP4 根文件系统在 `nvme0n1p1`，运行时挂在 `/mnt/jp4`。这条路线从未被正式改判入档，**它是终局架构还是过渡态，需要机主拍板**。

## 引导

**真配置在 eMMC `/dev/mmcblk0p1` 的 `/boot/extlinux/extlinux.conf`**（nvme 上那两份是幌子）。

| LABEL | 内核 | 说明 |
|---|---|---|
| `jp5` | `/boot-jp5/Image` + `tegra194-mi-k91.dtb` + `initrd` | 当前 DEFAULT |
| `primary` / `second` | `/boot/Image` | JP4 |
| `rescue` | `/boot/Image` + `initrd-rescue` | JP4 内核、RAM 盘、不挂 NVMe |

### 三重安全网（已实战验证）
1. **initrd 自动回滚守卫** `sbin/jp5-autorevert-hook`：启动尝试计数器（>3 次未成功 → 自动恢复 `extlinux.conf.jp4-saved` 并重启），rootfs 只读探测，写保护探测，恢复内容 `cmp` 校验，失败时挂 USB gadget shell 而**不是**盲目重启循环。计数器由 `jp5-boot-ok.service`（`After=multi-user.target`）清零。
   - **2026-07-19 实战触发过一次并成功回滚**（见 eMMC `/boot/jp5-revert.log`）
   - ⚠️ **`build/artifacts/jp5-autorevert-hook.sh` 是旧的 Phase-3 版本（bash、无计数器）。用它重建 initrd 会静默把安全网降级。权威版本在 `tools/phase4/initrd-rootfs/sbin/jp5-autorevert-hook`**
2. ~~**串口控制台**：笔记本 `ben@10.0.0.176` 的 `/dev/ttyACM0`（115200）→ 可在 cboot extlinux 菜单远程选启动项。~~
   🔴 **2026-07-27 实测推翻，这条不能当救援手段用。**
   那个 `/dev/ttyACM0` 不是内核控制台，是 **USB gadget 的 `acm.GS0` → 狗侧 `/dev/ttyGS0`**，上面跑的只是 `agetty`。
   证据：①`/proc/consoles` 只有 `tty0 / ttyTCU0 / ramoops-1`，**没有 ttyGS0** ②写 `/dev/kmsg` 到不了笔记本，直接写 `/dev/ttyGS0` 才到 ③gadget 由 `nv-l4t-usb-device-mode` 在 **T+19.4s** 才创建，agetty 在 T+89s ④笔记本 `lsusb` 上没有任何第二个 usb-serial 桥。
   **内核启动只花 15.7s，所以引导器输出和 probe 挂死整个落在 [0, 19.4s] 这个盲区里，这条线原理上看不见。** 也就**够不着 extlinux 菜单**。
   → 真·内核控制台是 `ttyTCU0`，走板上调试 UART，需要机主接 USB-TTL(3.3V)。见新增的 §2026-07-27。
   → 当前笔记本上已常驻 `cyberdog-serial-log.service`，覆盖 T+19.4s 之后的用户态输出 + 掉线/回归时刻，**不覆盖早期启动**。
3. **USB 网络** 192.168.55.100 ↔ 192.168.55.1（1.8ms）。

---

## 🔒 部署铁律

### DTB 五项，缺一不可（每次逐项 diff）
| 项 | 丢了会怎样 |
|---|---|
| `diag@5` disabled | RCE 相机 `CH_SETUP` 复发错误 128，相机链断 |
| 热区 `map3` 删除（`cl3_0` 悬空引用清零） | **静默复发 thermtrip 掉电死机** |
| `aonclk` 表项裁剪 | 声卡不注册 |
| `adsp_audio` 禁用 | 声卡不注册（defer 40 链） |
| legacy hsp okay + 四邮箱（cmd rx=SM6/tx=SM7、ivc rx=SM1/tx=SM0） | RCE 握手超时 |

> ⚠️ **H2 病理**：热区 `map3` 删除 + `aonclk` 裁剪 + `adsp_audio` 禁用这三项**与音频无关，却寄生在 `tegra194-mi-k91-audio.dtsi` 里**。回退音频 DTS = 静默复发热跳闸死机。**待拆分成独立 `thermal-fixup.dtsi`。**

### 构建顺序
`full-build.sh` → `build-jp5-initrd.sh`（后者会被前者清空 `out/final`，顺序反了白干）

### ⛔ 绝对不要做
- **不要"修" PWM 极性**：极性反转是这块板子的**硬件事实**，通用 `pwm-fan.c` 已用 DTB 里降序的 `cooling-levels=<255 178 135 95 0 …>` 补偿，端到端自洽正确，且"PWM 失能=全速"还是 fail-safe。**改了才会散热失效。**
- **不要远程 `systemctl isolate multi-user.target`**：会同时断掉 SSH 和 fanboy，无法远程回滚。
- **不要给 wlan0 改静态 DNS**：已实测 223.5.5.5/8.8.8.8 在本 LAN 上 UDP53/TCP53 全超时，修法无效却会冒断掉唯一 ssh 通道的险。
- **不要绕过 pulseaudio 走 ALSA 直通**：客户端流是 16kHz，pulse 在做 16k→48k 重采样；**16k 会被 BE 抽干 → 功放 CLK 故障锁存（要断电才清）**。
- **不要在笔记本上跑 `apt-get autoremove --purge`**：会 purge python2，而出厂 R32 树的 `BUP_generator.py` shebang 是 `#!/usr/bin/python`。

---

## 元器件状态

| 子系统 | 状态 | 说明 |
|---|---|---|
| 运动板 + 12 电机 | ✅ | LCM leg_control_data + spi_data 500Hz |
| 机身 IMU | ✅ | LCM myIMU ~1000Hz |
| 以太网 → 运动板 | ✅ | 千兆 |
| Wi-Fi (8821cu) | ✅ | 5GHz，冷启自动上线 |
| 麦克风阵列 (RT5680 6ch) | ✅ | 753 寄存器回放 + 42 控件按名 |
| 扬声器 (TAS5805M) | ✅ | 48k 立体声实测出声 |
| 双风扇 / 散热 | ✅ 兜住 | 5 温区注册、90.5°C 降频 + 96°C critical 已绑；但 `thermal_zone5` **mode=disabled** → 内核不动风扇，100% 靠用户态 `fanboy` |
| CPU 功耗模式 | ✅ 已修 | 曾误停在 `MODE_10W_DESKTOP`(4核)，**已恢复出厂 `MODE_15W_6CORE`(pmode 2)**；⚠️ `/etc/nvpmodel.conf` 的 `DEFAULT` 仍是 5，rootfs 重刷会静默退回 |
| 蓝牙 (Realtek hci0) | ⚠️ 退化 | hci0 UP RUNNING，但 JP4 的 `bluetooth_ros2.service` 在 JP5 无对应实现 |
| D455 深度相机 | ✅ | `d455-camera.service` 已部署+enabled，随栈自启（sidecar）。848x480@30 三路影像 + IMU 200Hz 实测满速，详见 0726 条目 |
| GPS (BCM4775) | ✅ 链路通（待室外定星） | **2026-07-27 改判**：串口实测在发合法 Bream/UBX 帧（`0xB5 0x62`）并抓到 `$GP`/`GGA` 片段；出厂节点独占 `/dev/ttyTHS0` 且**本来就有**读线程（`scene_detection.cpp:243-250`）。`/SceneDetection` 静默是因为发布条件要求有效经纬度（室内无星）→ 出厂正确行为，**不是数据链坏**。体检：`cyberdog-gps-check.sh` |
| 电池 / BMS | ⏸️ 物理项 | **机主已物理拆除电池**，当前适配器供电（只有 `usb-charger`，无 battery 节点） |
| AI 头顶相机（3 sensor） | ❌ 不通 | RCE 固件活(cmd=5)、IVC 通、nvcsi initialized、3 颗 subdev 全 bound、nvmap 手术已过 —— 但采集控制面 ABI 结构性分家 |
| 前超声 / ToF / 光流 / 光线 / LED | ✅ 已通 + 开机自动使能 | 0725 实测出数；**2026-07-27 补上自动使能** `cyberdog-sensors.service`：A/B 实测 `ObstacleDetection` 0.00→10.13 Hz、`BodyState` 0.00→25.01 Hz。（开源树里没人发 ENABLE，本该由闭源手机 App 发） |
| 背部触摸板 | ✅ 已通 | 驱动 4.9→5.10 移植(3 文件 56 行)+ DT 使能；`event0=synaptics_dsx`，出厂 `touch_publisher` 节点已 activate。⏸️ 物理触摸未由人验证 |
| 系统时钟 | ❌ 不通 | 停在 2000-01-01（双根因，见下） |
| swap | ❌ 无 | 内核没编 `CONFIG_ZRAM`，`nvzramconfig` failed |
| 硬件看门狗 | ❌ 禁用 | DT 里禁着，"挂死后自愈"零路径 |
| pstore / ramoops | ✅ 已通 | 纯 extlinux cmdline 零内核零 DTB 改动；**每次开机完整 console 日志(从 `[0.000000]` 到最后一行)自动落盘归档**，见下节。⚠️ 只覆盖热复位，硬断电 DRAM 掉电无解 |
| OP-TEE | ❌ 不通（可接受） | R32 引导器混血，本来就不可用 |

---

## AI 头顶相机：为什么是死路（2026-07-25 定案）

已推倒的墙：RCE legacy hsp 邮箱回移 ✅ / `diag@5` CH_SETUP ✅ / nvmap WRITE ABI ✅ / **nvmap handle-as-fd 核心手术 ✅**（`NVMAP_CONFIG_HANDLE_AS_FD:=y`，mmap/EBADF 墙已倒，nvgpu 毫发无伤）/ 采集 ioctl 参数墙（`build/capture-ioctl-compat/`，已构建通过）✅

**但后面还有一堵垫片原理上翻不过去的墙**，三条独立硬证据：
1. **一票否决**：`CAPTURE_CHANNEL_SETUP_REQ` 消息号 R32=`0x10`、R35=`0x1E`，且 R35 把 `0x10` 显式改名成 `CAPTURE_CONTROL_RESERVED_10`。R35 内核发的话 R32 固件根本不认识。（与已修好的 `diag@5`/CH_SETUP 是**两回事**——那个是 IVC 总线建立层）
2. `capture_channel_config` 216B→272B 全错位；更糟的是 ISP 侧 `CAPTURE_CHANNEL_ISP_SETUP_REQ` 两边**都是 0x20**，R32 固件会"接受"然后按错布局解析 → **静默乱掉而非报错**（特征：`arm-smmu Unhandled context fault`）
3. 每帧内存模型换了范式：R32=reloc（内核就地打补丁 IOVA）；R35=buffer-table+memoryinfo，且缓冲必须先经 `VI_CAPTURE_BUFFER_REQUEST` 注册 —— **R32 根本没有这个 ioctl 号**，所以 R32 用户态永远不会注册

**继续在 R35 驱动上打垫片是明确的死路。** 三个选项待机主拍板：
- **(a) 整体回移 R32 采集驱动** —— 与已打赢的两仗同一套路，源码在 `build/mirror/cyberdog_tegra_kernel.git` 现成，依赖面窄，三方自洽零翻译。**唯一有希望的路**，但工程量与 nvmap 核心手术同量级
- **(b) 先部署本轮垫片当探针** —— 零风险可回滚，价值是看清下一堵墙。**判别点：错误码从 `-EINVAL` 变成 `-ETIMEDOUT` 就说明垫片生效、卡点前移到 IVC 控制面**
- **(c) 收手** —— 接受 D455 为唯一相机

---

## 时钟停在 2000 的双根因

1. **`nvrtc-sync-boot.service`**（R35 新带进来的，JP4 根本没有）在 timesyncd 已经把时间恢复之后，又用**没电的 PMIC 备份 RTC** 把系统时间覆盖回 2000
2. **DNS 全灭**（路由 10.0.0.1 已降级，`getent` rc=2）→ NTP 连域名都查不出

修复顺序不可乱，见 `docs/` 下的行动计划。三个坑：
- `disable --now` 加在 **shutdown** 单元上会当场触发 ExecStop，把 2000 年写进备份 RTC
- **别把 `nvrtc-sync-shutdown` 也禁了** —— 它是当前唯一把正确时间落盘到硬件的通道
- 配置键是 `FallbackNTP=`，不是 `FallbackNTPServers=`

---

## 已被推翻的旧结论（不要再据此行动）

1. ~~"TCA6424 两条 init-gpios hog 在 JP5 丢失 = 全系统共同病根"~~ — JP4 那两条 hog 带 `status="disabled"`，`for_each_available_child_of_node()` 会跳过，**在 JP4 上同样从未生效**
2. ~~"CAN 总线实质死亡"~~ — TX 有 ACK、TEC=0、MCU 回了 timesync 应答，静默是出厂空闲态设计
3. ~~"ov7251 I2C 地址在 JP5 错位 +1"~~ — R35 驱动的 `ov7251_update_sccb_id()` 会主动把传感器搬到 DT 指定地址
4. ~~"GPS 停在 standby"~~ — 驱动 probe 里无条件拉高 nstandby，实测 `nstandby=1`
5. ~~"PWM 极性反了是 bug"~~ — 是硬件事实 + 降序 cooling-levels 补偿，端到端正确
6. ~~"相机被 RCE 固件锁死、必须动 QSPI"~~（`PHASE5_STATUS.md`）— 已用零刷写的 legacy hsp 驱动回移解决

---

# 2026-07-25 深夜追加

## 🔴 rmem_max：一个 123 倍的移植回归（已修）
JP4 `/etc/sysctl.conf` 设 `net.core.rmem_max=26214000`（26MB），**移植时整条丢了**，JP5 停在内核默认 `212992`（208KB）。
后果：所有 ROS2/DDS 大消息过不去。实测 D455 848x480 深度帧 814KB → 10 秒只收到 1 帧；424x240（203KB）满速 30.1Hz——**阈值正好卡在 208KB**。
两条独立的线（D455 取流、systemd 缺口审计）互相印证。极可能是 0722「rs_bridge 投递不出去」悬案的真凶。
修复：`/etc/sysctl.d/99-cyberdog.conf`。
**2026-07-26 追认**：确实是它。rmem 补齐后 848x480 当场满速（见下），0722 悬案结案。

---

# 2026-07-26 追加

## ✅ D455 深度相机：冷启自启落地（`d455-camera.service`）
JP4 出厂有 `rs-bridge.service`，JP5 一直没有对应实现 —— 相机每次都要人工拉起。现已补齐。

**部署内容**（全部为新增文件，未改动任何既有 unit / 出厂 launch）：

| 文件 | 位置 | 作用 |
|---|---|---|
| `d455-camera.service` | JP5 `/etc/systemd/system/` | 主 unit，`WantedBy` + `PartOf` = `jp5-cyberdog-stack.service` |
| `d455-camera.sh` | JP5 `/usr/local/bin/` | 宿主侧启动器：chroot 兜底、电源轨、USB 等待、尝试计数 |
| `d455-camera-inner.sh` | chroot `/home/mi/` | 直接 exec `/opt/lrs-wrapper` 包装器节点（不走 `ros2 run`） |
| `d455-doctor.sh` + `.service`/`.timer` | JP5 | 每 5 分钟 CPU 活性判活，连续 2 次判死才重启 |
| `d455-verify.sh` | JP5 `/usr/local/bin/` | 只读验收（rclpy 计数，不信 `ros2 topic hz`） |

**实测（2026-07-26 03:27–03:46）**

```
depth  848x480 Z16  30.0 Hz      infra1 848x480 Y8  30.1 Hz
infra2 848x480 Y8   30.0 Hz      imu                197.6 Hz
节点 CPU ≈16% 单核    SoC 62.5–65°C（无变化）    10 分钟零重启、PID 未变
```

**三条被推翻/证实的旧判断**
1. ~~"848x480 过不了 DDS"~~ —— 真凶是 `rmem_max`，补回 26MB 后当场满速。默认分辨率已从 424x240 提到出厂档位 **848x480**。
2. ~~"独立 systemd unit 的 DDS 参与者投递不到栈内节点"~~（`CAMERA-VIO-HANDOFF-2026-07-22.md`）—— 实测本 unit 与栈**同图可见（31 节点）**，投递正常。同样是 `rmem_max` 背的锅。**结论：不需要塞进栈 launch。**
3. ✅ 证实：IMU 速率必须 pin 成 gyro 200 / accel 100，否则节点自动挑 400/200 → `Motion Module failure`，IMU 无数据。

**默认档位 = `full`（depth + infra1 + infra2）**，对齐出厂 `realsense2_camera/launch/high_performance.py`（848x480、三路全开）。
出厂 VIO `ov_msckf/launch/ros2.launch.py` 的 remap 要的正是 `camera/infra1`、`camera/infra2`、`camera/imu` —— 只开 depth+infra1 的话 VIO 拿不到右目，所以默认给全。

**与既有工作流的关系（实测过，不是推理）**
`PartOf` + `WantedBy` 让相机成为栈的 sidecar：`systemctl stop jp5-cyberdog-stack` → 相机自动停、USB 设备释放；`start` → 相机自动回来。
所以 `/home/mi/rs-poc-run.sh`、`/home/mi/factory-node-revive.sh`（都是"停栈→独占相机→起栈"）**一行都不用改，也不会 device-busy**。`jp5-stack-doctor` 重启栈时相机跟着重启，同样正确。

**防呆**：`Restart=on-failure` + `RestartSec=20` + `StartLimitBurst=5/900s`（不做每几秒 chroot 加载 202MB 库的永动机）；`RestartPreventExitStatus=78`（缺文件类错误直接躺平等人）；`SuccessExitStatus=143`（正常停机不落 failed 态）；哨兵在 SoC ≥85°C 时拒绝动手。

**回滚**：`sudo bash /tmp/d455-stage/bin/d455-deploy.sh uninstall` —— 删干净，栈与出厂文件全程未被碰过。

## 🔴 音频路由：我们自己把调试期的错误固化进了「金标准」（已修）
`/etc/cyberdog-audio-golden.state` 里三个控件全部偏离 JP4 出厂值：

| 控件 | JP4 出厂 | 我们的 golden（错） |
|---|---|---|
| `I2S5 Mux` | `ADMAIF1` | `ADMAIF4` |
| `ADMAIF1 Mux` | `I2S5` | `None` |
| `I2S5 Loopback` | `true` | `false` |

`ADMAIF4` 是调试期用 `hw:1,3` 试喇叭留下的。后果三连：
1. **pulse 播出去的字节一个都没到功放**——语音播报全部丢进黑洞（"喇叭已验收出声"验的是 `hw:1,3` 直推，与 pulse 是两条路）
2. 没有 I2S 背压做 flow control → ADMA 以 **106 倍实时速度**空转 → `dma1chan0` 中断 **623 次/秒** → pulseaudio 常驻 89% CPU
3. AEC 参考回环饿死（`dma1chan1` 自开机只触发过 1 次）→ **这就是 athena_audio aec 线程超时的真因**

修复后实测：中断率 623→11 次/秒、pulseaudio **89%→3%**、负载 5~7→2.0、48kHz 无 xrun。已固化进 golden.state。
⚠️ **副作用（必须记住）**：`hw:1,3` 路径现在不出声了，那是错误路由。**验证喇叭必须改用 `hw:1,0`**，否则会误判"喇叭坏了"。
⚠️ 「远程无法确认声音是否真的响」——需要人耳，或机主在场。

> 顺带否决：审计原定的 `tsched=0` 方向已被实测证伪（623 次/秒的中断率证明 DMA 真在搬数据，切中断驱动只会把定时器唤醒换成硬中断，填充量一分不减）。**不要动内核、不要重建 tegra210-adma.ko。**

## 🔓 DDS 发现通了
栈用 `ROS_DOMAIN_ID=42` + `ROS_LOCALHOST_ONLY=1` + `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` +
`CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml`。用对这套环境即可从 chroot 看到全部 20 个节点、
调出厂栈的 service。此前用默认 domain 0 什么都发现不了。

## 传感器：从「推理」变成「实测」
- **前超声：实测出数**（`/mi1045904/ObstacleDetection` ~10Hz、range=0.2083m、回波幅值 8891~10161 有抖动=真回波）
- **底部 ToF、底部光流、光线传感器：实测出数**（ToF 18.6~19.6mm 与趴地姿态吻合；光线 0.2066 lux）
- **后超声：实测不存在**——全局广播使能点名，8 类传感器只有 type 7 `PROXIMITY_REAR` 一帧不出。**器件未装配，不是移植问题，不要再投时间**
- 状态表里「超声×4」是错的：实际是前超声 1 + 底部 ToF 1 + 底部光流 1
- **关键**：整个 `cyberdog_ros2` 树里没有任何开源节点会发 ENABLE（`motion_manager.cpp:168` 建了 client 但从没 `async_send_request`）。使能只可能来自闭源手机 App → **不做动作的话这些传感器在 JP5 上永远是黑的**
- 两个出厂级缺陷（JP4 上同样坏，非 JP5 引入）：`get_regulater_name()` 三次 `snprintf` 都从偏移 0 写导致 MCU 掉线自愈从未生效；底板时间戳帧只有 4 字节有效载荷而主机拷 8 字节，导致所有底板传感器时间戳是垃圾

## AI 头顶相机：R32 采集 ABI 已部署，卡在 RCE 固件侧总线错误
部署了 `build/r32-capture-backport/`（4 patch，**纯增量 +2809/-0**，全部包在 `CONFIG_TEGRA_CAPTURE_R32_ABI` 里，
9 条 `static_assert` 编译期证明 R32 布局全局生效：`CAPTURE_CHANNEL_SETUP_REQ==0x10`、`capture_channel_config==216`、
`capture_descriptor==704`）。Image `f4b6a035…`，DTB/initrd 未动，零回归。

**实测结果（走真实 argus 路径）**：
```
kernel: CPU:0, Error:rce-noc  →  Host read timeout at address 303cc (0x15a303cc = NVCSI 空间)
kernel: Camera RTCPU gone bad! restoring it immediately!!
kernel: isp capture control message timed out / isp capture setup failed
argus:  Error IoctlFailed → Failed to create CameraProvider → 断言失败
```
判别标记 `r32-abi: ... setup accepted` **没有出现**。

**定性**：消息送到了、RCE 固件开始执行了，但在解引用时落到未响应的地址上崩溃（`rce-noc` 是 RCE 自己的 NoC 端口）。
这与 NOTES 点名的头号未知数**吻合但不构成证明**——R35 的 `capture_get_gos_table()` 直接返回 count=0/table=NULL
（`nvhost_syncpt_get_gos()` 这个符号在 R35 里根本不存在），若 R32 固件解引用这张空表即是此现象。

**安全性**：RCE 崩溃**只在主动驱动采集时发生**，开机握手干净（`cmd=5`），RCE 每次都自恢复成功，
整机零影响（0 failed 单元、0 内核崩溃、WiFi/音频/6核/9 video 节点全在）。**这个内核留着是安全的。**

**下一步**：GoS 表是最该证伪的一件事，且便宜——在 JP4 引导下抓一次 `num_vi_gos_tables` 实际值。

## 🔊 喇叭修复完成（2026-07-26，机主亲耳验证）

**验证方式最硬**：修好后机主听到了**出厂语音播报**（"开始充电"、"电量低于10%"）自己响起来——不是测试音，是工厂栈自己发的。

**病根**：pulseaudio 只能选到单声道 profile，而 TAS5805M 需要立体声 I2S 帧，收到单声道帧就报 `CLK_FAULT` 并静音。

```
默认 profile-set: [Mapping analog-stereo] device-strings = front:%f   ← 这块卡没有 front:1 → profile 不可用
                  [Mapping analog-mono]   device-strings = hw:%f      ← 可用 → 只能选单声道
```

**修法（两处，都极小）**：
1. `/usr/share/pulseaudio/alsa-mixer/profile-sets/cyberdog.conf`（复制 default.conf，**只改 2 行**）：
   `analog-stereo` 的 `device-strings` 改成 `hw:%f`、`priority` 提到 20
2. 宿主 `/etc/udev/rules.d/91-cyberdog-pulse-stereo.rules`（1 行）：
   `SUBSYSTEM=="sound", KERNEL=="card*", ATTR{id}=="jetsonxaviernxa", ENV{PULSE_PROFILE_SET}="cyberdog.conf"`

**⚠️ 踩过的坑**：`load-module module-udev-detect profile_set=xxx` 在 **PulseAudio 11.1 上不支持**，会 `Failed to parse module arguments` → `Module load failed` → **整个 pulse 起不来**。必须走 udev 属性这条路。备份在 `default.pa.bak-mono`。

**验证结果**：
| 项 | 修复前 | 修复后 |
|---|---|---|
| 声卡 profile | `output:analog-mono+input:analog-mono` | `output:analog-stereo+input:analog-stereo` |
| sink | 1ch | **2ch 48000Hz RUNNING** |
| 麦克风 source | 正常 | **仍正常**（未被破坏） |
| 功放 `0x71` | `0x04` CLK_FAULT | `0x00` 无故障（放音时） |
| pulseaudio CPU | 89% → 3%（路由修复）| **0%** |
| 出厂语音播报 | 静默 | **能听到** |

判据补充：功放空闲时 `0x71=0x04` 是**正常**的（无流即无时钟），只有放音期间读到 `0x00` 才算通。

## 🔌 充电/电池（2026-07-26 实测确诊）
- 适配器插了数天，实测**充电电流恒为 0~40mA**（真充电是 3A），`checkcharge.sh` 判定"适配器已识别但没充上"
- **拔掉适配器后空载 15 秒内 SOC 从 17% 塌到 0%**，电压每 5 秒掉 80mV → **电芯失效/内阻过大，电池报废**
- "开始充电"语音只代表适配器被识别，**不代表真在充电**
- 机主已决定：先不换，全部工作完成后再买新电池

## 🚫 运动锁存 = 适配器联锁（不是欠压锁存，机主判断）
`[State_Detection] Locking state & Error state detected. Checking to passive` 5Hz 刷屏 = **充电中禁止运动的安全联锁**。
**实测**：拔掉适配器后 26次/5秒 → 0，插回来又出现。
→ **不需要长按断电清锁存**；站立前拔适配器即可（与旧记忆"站立前必须拔适配器"一致，现已从"疑似"升为实测）。

## ⚠️ USB 线插着断电会进 RCM
电池塌陷导致断电后，因下载口插着 USB 线，重新上电进了 **RCM（USB ID 变 `0955:7e19` APX，串口消失）**。
恢复：插好适配器 → **拔掉 USB 线** → 长按电源到灯全灭 → 开机。
本次恢复后 `PMC reset source: SYS_RESET_N`（真硬件复位），**全家桶全自动恢复、0 failed 单元** —— 这是"零人工干预"约束的一次有分量验证。

## 🔵 蓝牙 GATT 打通（2026-07-26）
**唯一阻塞是 chroot 内缺 `/run/dbus` bind** —— 出厂 `gattserver` 通过 D-Bus 跟宿主 bluetoothd 通信（`org.bluez` 的 `GattManager1`/`LEAdvertisingManager1`）。
补进 `jp5-chroot-prep.sh` 即通，顺带修掉 chroot 内 pulseaudio 反复刷的 "Failed to connect to system bus"。

新增 `jp5-bluetooth-gatt.{sh,service}`（宿主 unit 包装出厂 gattserver），**已设开机自启**。
验证：`get psn=P21511820GR00177ZM` / `BLE_STATUS_ADV` / `GATT application registered` / `Advertisement registered`。

**⚠️ 踩坑**：systemd 不带 `HOME`，而 ROS2 的 `rcl_logging_spdlog` 要用它展开 `~/.ros/log`，缺了直接
`rcutils_expand_user failed` → `Failed to initialize logging` → 退出。出厂 unit 是 `User=root`（systemd 自动给 HOME），
chroot 包装会丢掉，**必须显式 `export HOME=/root`**。这个只有真 `systemctl start` 才暴露，交互式试跑看不出来。

## 💡 LED 子系统实测通过（2026-07-26）
`led_server` 节点实时处理 LED 命令（`start process led cmd` / `command=28` / `command=9`），
**机主目视确认头部橙灯在闪**（低电量指示，与电池 0% 吻合）。
→ 整条链路 **ROS2 节点 → led_server → CAN → MCU → 灯珠** 全部验证，
元器件表里最后一个"只靠推理挂着"的项已结案。

## 自启服务清单（全部 enabled，2026-07-26 实测）
| 服务 | 作用 |
|---|---|
| `fanboy` | 温控守护 v2（反极性风扇曲线 + 92°C CPU 频率封顶 + 82°C 迟滞恢复） |
| `deadman` | 用户态黑匣子 |
| `audio-init` | 声卡金标准回放（v2 如实上报 + `Before=stack`） |
| `cyberdog-health` | 长稳基线采集 |
| `cyberdog-timekeeper` | 时钟单调地板（只向前推） |
| `jp5-cyberdog-stack` | chroot 出厂 ROS2 栈 |
| `jp5-cyberdog-net` | 内网/CAN |
| `jp5-boot-ok` | 清启动尝试计数器（oneshot，inactive 属正常） |
| `jp5-bluetooth-gatt` | 蓝牙 GATT（手机 App 通道） |

---

## 🗳️ ramoops 黑匣子（2026-07-26 落地并端到端验证）

**零内核改动、零 DTB 改动** —— 只在 eMMC p1 的 `/boot/extlinux/extlinux.conf` 的 `LABEL jp5` 的 `APPEND` 尾部加一串模块参数。备份 `extlinux.conf.pre-ramoops`。

```
ramoops.mem_address=0xf0800000 ramoops.mem_size=0x200000 ramoops.record_size=0x10000 \
ramoops.console_size=0x80000 ramoops.ftrace_size=0 ramoops.pmsg_size=0 ramoops.max_reason=3
```

### 为什么原来 probe -22
DT 的 `reserved-memory/ramoops_carveout` 是**动态保留**(只有 `size`/`alignment`/`alloc-ranges`，没有 `reg`)。
R35 换成上游 `compatible="ramoops"` 的 `ramoops_parse_dt()` **要求 `reg`** → `-EINVAL`。
绕法：ramoops 是 **builtin**，`ramoops_register_dummy()` 在 `mem_size!=0` 时用模块参数造一个 dummy platform device，
`platform_data` 非空就整个跳过 DT 解析。DT 那个设备随后 probe 会打一句 `already initialized`，无害。

### 地址是怎么锁死的（三重独立证据，别再靠猜）
| 证据 | 值 |
|---|---|
| 引导器交给内核的 `/memory` 节点 | `0xac200000‑0xf09fffff` |
| 内核 `memblock.memory` 实际 | `0xac200000‑0xf07fffff` |
| **内核自己挖掉的差值** | **`0xf0800000‑0xf09fffff` = 正好 2 MiB** |

- 大小与 `ramoops_carveout` 的 `size=<0 0x200000>` **精确相符**
- 位置与 memblock **自顶向下**分配器的预测**精确相符**（`alloc-ranges` 上限 4 GiB）
- DT 里**唯一**一个非零的 `no-map` 动态保留就是 `ramoops_carveout`
- `of_reserved_mem` 对 `no-map` 走 `memblock_remove()`，所以它表现为**真空洞**而不是带 flag 的区段

⚠️ **`0xac000000` 那个洞也是 2 MiB，但它是引导器的**（`/memory` 节点里本来就没有它）。
用它会写进引导器 carveout —— `request_mem_region` 不会拦（没人注册 iomem），会**静默写坏**。

### 🔴 最关键的坑：`Unlink=yes` 会抹掉当前这次开机的日志
`ramoops_pstore_erase(PSTORE_TYPE_CONSOLE)` → `persistent_ram_zap(cprz)`。
也就是**删 pstore 文件会 zap 掉【正在用的】console 环形区**。
`systemd-pstore` 默认 `Unlink=yes` 且在 **~17s** 运行 → 每次开机都把 `[0..17s]` 抹干净，
**而那正是驱动 probe 挂死的窗口，黑匣子最该看见的地方**。

实测铁证：
| | |
|---|---|
| boot B 里 systemd-pstore 运行于 | `[17.072 – 17.188]` |
| boot B 归档的第一行 | `[17.280506]` ← 紧接着的下一条 |
| boot A 归档的第一行 | `[0.000000]` ← 当时 `/sys/fs/pstore` 是空的，`ConditionDirectoryNotEmpty` 没过，**根本没运行** |

**修法**：`/etc/systemd/pstore.conf` 设 `Unlink=no`（备份 `.orig`）。
崩溃记录改由 `cyberdog-blackbox-rotate` 归档后自己 `rm /sys/fs/pstore/dmesg-ramoops-*` 消费掉 ——
erase 一个 dump prz 只 zap 它自己，**不碰 console prz**（`ramoops_pstore_erase` 的 `case PSTORE_TYPE_DMESG`）。

### 归档链
`ramoops 环形区` → `systemd-pstore`(copy, 不 unlink) → `/var/lib/systemd/pstore/` → **`cyberdog-blackbox-rotate.service`** → `/var/log/cyberdog-blackbox/<时间戳>[-CRASH]/`，保留最近 30 次。
> systemd 245 写的是**扁平文件名**(`console-ramoops-0`)，不转存的话下次开机直接覆盖，黑匣子只有一层深。
> 目录名带 `-CRASH` 表示上次是**真崩溃**(有 `dmesg-ramoops-*`)，一眼可辨。

### 验收（5 次重启实测）
- `ramoops: using 0x200000@0xf0800000, ecc: 0`；`/proc/iomem` 24 个 `ramoops:dmesg(N/23)` + `ramoops:console`，正好铺满 2 MiB
- 归档 **796 行 / 55639 字节**，首行 `[0.000000] Booting Linux on physical CPU 0x0000000000`，末行 `[72.434193] reboot: Restarting system`
- 用户态面包屑：`<3>`/`<4>` 前缀能进环形区；**无前缀的 `/dev/kmsg` 进不去** —— `printk` 是 `6 6 1 7`，
  `default_message_loglevel=6` 而 `6 >= console_loglevel(6)` 被过滤。写黑匣子必须带 `<4>` 或更低。
- 零回归：6/6 温区、6 核 pmode2、0 failed、36 模块、9 video、2 声卡、rmem 26MB、zram 6、
  RCE cmd=5、CAN UP、eth0 5075 pkt/s、`I2S5 Mux=ADMAIF1`、功放 `0x71=0x00`、31 个 ROS2 节点

### ⚠️ 覆盖边界（别高估它）
| 场景 | 能不能拿到 |
|---|---|
| panic / oops（`panic=15` 自动热重启） | ✅ |
| 正常重启、异常重启 | ✅ |
| **真挂死需要拔电** | ❌ **DRAM 掉电即失** |
| 热跳闸断电 | ❌ 同上 |

~~补这个缺口的唯一办法是**在救援笔记本上常驻串口日志**(`/dev/ttyACM0` → 落盘)，与 ramoops 互补。~~
🔴 **2026-07-27 实测：`/dev/ttyACM0` 补不了这个缺口**（它是 USB gadget 的 ttyGS0，T+19.4s 才存在）。详见下节。

---

# 2026-07-27 追加

## 🔴 「串口控制台」这条救援路是假的（三重安全网实为两重）

笔记本上的 `/dev/ttyACM0` **不是内核控制台**，是 L4T USB gadget 的 `acm.GS0` → 狗侧 `/dev/ttyGS0`，上面只有一个 `agetty`。

| 证据 | 结果 |
|---|---|
| `/proc/consoles` | `tty0` / `ttyTCU0` / `ramoops-1` —— **没有 ttyGS0** |
| 写 `/dev/kmsg` | 笔记本收不到 |
| 直接写 `/dev/ttyGS0` | 笔记本**收到** |
| gadget 创建时刻 | `nv-l4t-usb-device-mode` 在 **T+19.4s**，agetty 在 T+89s |
| 笔记本 `lsusb` | 只有 `0955:7020`，**没有第二个 usb-serial 桥** |

内核启动只花 **15.7s** → 引导器输出与 probe 挂死整个落在 `[0, 19.4s]` 盲区，**这条线原理上看不见**，也够不着 extlinux 菜单。
以前"实测打回 `cyberdog-jp5 login:`"是真的，但那是 agetty，只能证明狗已经完成启动。

**已部署（笔记本 `ben@10.0.0.176`）**：`cyberdog-serial-log.service` + `/usr/local/bin/cyberdog-serial-log.py`
→ 落盘 `/var/log/cyberdog-serial/console.log`（logrotate 14 天）。
- **只读打开**（`O_RDONLY`）+ `CLOCAL` + `-HUPCL`：从 OS 层面保证我们不可能往那个口写一个字节
  （狗的 extlinux 菜单在等按键，写进去会改启动项）
- 用 by-id 稳定路径，设备消失（狗重启/RCM）不是错误，自动等回来
- **实际覆盖**：T+19.4s 之后的用户态输出、掉线/回归的精确时刻、login 提示。**不覆盖早期启动。**

**要补早期盲区只有一条路**：接板上调试 UART（`ttyTCU0`）到 USB-TTL(3.3V)。⏸️ 需机主动手。

## ✅ ov_msckf 单目 VIO 上线（`ov-vio.service`）

栈的 sidecar（`WantedBy` + `PartOf`，与 d455 同一套语义）。**修掉两个会静默出错的坑**：

1. **内参对不上**：出厂 launch 硬编码 640x480（`fx=388.36 cx=319.38 cy=240.99`），而 D455 跑在 848x480（`fx=429.77 cx=427.41 cy=236.46`，cx 差 **108 像素**）。
   内参错了 VIO **不报任何错**，只是安静输出错误轨迹。已按 `camera_info` 实测值覆盖，节点启动打印证实：`cam_0_wh: 848 x 480` / `cam_0_intrinsic: 429.766 429.766 427.407 236.462`。
   （外参 `T_C0toI` 平移 `[-0.03, 0.007, 0.016]` 与 D455 手册 IMU→左红外偏移吻合，且与分辨率无关 → 保持出厂值。）
2. **IR 点阵发射器**：开 depth 就开投射器，infra 上的散斑**跟着相机走** → 无视差的假特征 → KLT 咬住它们 → VIO 认为自己没动。**不是精度问题，是结果无效。**
   实测 A/B（相邻像素绝对差均值）：**ON=4.152 / OFF=1.376**。
   由 service 启动时关、停止时还原（`ov-vio-emitter.sh`，双向实测过）。代价：depth 退化成纯被动双目（当前 depth 订阅者=0）。

**lifecycle 陷阱**：`ros_subscribe_msckf` 是 managed 节点，起来后停在 `unconfigured` 只发 `transition_event` —— 极易误判成"坏了"。必须显式 configure→activate。
（另：手写 params.yaml 漏 `stereo_pairs` 会让 configure 抛异常，所以坚持用出厂 launch 只覆盖内参。）

**实测无回归**：0 failed、6/6 温区、63°C、eth0 **5089 pkt/s**（基线 ~5075，运动板没被抢）、相机 infra 30.3Hz / imu 198.6Hz。
⚠️ VIO 占 **171% CPU**（1.7/6 核），load→12，靠 `Nice=10 + CPUWeight=30` 让路。要降可调 `num_pts` 或开 `downsample_cameras`。
⏸️ **必须机主在场才能验收**：VIO 需要运动才初始化（`no IMU excitation 0.0147 < 0.4`，狗静止是**正确行为**）。
注：本机是小米改版，输出话题是 `odomfoot`/`odomfusion`/`poseimu`/`pathimu`，不是原版 `odomimu`。

## ✅ 传感器开机自动使能（`cyberdog-sensors.service`）

| 话题 | 使能前 | 使能后 |
|---|---|---|
| `/ObstacleDetection` | **0.00 Hz** | **10.13 Hz**（真回波 0.2227m） |
| `/BodyState` | **0.00 Hz** | **25.01 Hz** |

坐实了旧判断：开源树里没人发 ENABLE（`motion_manager.cpp:168` 建了 client 却全树零次 `async_send_request`），本该由闭源手机 App 发。
用 `ception_msgs/srv/SensorDetectionNode`：`obstacle_detection` 发 `ENABLE_ALL(4)`；`athena_body_state` 发 `ENABLE_ROTATION_VECTOR(50)`+`ENABLE_SPEED_VECTOR(52)`；`timeout=ALWAYSON`，`clientid=9`（避开出厂 BMS=1/BT=2/AUDIO=3）。
服务**自验收**：光有 `success=True` 不算，要话题真出数达标才算成功。
⚠️ 我们是常驻 ALWAYSON client（引用计数语义）→ 手机 App 之后关不掉这些传感器。要还原：`SENSOR_DISABLE=1` 跑一次。

## 🔴 新踩的坑：`chroot ... su - mi -c` 在无 tty 时吞掉内层 stdout

手工跑（有 tty）能看到全部输出，**systemd 起的时候 journal 里一行都没有**；加 `python3 -u` 无效（不是 python 缓冲，是 `su` 那一层）。
对"价值全在自验收输出"的服务等于白做。**修法**：包装器先把输出抓进变量，再由自己逐行 echo。
⚠️ 同一个吞噬也影响既有的 `d455-camera-inner.sh` 和新的 `ov-vio-inner.sh` 的内层日志（关键输出走宿主侧脚本，所以只是观测性损失）。

## ✅ GPS 改判：链路是通的，不需要写桥

原判断「出厂节点没有串口读线程 → 数据链没通 → 得自己写个桥」**是错的**：
1. 开源 `scene_detection.cpp:243-250` **本来就有**读线程，init 里就 `SetMsgRate(0xF0,…)` 开了 GPGGA/GPRMC/GPSV
2. 出厂 `service_scene_detection` **独占持有** `/dev/ttyTHS0` 并在读 —— 再写一个桥只会互相抢字节
3. 串口实测活着：合法 Bream/UBX 帧同步头 `0xB5 0x62`（class 0x04 INF / 0x02），并抓到 `$GP`/`GGA` 片段
4. 静默的真因在 `gps_data_receiver_callback`：`if (flag==1 && (lat!=0 || lon!=0))` —— **没有效经纬度就一条不发**。室内无星 → 0 Hz 是**出厂正确行为**
5. `GPS_START` 服务返回 success

**唯一没验证的是室外能不能定星** ⏸️ 需机主把狗抱到露天。
体检工具：`cyberdog-gps-check.sh`（驱动层 + 串口活性 + ROS 话题层，一条命令）。
⚠️ 波特率 **3000000 是对的**，别去"修"它。

## 🔬 kernel-E 炸机静态分析（§6.4 前置，零风险离线完成）

1. **kernel-E 实际改了什么**：DTB 侧只有两处功能改动 —— 触摸板（已证明是好的，今天仍在跑）+ 相机电源拓扑（`nvcsi/vi/vi-thi/isp` 加 power-domains+resets+clocks）。ramoops 根本不在 DTB 里（纯 extlinux cmdline），"H2 拆分"对 DTB 输出零影响。Image 侧多了 C 补丁 0002/0003/0004：`camrtc_device_group` 标记 good=**1** / failed=**4**，`nvcsilp` good=0 / failed=1。
2. 🔴 **A/B 对照没有真正隔离元凶**：撤除时 DT 那半和 C 补丁那半是**一起**撤的。现有证据只支持"相机电源这项工作整体是元凶"，**不支持"具体是 DT 还是 C 补丁"**。下次必须拆成两个独立可启动变体（血的教训#1 的直接应用）。
3. ✅ **排除掉一个主要假设**（实测只读）：原怀疑"R32 BPMP 不认识 VE 域 → MRQ 无应答 → 阻塞"。实测证伪 —— BPMP debugfs 完整暴露 `powergate/ve` 和 `powergate/ispa`，`powergate_summary` 正常应答，`ve/state`=0、`ispa/state`=0 读取 rc=0，且**同一条 MRQ 路径上 aud/disp/xusba-c/pciex8a/gpu 正在被实际使用且已上电**；补丁引用的时钟 `nvcsilp` 204MHz、`vi_const` 408MHz 在运行内核里都存在且健康。
   → **BPMP 通信层是好的，挂死点在内核侧的 attach / runtime-PM / reset 时序。**
   头号嫌疑：`t19_nvcsi_info` 的 `.keepalive`/`.poweron_reset`，以及 `camrtc_device_group_busy()` 被放在 `tegra_cam_rtcpu_runtime_resume()` 里跨设备跨域嵌套 `pm_runtime_get_sync()`。
4. ✅ **VE / ISPA 点火实验已做（2026-07-27，机主在场）—— 结果是关键的好消息**，见下节。

## ✅ 冷启动验收（连续两次重启，零回归）

验收脚本 `cyberdog-acceptance.sh` —— 重启前后跑同一份，逐行 diff 即回归报告。

两次重启后全部一致：`0 failed`、6/6 温区、pmode 2、rmem 26MB、0 oops、0 deferred、9 video、2 声卡、
can0 UP、`I2S5 Mux=ADMAIF1`、eth0 **5107 pkt/s**、37 个 ROS2 节点、
相机 30.2Hz / imu 196.9Hz、`ObstacleDetection` 10.0Hz、`BodyState` 25.0Hz、
`ov_msckf` **active [3]**、`emitter_enabled=0`、黑匣子归档 4→6（每次开机都归档，首行 `[0.000000] Booting Linux`）。

**两个新服务冷启动自证**（journal 原文）：
```
[ov-vio-emitter]  emitter_enabled=0 OK (attempt 1)
[ov-vio-activate] final state: active [3]
[cyberdog-sensors] OK /mi1045904/ObstacleDetection -> 9.93 Hz
[cyberdog-sensors] OK /mi1045904/BodyState -> 23.70 Hz
[cyberdog-sensors] RESULT: all sensor groups enabled and verified
```

## 🔴 新问题：传感器使能会运行时退化，且**重发 ENABLE 救不回来**

运行约 11 小时后实测 `ObstacleDetection` 从 10 Hz **掉到 0.00 Hz**（`BodyState` 从 25 降到 15，未归零）。

排查结论（都是实测）：
| 层 | 状态 |
|---|---|
| CAN 总线 | ✅ 健康：`ERROR-ACTIVE`、berr-counter 0/0、零 bus-error/bus-off、rx **45 pkt/s** |
| ROS 服务端 | ✅ 应答正常：重发 `ENABLE_ALL` 返回 `success=True, clientcount=2` |
| 话题 | ❌ 仍然 **0.00 Hz** |
| 强制刷新（`DISABLE_ALL` → `ENABLE_ALL`） | ❌ 无效，且 `DISABLE_ALL` 后 clientcount **没有下降** |
| 重启 | ✅ **当场恢复到 10 Hz** |

→ 典型的**引用计数记账与硬件真实状态漂移**：服务端认为"已经开着，不必再下发"，而 MCU 侧那一路其实已经卡死。
→ 和出厂那个已知缺陷吻合：`get_regulater_name()` 三次 `snprintf` 都从偏移 0 写，导致 **MCU 掉线自愈从未生效**（JP4 上同样坏）。
→ **待办**：加一个传感器健康哨兵（timer，发现 0 Hz 持续 N 次就重启栈并告警）。目前唯一恢复手段是重启。

## 🔴 狗重启会打死笔记本的 xHCI（USB 救援通道没有想象中可靠）

第二次重启后笔记本 `lsusb` 上**整个 bus 003 全没了**，dmesg：
```
xhci_hcd 0000:00:14.0: xHCI host controller not responding, assume dead
xhci_hcd 0000:00:14.0: HC died; cleaning up
```
狗侧完全正常（UDC 已绑定、4 个 function 都在、`/dev/ttyGS0` 在、`EP 0 enabled`）—— **是笔记本侧的控制器猝死**。

**救法**（已实测，来自旧记忆条目）：
```bash
echo 0000:00:14.0 | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind
sleep 3
echo 0000:00:14.0 | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind
```
⚠️ 先确认笔记本的 ssh 不走 USB 网卡（本机走 PCIe 的 `wlp0s20f3`，安全）。
⚠️ **含义**：USB 救援通道（192.168.55.1）和串口日志在狗重启后**可能需要人工 unbind/bind 才能恢复**。
做高风险内核改动前要把这条算进去 —— 它不是无人值守可靠的。

## 🔧 串口记录器修掉两个缺陷（都是 A1 重启验收暴露的）

1. **设备重新枚举后记录器抱着死 fd 空转**：狗重启后 by-id 符号链接从 `ttyACM0` 指到了 `ttyACM1`，
   而旧 fd 指向已消失的 ttyACM0，`read()` 只是一直返回 `EAGAIN` **不报错** →
   记录器看似在跑、实际永远收不到一个字节，**整个重启窗口一行没记到**。
   修法：每秒 `os.stat(dev).st_rdev` 与 `os.fstat(fd).st_rdev` 比对，变了就重开。
2. **`StartLimitIntervalSec` 放错 section**：写在 `[Service]` 里会被 systemd 当未知键忽略
   （`Unknown key name 'StartLimitIntervalSec' in section 'Service'`），限流形同虚设。必须放 `[Unit]`。

修后实测闭环：`device re-enumerated, reopening` → `waiting for …` → 设备回来自动重连 → 捕获到 `cyberdog-jp5 login:`。

## ✅ VE / ISPA 电源域点火实验：**能上电，且完全干净**（2026-07-27，机主在场）

AI 相机主线上最便宜、最决定性的一步。只写 NVIDIA 自己的 BPMP debugfs，不动内核、不动 DT、不重启。

| 步骤 | 结果 |
|---|---|
| `echo 1 > powergate/ve/state` | ✅ 写入成功，`ve: 0 → 1` |
| `echo 1 > powergate/ispa/state` | ✅ 写入成功，`ispa: 0 → 1` |
| 新增 oops / `rce-noc` / SMMU fault | **0**（点火后、静置 10s 后、恢复后三次采样都是 0） |
| failed units / 温度 | 0 / 65.5°C 无变化 |
| 恢复 `echo 0` | ✅ 两个域都干净落回 0，系统仍在线 |

### 为什么这条结论很重要

**这套 `R32 BPMP 固件 + R35 内核` 的混血系统上，VE 和 ISPA 电源域本身完全可以正常上下电。**
也就是说 kernel-E 炸机 **不是"电源域这条路走不通"**，而是 **内核侧的 attach / runtime-PM / reset 时序**问题。
配合前面已经排除的 BPMP 通信层，现在可以把嫌疑范围收得很窄：

- `t19_nvcsi_info` 的 `.keepalive` / `.poweron_reset`
- `camrtc_device_group_busy()` 被放在 `tegra_cam_rtcpu_runtime_resume()` 里跨设备跨域嵌套 `pm_runtime_get_sync()`
- `vi_thi` / `isp` 这两个**没有 `reg`** 的节点被加上 `power-domains` 后的 attach 行为

→ **重做 NVCSI 电源域的把握度显著提高**，NOTES 里原来写的 70–80% 可以上调。

### 一个必须记住的细节

BPMP 侧 `ve/state=1` 的同时，内核 genpd 里仍然是 `ve off-0`，`nvcsi/nvcsilp/vi` 的 `enable_cnt` 仍然是 0。
**BPMP 记账与内核 genpd 记账是两套**，直接写 debugfs 会绕过 genpd。
所以这个实验证明的是「硬件+BPMP 能上电」，**不等于**「内核把设备挂上去之后也能正常走完 attach」——
后者正是 kernel-E 死掉的地方，必须靠拆分变体去验。

### 顺带发现的噪音（不紧急）

`uvcvideo: Failed to query (GET_CUR) UVC control 1 on unit 3: -32` 在持续刷屏（-32 = EPIPE），
来自 D455 的 UVC 控制查询。当前不影响取流（30.2Hz 稳定），记一笔待查。

## ✅ 背部触摸板：物理确认通过（2026-07-27，机主亲手）

元器件表最后一个"只靠推理挂着"的项结案。

**判据用 GPIO 中断计数，不用 input 事件流** —— 因为出厂 `touch_publisher`（`service_athena_`）
**独占读走了 `/dev/input/event0`**，自己起个 `cat /dev/input/event0` 抓不到任何东西，
很容易误判成"触摸板没反应"。中断计数骗不了人：

```
gpio 103 Level synaptics_dsx
  机主第一次摸后 : 10
  机主第二次摸后 : 28     (+18)
```
出厂话题 `/mi1045904/TouchState` 在发。→ 硬件 → RMI4 中断 → 驱动 → input → 出厂节点 → ROS 全链路确认。

## 🔴 单目 VIO 在静止时必然发散 —— 必须开 ZUPT（出厂默认是关的）

机主抱起狗轻晃后实测（狗约 14kg，只能轻晃）：

| 指标 | 实测 |
|---|---|
| `pathimu` y 范围 | -4.6 .. **90.0 m** |
| 相邻两点最大步长 | **97.6 m** |
| 实际移动 | 不到 2 m |
| 当时 `poseimu` | 全零 + 零协方差 |

**这不是 bug，是单目方案的固有特性**：单目 VIO 的尺度只能靠平移激励观测，几乎静止时尺度不可观、
协方差爆掉。出厂 launch 的 `try_zupt: false` 是给手持数据集调的参数，
对一条**大部分时间站着不动**的四足狗完全不适用。

**已改为 `try_zupt:=true`**（配 `zupt_max_velocity=0.5 / zupt_noise_multiplier=50 / zupt_chi2_multipler=2`，
均为出厂已有的默认值），由 `OV_VIO_ZUPT` 环境变量可关。
重启后实测：狗静止 → VIO 不初始化 → `pathimu` 无数据 = **正确行为**（不再吐垃圾轨迹）。

⚠️ **下游别盲信 VIO**：它在没有持续平移激励时不会给出可用位姿。真实验收仍需狗自己行走。

## ⛔ B1 物理调试串口：确认走不通（2026-07-27）

机主实地确认：**狗身上没有任何裸露的调试串口**，只有 3 个 Type-C（充电 / Download / Extension）+ 1 个 HDMI，**且不能拆机**。

软件侧佐证：
- `ttyTCU0` = `combined-uart`（内核控制台），物理输出在板上 UART 引脚
- `ttyTHS0`=GPS、`ttyTHS1`，其余 6 个 serial 节点 DT 里全是 `disabled`
- **无 `typec` class** → 没有 Type-C PD/altmode 驱动栈，Extension 口无法靠软件配成调试 UART

→ **早期启动盲区（[0, 19.4s]）永久补不上。**

### 因此 AI 相机改用「RCM 兜底」模式推进

| | |
|---|---|
| 安全网 | RCM 裸机刷写（`--boot recovery`，0726 实战一次成功，1.6GB/103s） |
| 触发 | 挂死 → 机主拔电重启；**USB 插着断电正好进 RCM**，此场景下反而是我们要的 |
| 定位 | 拆成两个独立可启动变体，炸了也知道是哪半 |
| 热重启场景 | ramoops 黑匣子照常捕获 |
| 代价 | **每次内核实验必须机主在场** |

配合已证实的「VE/ISPA 能干净上电」，这条路值得走。

## 🔬 变体 B（纯 C 补丁）实测：**单独就足以炸掉内核**（2026-07-27/28）

拆分变体的价值当场兑现 —— kernel-E 那次炸完什么都不知道，这次炸完**排除了一半**。

**部署**：只换 Image（`bdf077cf`），DTB 保持 good（`2228d7ab`）一字节未动。
**结果**：重启后 4 分钟内 —— 笔记本上 `lsusb` **完全看不到 `0955` 任何设备**、
USB 和 WiFi 都不通、串口日志停在设备消失那一刻。

→ USB gadget 由 `nv-l4t-usb-device-mode` 在 **T+19.4s** 创建，它连出现都没出现，
说明 **probe 挂死发生在 T+19.4s 之前**，正落在那个补不上的盲区里。

### 🔴 结论：元凶**不在** DT 那半

我原本预测变体 B 更温和（DT 里没有 `power-domains`，`nvhost_module_busy()` 只会开时钟、
不触发 genpd 上电）。**预测错了。** 纯 C 补丁单独就炸。

嫌疑收窄到 patch 0003/0004 的这三处之一：
1. `t19_nvcsi_info` 的 `.keepalive` / `.poweron_reset`（0004）
2. `camrtc_device_group_busy()` 在 `tegra_cam_rtcpu_runtime_resume()` 里跨设备嵌套 `pm_runtime_get_sync()`（0003）
3. `camrtc_device_group_reset()` 放在 `tegra_camrtc_deassert_resets()` 之前（0003）

**下一轮继续二分**：先只上 0002+0004（不上 0003），或只上 0002+0003（不上 0004）。
注意 0002 单独是纯增量函数定义，没有调用点，理论上是死代码 → 可以并入任一组作为对照。

### ✅ 救援链路实战复验（这次是真用上了，不是演练）

| 环节 | 结果 |
|---|---|
| WiFi | 重启**之前**就自己断了（路由抽风的老毛病，`wlan0 NO-CARRIER`） |
| **USB 救援通道** | ✅ **救了场**：`192.168.55.100 ↔ 192.168.55.1`，1.757ms |
| 进 RCM | ✅ 拔适配器（USB 保持插着）→ 重新上电 → `0955:7e19 APX`，Device 号 007→008 |
| RCM 刷写树 | ✅ 真树在 `~/cyberdog-flash/xiaomi-sdk`（550M，工具齐全） |

⚠️ **两个必须记住的坑**：
1. `~/cyberdog-flash/Linux_for_Tegra` 是**残骸**（只剩 `bootloader/pyfdt`），真树是 `xiaomi-sdk`。
   笔记本上还有个 `JetPack_6.2.2_..._ORIN_NANO_TARGETS` —— **那是 Orin Nano 的，绝不能用在 CyberDog 上**。
2. **0726 的 `APP-raw.img` 不能直接写回**：里面 `boot-jp5/Image` 是 `f4b6a035`（r32cap 那批），
   且 `extlinux.conf` 里 **ramoops 配置为 0**。写回会丢掉 ramoops 黑匣子 + 触摸板批次。
   必须走「读出当前 p1 → 只改 Image → 写回」。

**USB 通道已持久化**：笔记本上建了 nmcli 连接 `cyberdog-usb`（按 MAC `de:9f:89:2d:cf:82` 匹配 +
autoconnect），重启后自动上线，不用再手工配地址。

## 💡 HDMI 很可能是被忽略的控制台（待验证，可能部分替代串口）

狗有 1 个 HDMI 口，而且：
- 内核 cmdline 里有 **`console=tty0`** 和 **`fbcon=map:0`**
- `/proc/consoles` 里**确实有 `tty0`**（`-WU (EC p )`，带 E=enabled、C=console）

→ **接一台显示器很可能就能看到内核启动日志**，包括 probe 挂死时的最后几行 ——
那正是 ttyGS0（T+19.4s 才存在）看不到的盲区。
再配一个 USB 键盘（Extension 口转 USB-A）还能在 extlinux 菜单里选 `primary`（JP4 内核）自救，
**不用走 RCM**。

⏸️ 待机主用显示器验证。如果成立，这是「不能拆机、没有调试排针」这个死局的实际解法。
局限：只能人眼看/拍照，无法自动落盘归档。

## ✅ RCM 救砖实战复盘（2026-07-28，变体 B 炸机后）

**完整流程（已跑通，可照抄）**：

```bash
# 前置：拔适配器断电(USB 保持插着) → 重新上电 → lsusb 出现 0955:7e19，且 Device 号必须变
cd ~/cyberdog-flash/xiaomi-sdk

# ① 读出 APP 分区（约 100s，产出 Android 稀疏镜像 ~444MB）
sudo NO_RECOVERY_IMG=1 ./flash.sh --no-systemimg -k APP \
     -G ~/cyberdog-flash/APP-current.img jetson-xavier-nx-athena mmcblk0p1

# ② 稀疏 → raw，挂载，外科式只改要改的
sudo simg2img ~/cyberdog-flash/APP-current.img ~/cyberdog-flash/APP-current.raw
sudo mount -o loop ~/cyberdog-flash/APP-current.raw /mnt/appcur
sudo cp /mnt/appcur/boot-jp5/Image /mnt/appcur/boot-jp5/Image.failed-variantB   # 坏的留档
sudo cp /mnt/appcur/boot-jp5/Image.pre-variant /mnt/appcur/boot-jp5/Image       # good 换回
sudo umount /mnt/appcur

# ③ 🔴 必须再断电一次重进 RCM（见下），然后立刻写回（约 111s，会自动 coldboot）
sudo NO_RECOVERY_IMG=1 ./flash.sh --no-systemimg -k APP \
     --image ~/cyberdog-flash/APP-current.raw jetson-xavier-nx-athena mmcblk0p1
```

### 🔴 四个实测确认的坑

1. **RCM 会话是一次性的，读操作会把它用掉。**
   读完直接写会报 `Error: probing the target board failed`，而此时 `lsusb` **仍然显示 `0955:7e19`**。
   判据只能看 **Device 号变没变**（本轮：008 读 → 写失败 → 断电 → 010 写成功）。
2. **`-G` 产出的是 Android 稀疏镜像**（魔数 `3aff26ed`，444MB），**不能直接 mount**，
   必须先 `simg2img` 转成 1.5GB raw。写回用 `--image <raw>` 即可（flash.sh 自己处理）。
3. **真刷写树是 `~/cyberdog-flash/xiaomi-sdk`**（550MB，工具齐全）。
   同目录的 `Linux_for_Tegra` 只剩 `bootloader/pyfdt`，是**残骸**。
   ⛔ 笔记本上还有 `JetPack_6.2.2_..._ORIN_NANO_TARGETS` —— **那是 Orin Nano 的，绝不能用在 CyberDog 上**。
4. **0726 的 `APP-raw.img` 不能直接写回**：其 `boot-jp5/Image` 是 `f4b6a035`（r32cap 批次），
   `extlinux.conf` 里 **ramoops 计数为 0**。写回会丢掉黑匣子 + 触摸板批次。必须走"读→改→写"。

**结果**：Image 恢复 `b082b8ea`、DTB 全程未动 `2228d7ab`、ramoops 配置保留、
坏的留档为 `Image.failed-variantB`。开机后 **0 failed / 6-6 温区 / 37 节点 /
相机 30.4Hz / 传感器 10.0+25.1Hz / eth0 5088 pkt/s**，WiFi 也自己回来了。

## 🔴 `ov-vio.service` 必须 `Restart=always`（已修）

实测：VIO 起来并 activate 成功后约 2 分钟**自己退出**，journal 里是
`ov-vio.service: Succeeded.` 紧跟 ExecStopPost 把发射器还原成 1。
因为退出码落在"成功"区间（0 或 `SuccessExitStatus=143`），**`Restart=on-failure` 不会重启** —— VIO 就永远躺平了。

⚠️ **外部可见的现象只是「`emitter_enabled` 莫名其妙变回 1」**，极难联想到是 VIO 没了。
根因未查清（栈的日志把现场淹了），但一个纯感知的常驻服务不该"安静消失且永不回来"。
已改 `Restart=always`（配 `StartLimitBurst=5/900s` 限流兜底）。

## ℹ️ 小坑：狗上跑着 dhcpd，与手工静态 192.168.55.100 冲突

日志里会刷 `Abandoning IP address 192.168.55.100: pinged before offer`。
不影响连接（静态地址照常工作，且重启后立即可用不用等 DHCP），记一笔备查。

## ✅ 自动复活基础设施：`hung_task_panic=1`（2026-07-28，零内核零 DTB）

机主要求**全自动、尽量不要人为干预**。为此先补上"挂死能自动变成可恢复事件"这一层。

**关键推理**（不是猜的）：`softlockup_panic` 编译时就是 1
（`CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y`，sysctl 实测为 1），而变体 B 炸掉时
**并没有自己热重启**（4 分钟死寂）→ 说明它**不是** "CPU 卡在内核态不调度"，
而是 **D 状态永久等待**（`wait_for_completion` / mutex 之类）→ 归 `hung_task` 检测器管，
而 `hung_task_panic` 默认是 **0**。

**已加到 `LABEL jp5` 的 APPEND**（备份 `extlinux.conf.pre-hungtask`）：
```
hung_task_panic=1 hung_task_timeout_secs=60
```

**验证生效的硬证据**：`CONFIG_BOOTPARAM_HUNG_TASK_PANIC is not set`（编译默认 **0**），
而重启后 `sysctl kernel.hung_task_panic` = **1** → cmdline 确实被内核吃进去了。
⚠️ `hung_task_timeout_secs` **没有** `__setup` 处理器（只是 sysctl），所以仍是默认 120s。
对 probe 挂死检测够用，不必纠结。
⚠️ dmesg 里这两个参数会出现在"传给 init 的环境变量"列表里，**这不代表没生效**
（`earlycon`/`tegraid` 也在同一列表，它们显然是生效的）。

**误报风险已评估**：6 次历史开机 + 本次，`INFO: task ... blocked` 实测命中 **0**；
重启后 0 failed / 6-6 温区 / 0 oops / 0 panic。

时序可行性：`hung_task_init()` 是 `subsys_initcall`(level 4)，驱动 probe 多在
`device_initcall`(level 6) → **khungtaskd 先启动，抓得到 probe 阶段的 D 状态挂起**。

### ⚠️ 但光有 panic 还不够（重要，别高估这一层）

panic → 热重启 → **还是同一个坏内核** → 再 panic → **无限循环**，仍然要人来救。
真正的无人干预还需要下一层：**危险代码必须发生在 initrd 之后**
（那时 initrd 守卫已经把"下次用 good 内核"写下去了，热重启就会自动落回好内核）。

**"把驱动编成模块来延后 probe"这条路已排除**：
`TEGRA_CAMERA_RTCPU` 在 Kconfig 里是 **`bool`** 而非 `tristate`，只能 y/n，不能 m。

→ 正解是**运行时开关**：驱动照常内建、probe 时不做任何危险操作，
只注册一个默认关闭的开关；由 userspace 触发。挂死 → panic → 热重启 → 开关回到默认 0 → 自愈。

## ✅ 变体 C：R32 相机上电契约「运行时开关版」（2026-07-28，已构建待部署）

**这是实现"全自动实验"的核心构件。**

```
变体 C = 0002（纯函数定义，无调用点）
       + 改造后的 0003（三处调用包在 r32_camera_power 开关里，默认 0）
       ✗ 故意不含 0004
```

### 为什么必须是运行时开关（两条硬约束）

1. **probe 挂死必然发生在 initrd 之前**：这些调用点跑在 rtcpu 的 probe 路径 =
   `device_initcall`，而**所有 initcall 都在 initrd 的 `/init` 之前跑完**
   （dmesg 实证：`[5.58] jp5-init: up`）→ initrd 里的自动回滚守卫**永远看不到它**，
   没有任何自动回来的路，只能人工拔电 + RCM。
2. **不能靠"编成模块"推迟 probe**：`TEGRA_CAMERA_RTCPU` 在 Kconfig 里是
   **`bool` 而非 `tristate`**，只能 y/n。

### 为什么刻意不含 0004

0004 给 `t19_nvcsi_info`/`t19_vi5_info` 加了 `nvcsilp`/`vi-const` 时钟，
而 `nvhost_module_init()` 里有 **`clk_prepare_enable()`** —— 那是 **probe 阶段就执行**的，
**运行时开关关不掉**。先把能关的关掉、单独验证 0003 这一半。

> 顺带发现：0004 里的 `.keepalive = true` 是**死字段** ——
> `keepalive` 在 R35 的 `nvhost_acm.c` 里**根本不存在**，NVIDIA 连读它的代码都删了。
> 所以 0004 的真实风险只在时钟那部分。

### 全自动闭环

| 步骤 | 谁 | 失败时 |
|---|---|---|
| 内核启动 | 自动 | 开关默认 0 ⇒ 等价 pristine，**必然起得来** |
| `echo 1 > /sys/module/tegra_camera_rtcpu/parameters/r32_camera_power` | 远程 | — |
| 触发 RCE runtime resume | 远程 | 挂死 → `hung_task_panic` → **ramoops 记 call trace** |
| 恢复 | **自动** | `panic=15` 热重启，参数回 0 → 狗自己回来 |

### 构建方法论

注入用**精确字符串锚定 + 断言命中次数**，不用 patch 上下文
（这棵树的行号已经漂过一次 —— `0001` 就是那么冲突的）。四处锚点任一命中数不对就整体失败并回退。
构建后确认源码树两项残留均为 0，避免污染下一个变体。

**产物**：`build/nvcsi-variants/C-gated/Image`，sha256 `8bc45ee7f8d4fd1f…`
符号验证：`r32_camera_power` 1 / `camrtc_device_group_busy` 1 / `camrtc_device_group_reset` 1 /
**`nvcsilp` 0**（确认不含 0004）。

## 🔴 变体 C 也炸了 —— 我的"开关默认关⇒必然安全"是未经验证的假设（2026-07-28）

**推理错误**：我把"开关默认关"直接等同于"行为等价 pristine"，但变体 C 相对 good 内核
实际引入了**两处**变化，我只审了其中一处：

| 变化 | 我的判断 | 实际 |
|---|---|---|
| 注入的三处 gated 调用 | 开关关 ⇒ 不执行 | 大概率成立（initcall 确实跑完了） |
| **patch 0002 的函数定义** | "纯死代码，无调用点" | **未经验证的假设** |

R35 是把 `device-group.h` 的声明保留、定义删除 —— NVIDIA 通常**成对处理**。
我没核实"补回定义后是否有别处引用被激活"就下了"安全"结论。

### 但这次并非白炸 —— 两个硬事实

1. **`usb 3-5: Product: CyberDog JP5 initrd` 的 gadget 出现了**（存在 10 秒后正常交接）
   → **内核所有 initcall 跑完了** → **运行时开关确实挡住了 probe 阶段的挂死**，
   变体 C 的核心设计是有效的。
2. 挂死落在 **initrd 之后、`nv-l4t-usb-device-mode`(T+19.4s) 之前** ——
   与变体 B（连 initrd gadget 都没出现）**是两种不同的故障**。
3. 6 分钟内**没有热重启** → 这个挂死既不是 `hung_task` 也不是 `softlockup` 能抓到的类型。

### 🔑 第 2 点的推论：initrd 守卫这次够得着

既然挂死在 initrd 之后，**initrd 里的启动尝试计数器已经递增过**。
→ 下一步该改的是**流程**而不是补丁：做成「一次性实验启动项」

```
① good 系统里：实验内核放 /boot-jp5/Image.exp，加 LABEL jp5-exp，DEFAULT 指向它
② initrd 守卫加一句：发现本次启动的是 jp5-exp → 立刻把 DEFAULT 改回 jp5
③ 若挂死 → 只需拔电重启一次 → 直接走 good 内核，零 RCM
```
成本从「两次拔电 + 4 分钟 RCM 刷写」降到「一次拔电」。
**后续每一步二分都依赖这套机制，否则代价不可持续。**

### ⚠️ RCM 写回会冲掉 extlinux 的后续改动

本轮写回的 `APP-current.raw` 是更早读出的，不含 `hung_task_panic`。
狗起来后必须重新跑 `add-hungtask-panic.py` 补回（已补，复核 hung_task=1 / ramoops=1）。
**每次 RCM 救砖后都要检查 extlinux 是否退回了旧版本。**

## 🔴🔴 重大改判：变体 B / C 的「炸机」是构建脚本缺陷造成的假象（2026-07-28）

**上面两节（变体 B 炸机、变体 C 也炸）的结论全部作废，不要再据此行动。**

### 铁证

| Image | `strings` 里的版本串 |
|---|---|
| 变体 B | `Linux version 5.10.216+` ❌ |
| 变体 C | `Linux version 5.10.216+` ❌ |
| kernel-E（full-build.sh 构建） | `5.10.216-tegra` ✅ |
| good（部署中） | `5.10.216-tegra` ✅ |

### 根因

我的快捷构建脚本（build-variant-B/C.sh）**漏了 `export LOCALVERSION=-tegra`**。
`athena_defconfig` 里只有 `# CONFIG_LOCALVERSION_AUTO is not set`，版本后缀全靠
`full-build.sh` 的环境变量 —— 它一直有这行**且带 KREL 断言**，快捷脚本绕过它就把坑绕回来了。

### 后果链（为什么看起来像挂死）

版本串 `5.10.216+` → `/lib/modules/5.10.216-tegra/` 对不上 → **全部 36 个模块加载失败**：
- 8821cu 没了 → **WiFi 失联**
- USB gadget 的 function 模块（f_rndis/f_acm/f_ncm/mass_storage）没了 → **`nv-l4t-usb-device-mode` 起不来 → USB 也失联**
→ 狗**活着但完全不可达**，从外面看与 probe 挂死**一模一样**。

### 各结论的重新定性

| 原结论 | 现状 |
|---|---|
| "变体 C 炸在 initrd 之后" | ❌ 假象。initrd gadget 出现过（initrd 用自带 busybox+builtin xudc，不依赖模块），switch_root 后模块全挂 → 失联。**内核本身多半是好的** |
| "0002 是变体 C 炸点的头号嫌疑" | ❌ 大概率冤枉 |
| "变体 B 炸在 probe 阶段（连 initrd 都没到）" | ⚠️ **存疑**。当时笔记本 xHCI 恰好猝死（`HC died` 时间窗吻合），initrd gadget 可能出现过但没被看见；模块失败假象同样适用。**不能再当定论** |
| "元凶不在 DT 那半" | ⚠️ 随变体 B 一起降级为存疑 |
| kernel-E 挂死（0726 A/B 撤除确认） | ✅ **仍然成立**——它是 full-build.sh 正确构建的 |

### 已修（三个构建脚本）

`build-variant-A/B/C.sh` 全部加上 `export LOCALVERSION=-tegra` +
**产物版本串断言**（`strings Image | grep "Linux version 5.10.216-tegra "` 不中就构建失败）——
错误必须在构建时响亮死掉，不能等部署后变成"幽灵失联"。

### 方法论教训

1. **绕过带断言的权威构建入口（full-build.sh）等于把它挡掉的坑全部请回来。**
   快捷脚本可以省时间，但必须继承全部断言。
2. **"失联"和"挂死"从外面不可区分**，下结论前必须先排除可达性层的失败
   （模块、网络、gadget）。本轮两轮 RCM 救砖救的其实是"活着的狗"。
3. 观察窗口被污染（笔记本 xHCI 猝死）时的结论要打上污染标记，不能与干净观察同权。

## 🏆 R32 相机电源契约打通（2026-07-28，E2 = C2 内核 + A DTB）

**AI 头顶相机线的分水岭时刻。** 0726 NOTES 定性的根因——「ve/ispa 域下零设备、永久断电、
R32 固件假定内核已上电」——**已被完整解决，且全程零炸机**。

### 实测证据链（一次受保护实验跑完）

| 步骤 | 结果 |
|---|---|
| E2 启动（C2 内核 + A DTB，开关默认关） | ✅ 正常启动，36 模块，0 failed |
| genpd 拓扑 | **ve 域下挂上 nvcsi/vi-thi/vi，ispa 域下挂上 isp**（此前永远是空的） |
| `echo 1 > r32_camera_power` + rtcpu unbind/rebind | ✅ 存活 |
| `r32-power: group_busy` → | **`ve=1 ispa=1`，genpd `ve on / ispa on`** —— 域真的上电了 |
| `r32-power: group_reset`（deassert 前，R32 时序） | ✅ |
| RCE 握手 | **`cmd=5` 成功**（域上电状态下） |
| 崩溃指纹 | **oops=0 / rce-noc=0 / smmu=0** |

### 关键定性

**同样的调用，boot-time probe 会挂死（kernel-E 实证），运行时执行完美工作。**
门控设计让我们根本不需要 boot-time 上电：相机要用时运行时武装即可。
kernel-E 的 boot-time 挂死从「必须攻克的墙」降级为「不需要走的路」。

### 现在内核侧拼图已全齐（当前运行中的 E2 内核）

legacy hsp ✅ / diag@5 disabled ✅ / nvmap handle-as-fd ✅ / R32 采集 ABI ✅（`r32-abi` 断言在 Image 里）
/ **R32 电源契约（运行时门控）✅**

**下一堵墙**：真采集（argus）——上次死在 `rce-noc Host read timeout at 0x15a303cc`，
那是在域断电时读 NVCSI 的必然结果。现在域能上电，该读应落在活硅片上。
若通过则进 NOTES §6 Stage 2（prod settings + MIPI 校准）。

### 实验脚本的已知小缺陷（下版修）

restore 顺序错了：先 `param=0` 再 unbind → suspend 路径的 `group_idle` 被门挡掉 →
busy 引用泄漏 → 实验结束后 ve/ispa 停在 on（无害，重启即清；正确顺序是先 unbind 再关 param）。

## 🤖 一次性实验机制（jp5-exp）已实战验证 —— 本轮全部实验的基座

`jp5-exp arm <Image> [DTB]` → reboot → initrd-exp 在 T+15.5s 把 DEFAULT 拨回 jp5（一次性消费）。
好路径三件套（Image/DTB/initrd）**永不被碰**。已连续三轮实战（good 验证轮 / C2 / E2）零故障。
挂死代价从「两次拔电 + 4 分钟 RCM」降到「一次拔电」；本轮三次实验实际人工干预 = **零**。

## 🏆🏆 采集控制面全通：`0x10 setup accepted` ×19，rce-noc 墙倒了（2026-07-28）

同一会话第二个历史性节点。域上电状态下打 V4L2 直采（`v4l2-ctl /dev/video0` ov7251 640x480 BG10）：

| 判据 | 结果 |
|---|---|
| **`r32-abi: VI channel setup accepted`**（NOTES §7.4 定义的胜负手） | **出现 ×19**（历史上从未出现过） |
| `rce-noc Host read timeout at 0x15a303cc`（0726 的死墙） | **0 次 —— 墙倒了** |
| oops / smmu fault / RTCPU gone bad | 0 / 0 / 0 |
| v4l2-ctl | 全程存活，错误恢复路径（`err_rec: successfully reset`）也正常工作 |

**定性**：R32 固件接受了 R35 内核（经 r32-capture-backport 翻译）发出的
`CAPTURE_CHANNEL_SETUP_REQ (0x10)` —— **采集控制面已通**。
0725 定案的「三堵原理性 ABI 墙」中的消息号墙、结构布局墙实测已被 backport 攻克。

**剩下的是数据面（零帧）**，症状与 NOTES §6 Stage 2 的预言精确吻合：
```
csi5_stream_open: VI channel not found for stream-0 vc-0
uncorr_err: request timed out after 2500 ms        ← 通道建好了，等不到帧
```
两个候选（按可能性排序）：
1. **Stage 2 缺失**：R32 内核在 RCE 上电后还做 nvcsi prod settings + `tegra_csi_mipi_calibrate()`，
   现在没人做 → PHY 不锁 → 传感器数据进不来。回移路径 NOTES §6 已写好
   （`nvcsi-t194.c` 的 ioremap + prod_list + apply thread；DT 给 `&nvcsi` 加回 `reg`）。
2. `csi5_stream_open: VI channel not found` —— stream↔channel 绑定的 R32/R35 缝，
   可能要看 `csi5_fops.c` 的 stream open 消息路径。

**实验基座已完全成熟**：jp5-exp 一次性机制 + 运行时门控 + kmsg 面包屑 + hung_task_panic 兜底，
本轮五次内核实验（good 验证 / C2 / E2 / 电源实验 / 采集实验）**人工干预总计 = 零**。

⚠️ 已知小尾巴：实验结束后 ve/ispa 停在 on（采集错误路径泄漏了 busy 引用），无害，重启即清。
⚠️ E2 组合（C2 内核 + A DTB）目前只存在于 exp 入口；good 路径未动。
   **要不要把它转正成默认内核，需机主拍板**（转正 = AI 相机能力常驻 + 这套内核已被今天五轮实验反复锤过）。

## 🔬 Stage-2 落地 + 零帧墙精确定位到 `nvcsi_error_config` 布局错位（2026-07-28）

### 变体 G（Stage-2 完整包）已构建并实测

内核 = 0002 + gated-0003 + **Stage-2 回移**（`nvcsi-t194.c` 的 prod apply/125ms 轮询线程/
`finalize_poweron`/`prepare_poweroff`，全部关在同一个 `r32_camera_power` 门后）；
DTB = A + **nvcsi `reg`**（设备更名 `15a00000.nvcsi`，devfs_name 钉死无影响）+ **mipical okay**。

实测（jp5-exp 部署，正常启动零回归）：
```
r32-stage2: prod applied (cphy=0)            ← prod settings 真写进去了(DPHY)
r32-stage2: mipi calibrate(on) rc=0          ← MIPI 校准成功(直接/线程两条路径都验证)
```
**但仍零帧**（同样的 2500ms request timeout）。

### 逐层排除后的精确定位

| 层 | 状态 |
|---|---|
| 传感器供电/时钟 | ✅ MCLK `extperiph2` enable=1 |
| 传感器在流出 | ✅ **采集中实测 `0x0100=0x01`**（16 位寄存器要用 `i2ctransfer`，`i2cget` 会 ERR） |
| MIPI pad 校准 | ✅ rc=0 |
| NVCSI prod | ✅ applied |
| 控制面 | ✅ 0x10 accepted ×19、RCE vi5_hwinit |
| **`nvcsi_error_config` 布局** | 🎯 **两代不同 —— 唯一错位点** |

`CSI_STREAM_SET_CONFIG (0x40)` 载荷的前三段（stream/brick/cil）两代逐字段一致，
**最后一段 `nvcsi_error_config` 错位**：R32 = 9×u32+pad(40B)，R35 = 11×u32+pad+csimux(≥52B)，
且从第 2 个字段起全体错位（R32 的 `host1x_intr_type` 读到 R35 的 `mask_hsm`……）。
R32 固件"接受"后按错位布局解析错误掩码/`status2vi_notify_mask` ——
**正是 0725 定性的「静默乱掉而非报错」模式**（当时点名 ISP 侧，这是 CSI 侧同款）。

### 变体 H（下一步，已精确锁定）
1. `csi5_fops.c` 在 R32 门控下按 **R32 布局**填 `error_config`（40B，字段按 R32 语义）
2. 给 0x36/0x38/0x40 的**应答码加 `dev_info`**（内核没编 `CONFIG_DYNAMIC_DEBUG`，
   dev_dbg 全部不可见 —— 这也是为什么至今看不到 RCE 的 resp.result）
3. 顺手核对 `PHY_STREAM_OPEN/CLOSE` 载荷（结构简单，大概率一致）

## ✅ 传感器健康哨兵上线（`cyberdog-sensor-doctor.timer`，每 5 分钟）

对付「使能运行时退化且重发 ENABLE 救不回来」（0727 实测 11 小时后 ObstacleDetection 归零）。
连续 2 次 0Hz 判死才重启栈；**栈非 active 时跳过**（绝不和相机实验打架，守卫已当场验证）；
SoC≥85°C 拒绝动手；30 分钟冷却期防永动机；判决进 journal + kmsg 面包屑。

## 🔬 变体 H：csi5 stream 全面 R32 化 —— 三重收获 + 墙再度前移（2026-07-28）

### 变体 H 内容（构建/部署/实验全通，仍零帧）

在 G 之上把 csi5 的三个 stream 函数整体改为 **R32 忠实实现**（同一个运行时门控）：
1. **传输方式**：R35 走 per-VI-channel 请求-应答并等回包 → R32 是
   `tegra_capture_ivc_control_submit()` **发射后不管**（`TEMP_CHANNEL_ID=65`，固件不回包）。
   这顺带解释并消灭了 `csi5_stream_close: Error in closing`（在等一个永远不会来的回包）
   和全部 `NULL VI channel` 噪音。
2. **`nvcsi_error_config` 全零**（R32 从不填它 —— 布局错位问题就此绕开）。
3. **CIL 数值 R32 语义**：`cil_clock_rate=204000`（R35 已弃用的字段）、DPHY `t_clk_settle=33`、
   `lp_bypass_mode=!discontinuous_clk`、`mipi_clock_rate=pixel_clk/1000`。

实测（消息全部发出且干净）：
```
r32-csi5: STREAM_SET_CONFIG stream=0 port=0 lanes=1 cphy=0 settle=0 lp_bypass=0 mipi=80000kHz rc=264
r32-csi5: PHY_STREAM_OPEN  stream=0 port=0 rc=264      (rc=264=整包提交成功)
```

### RCE 固件视角取证（rtcpu trace + ftrace）

- `tegra_rtcpu_trace/stats`：**Exceptions=0**，Events 252→439（固件活着且在处理流量）
- ftrace `events/tegra_rtcpu` 采集窗口内：**只有 `vi5_hwinit` 一条字符串，
  零 VINOTIFY / 零错误事件** → **SOF 从未到达 VI**

### 定性：墙在 CSIMUX 匹配层

传感器在发（实测）→ PHY 已校准 → NVCSI 已按 R32 配置 → **但 VI 的 CSIMUX 匹配过滤把像素全丢了**
（匹配不命中连事件都不会产生 —— 与观察精确一致）。

**下一个精确工作项**：`vi_channel_config`（ch_cfg）**内部**的 match/csimux 字段逐位审计。
backport 的 static_assert 只锁了外层（`capture_descriptor==704`、`config==216`），
**ch_cfg 内部布局两代分叉**（R32: `fm_cfg`/`fm_result`；R35: `pfsd_cfg`），
且填值的是 R35 的 vi5_fops 语义。审计对象：
- R32 vs R35 `struct vi_channel_config` 全字段（尤其 match/stream/vc/dt 过滤）
- `build/r32-capture-backport/0002` 里 setup 消息的填值代码

### 判据保持不变
`/tmp/frames.raw > 0` 字节（`r32-frames-experiment.sh`）。

## 🔬 变体 I：内联 IOVA 修复已生效，但仍零帧 —— 墙在描述符「内容」而非布局（2026-07-28 深夜）

### 变体 I 做了什么

对比两代 `vi5_setup_surface` 发现的真实差异：
- **R32**：`desc->ch_cfg.atomp.surface[0].offset/offset_hi = IOVA`（描述符**内联**）
- **R35**：`desc_memoryinfo->surface[0].base_address = IOVA`（**独立表**），
  而 `atomp.surface[0].offset` 恒为 **0**

R32 固件按自己的范式读内联地址 → 读到 0 → 帧 DMA 向空地址。
这正是 0725「每帧内存模型换范式（reloc vs buffer-table）」在 v4l2 路径的具体形态。

stage4 在门控下把同一个 offset 补写进 `atomp.surface[0/EMBEDDED]`，memoryinfo 照旧写（R32 固件无视它）。
**实测标记确认生效**：
```
tegra-capture-vi: r32-vi5: inline surface IOVA active (0x0000007ffe000000)
```
IOVA 数值合理（40 位 SMMU 地址空间内）。**但仍然 `request timed out after 2500 ms`。**

### 布局层已完全排除（逐字节核对）

用 backport 实际编进内核的 `camrtc-capture-r32.h` 重算（`/tmp/sz2.c` 方法）：
```
descriptor=704  ch_cfg@64  status@624   ← 与 backport 的 static_assert 逐项吻合
ch_cfg=160  match@4  frame@24  pixfmt@52  atomp@104
atomp.surface[0].offset 绝对偏移 = 168
```
且 `ch_cfg` 两代**逐字节同构**（size/match/frame/pixfmt/atomp 偏移全部相同）。
→ **match 段和内联 IOVA 的位置都是对的，布局不是问题。**

⚠️ 中途我曾据未打 backport 的原始头算出「status 错位 352 字节」并以为找到真凶 ——
**那是错的**：backport 用独立的 `camrtc-capture-r32.h` 让整个内核统一看到 R32 布局
（`camrtc-capture.h` 里加了 `#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)` 切换，无 ODR 风险）。
**算布局必须用实际参与编译的那份头。**

### 现在的精确边界

| 层 | 状态 |
|---|---|
| 电源域 / prod / MIPI 校准 / 传感器流出 | ✅ 全部实测通过 |
| 控制面（0x10 setup accepted、csi5 三消息 R32 语义） | ✅ |
| 描述符**布局**（704/ch_cfg@64/status@624/atomp@104） | ✅ 逐字节核对通过 |
| 描述符**内容**（内联 IOVA 已补，数值合理） | ✅ 已写入并验证 |
| **帧完成** | ❌ 仍 2500ms 超时，RCE 零异常零 VINOTIFY |

**下一轮的三个候选**（按优先级）：
1. **flags 位域**：R35 删了 `fmlite_enable`(bit12)，`compand_enable` 从 bit13 挪到 bit12。
   `capture_template` 是 R35 语义填的 —— 需确认 R32 头下这些位的实际含义与填值一致。
2. **`capture_flags` / `frame_start_timeout`**：R32 需要 `CAPTURE_FLAG_STATUS_REPORT_ENABLE`
   才会写回状态；模板里若没置位，固件可能"做了但不报"。
3. **syncpoint / GoS**：R35 `nvhost_syncpt_get_gos()` 不存在（NOTES 点名的头号未知数），
   `progress_sp` 若无效，固件无法通知完成 —— 与「零 VINOTIFY + 超时」高度吻合。

第 3 条与 0725 NOTES 的预言最吻合，建议优先。

## 🔬 syncpoint / GoS 线索排查完毕：**GoS 不是真凶**（2026-07-28 深夜）

0725 NOTES 把 GoS 空表列为「头号未知数」，本轮把它彻底查清了。

### R35 侧确实是空壳（NOTES 的观察正确）
```c
/* R35 capture-support.c */
void capture_get_gos_table(...) { *gos_count = 0; *gos_table = NULL; }   // 硬编码空
int capture_get_syncpt_gos_backing(...) { *gos_index = GOS_INDEX_INVALID; ... }
```
`nvhost_syncpt_get_gos()` 这个符号在 R35 里**根本不存在**（NVIDIA 整条删除）。

### 但 R32 自己也允许 GoS 无效 —— 所以这不构成阻塞
```c
/* R32 t194_capture_get_syncpt_gos_backing() */
err = nvhost_syncpt_get_gos(pdev, id, &index, &offset);
if (err < 0)
        dev_dbg(...);          /* 只打调试日志 */
*gos_index = index;            /* 保持 GOS_INDEX_INVALID */
return 0;                      /* ← 照样返回成功 */
```
**R32 原版在 GoS 拿不到时同样把 `gos_index` 留成 `GOS_INDEX_INVALID` 并继续。**
GoS 是「syncpoint 直写」的加速路径，不是完成通知的必需品。

### 真正必需的 `syncpt_addr`（shim 地址）两代同构
```c
R35: return syncpt_unit_interface->start + syncpt_unit_interface->syncpt_page_size * id;
R32: return syncpt_unit_interface->start + SYNCPT_SIZE * id;
```
语义与数值来源一致 → **固件写完成通知的地址是对的**。

### 结论：三个候选里排掉了最可疑的一个

| 候选 | 结论 |
|---|---|
| ~~syncpoint / GoS~~ | ❌ **已排除**（R32 自己也容忍 GoS 无效；shim 地址同构） |
| `capture_flags` 的 `CAPTURE_FLAG_STATUS_REPORT_ENABLE` | ⏳ 未查 —— 现在升为**头号**（不置位则固件「做了但不报」，与零 VINOTIFY 完全吻合） |
| flags 位域（R35 删 `fmlite_enable`，`compand` 挪位） | ⏳ 未查 |

**下一轮起手式**：核对 `capture_template` 里 `capture_flags` 的实际值，
以及 R32 固件对 `CAPTURE_FLAG_STATUS_REPORT_ENABLE` / `CAPTURE_FLAG_ERROR_REPORT_ENABLE` 的依赖。
这两个标志在 R32 头里就定义在 `capture_descriptor.capture_flags` 上，位置已知（+4）。

## 🔬 `capture_flags` 也排除 —— 三候选清空，范围收敛到 setup 消息本身（2026-07-28 收尾）

`capture_template` 两代**逐字节相同**（连注释都一样）：
```c
.capture_flags = 0 | CAPTURE_FLAG_STATUS_REPORT_ENABLE | CAPTURE_FLAG_ERROR_REPORT_ENABLE,
.ch_cfg = { .pixfmt_enable = 0, .match = { .stream=0, .stream_mask=0x3f,
                                           .vc=(1u<<0), .vc_mask=0xffff } },
```
→ 状态上报**已经**是开的，「做了但不报」的假说不成立。

### 本轮三候选全部排除

| 候选 | 结论 |
|---|---|
| syncpoint / GoS | ❌ R32 自己也容忍 GoS 无效；shim 地址两代同构 |
| `capture_flags` | ❌ 模板两代逐字节相同，状态/错误上报都已开启 |
| flags 位域 | ⚠️ 差异存在（R35 删 `fmlite_enable`、`compand` 从 bit13→bit12），但当前路径两位都是 0，**无实际影响** |

### 已彻底排除的层（累计，全部有实测或逐字节证据）

电源域 ✅ / prod ✅ / MIPI 校准 ✅ / 传感器流出 ✅ / 控制面 0x10 ✅ /
csi5 三消息 R32 语义 ✅ / 描述符布局（704・ch_cfg@64・status@624・atomp@104）✅ /
内联 IOVA ✅ / GoS ✅ / capture_flags ✅

### 下一轮的精确起手式：`CAPTURE_CHANNEL_SETUP_REQ` 的**载荷内容**

布局已由 `static_assert(capture_channel_config==216)` 锁住，但**填值**没人核对过。
R35 的 `vi_capture_setup()` 里有一段明显是 R35-only 的：
```c
config->requests_memoryinfo = capture->requests_memoryinfo_iova;   /* R32 没有这个字段语义 */
config->request_memoryinfo_size = ...;
```
在 R32 的 216 字节布局里，这两个 u64/u32 写进去的是**别的字段的位置** ——
很可能覆盖了 R32 期望的 `requests`（描述符环 IOVA）或 `queue_depth`/`request_size`。

**下一轮第一件事**：把 R32 `capture_channel_config` 与 R35 的填值代码逐字段对照，
特别是 `requests` / `request_size` / `queue_depth` / `channel_flags` 四项，
并在 `vi_capture_setup` 里加 `dev_info` 打印实际提交值。
判据不变：`/tmp/frames.raw > 0`。

## 🔑 关键发现：我一直在测**错误的路径**（2026-07-28 最终收敛）

### backport 的填值处理是完备的（我上一轮的推断作废）

`0002` 补丁把**每一个** R35-only 字段都用 `#if !IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)` 排掉了：
`requests_memoryinfo` / `request_memoryinfo_size` / `vi2_channel_mask` / `vi_unit_id` /
`csi_stream.*` / `stop_on_error_notify_bits` —— 一个不漏。
→ **CHANNEL_SETUP 载荷填值没有问题**，上一节的怀疑不成立。

### 真正的原因：reloc pass 只挂在 ioctl 路径上

```c
/* 0002 补丁：VI_CAPTURE_REQUEST ioctl 分支 */
#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)
        err = r32_reloc_vi_capture_request_buffers_locked(chan, &req, request_unpins);
#else
        err = pin_vi_capture_request_buffers_locked(chan, &req, request_unpins);
#endif
```

这条路径是 **`VI_CAPTURE_REQUEST` ioctl** —— 也就是 chroot 里 **argus / nvargus-daemon** 走的路。

而我这一整天用的 `v4l2-ctl` 走的是**内核内部**路径：
```
vi5_capture_enqueue() → vi5_setup_surface() → vi_capture_request()
```
**完全不经过那个 ioctl，因此 reloc pass 从未执行过。**

R32 固件要求内核在提交前把描述符里的相对偏移就地重定位成真实 IOVA
（这正是 0725 记录的 "R32=reloc（内核就地打补丁 IOVA）" 范式）。
v4l2 路径下这一步没人做 → 固件拿到未重定位的描述符 → 静默等待 → 2500ms 超时。
**与实测的「零 VINOTIFY、零异常、纯超时」完全自洽。**

### 这也解释了变体 I 为何"修对了却没用"

stage4 补的 `atomp.surface[0].offset` 是**必要但不充分**的：
它只补了一个字段，而 R32 范式要求的是**整个描述符的 reloc 遍历**（backport 已实现，只是没挂到 v4l2 路径）。

### 下一轮的两条路（都是低风险，工具链现成）

**路线 A（推荐，工作量小）**：用**真正的目标用户态**验证 ——
chroot 里的 argus/nvargus 本来就走 ioctl 路径，reloc pass 会自动生效。
这也是这个工程**真正要支持的场景**（出厂 ROS2 相机节点用的就是 argus）。
做法：`systemctl start nvargus-daemon`（NOTES §7.3 的步骤 6），跑一次采集。
⚠️ 红线：别对 active 的 `camera_server` 调 configure。

**路线 B**：把 reloc pass 也挂到 `vi_capture_request()` 内核内部路径，让 v4l2 直采也能用。
工作量中等，价值是多一条不依赖 chroot 的验证途径。

**先做 A** —— 它可能直接出图，而且是真实目标场景。

## ⏳ 路线 A 首次尝试：卡在 GStreamer/EGL，未触及内核层（2026-07-28 收尾）

用 `nvgstcapture-1.0` 走 argus 路径的第一次尝试**没能到达内核**：
```
nvbuf_utils: Could not get EGL display connection
GStreamer-CRITICAL: gst_element_link_pads_full: assertion 'GST_IS_ELEMENT (dest)' failed
ERROR <create_vid_enc_bin:3220> Elements could not link encoder & parser
```
**判据证实它没到内核**：采集窗口内 `timed out` **0 次**、`r32-abi` 日志 **0 条**
（对比 v4l2 路径每次都刷 16 次超时）。
→ 这是**用户态 GStreamer 的编码器/EGL 链问题**，与本工程的内核改动无关。

⚠️ 另：`nvargus-daemon` 在 chroot 里被 Terminated，启动方式需要再调
（`nvargus-daemon --help` 会前台阻塞，别在自动化脚本里直接调它 —— 本轮因此吃了一次 ssh 超时）。

### 下一轮路线 A 的正确做法（三选一，按可靠性排序）

1. **出厂 ROS2 相机节点**：`/opt/ros2/cyberdog/lib/athena_camera/maincamera` ——
   它就是这个工程要支持的最终用户态，且不依赖 GStreamer 编码器链。
   ⚠️ 红线仍在：**不对 active 的 `camera_server` 调 configure**（栈停着时它不 active，可直接跑二进制）
2. **`nvgstcapture` 纯图像模式**：绕开 `create_vid_enc_bin`（`--mode=1` 只出 JPEG，不建视频编码器）
3. **jetson_multimedia_api 的 argus 示例**：`/usr/src/jetson_multimedia_api/argus/`，
   最小依赖，但可能需要现场编译

### 路线 B（备选，工作量中等但更彻底）

把 `r32_reloc_vi_capture_request_buffers_locked()` 也挂到内核内部路径
`vi_capture_request()`，让 `v4l2-ctl` 直采也走 reloc。
好处：验证链完全不依赖 chroot 用户态，排障面积小得多。
做法：在 `vi_capture_request()` 里门控调用同一个 reloc 函数
（注意它现在从 `req->reloc_relatives` 读用户态指针，内核内部路径需要一个不走 `copy_from_user` 的变体）。

## ⏳ 路线 A-1（maincamera）：用户态起来了，但没触发采集（2026-07-28 最终）

`maincamera` **确实链接 `libnvargus.so`**（`ldd` 证实），是走 ioctl 路径的正确用户态。

**进展**：
- `nvargus-daemon` 起来了（关键：必须 `setsid ... </dev/null >log 2>&1 &` **完全脱离**，
  否则会拖住 ssh；且**永远别在脚本里调 `nvargus-daemon --help`** —— 它前台阻塞）
- `maincamera` 起来了：`CameraServerNode: Creating node camera_server` → `CameraContext: initialize`

**但内核层仍未被触及**：`timed out` **0 次**、`r32-abi` **0 次**。

**原因**：`maincamera` 是 **ROS2 lifecycle 节点** —— 只做了 initialize，
真正开流要靠 ROS service 触发（出厂设计），光起进程不会走到 `VI_CAPTURE_REQUEST`。
另见 `(Argus) Error OverFlow: Server already operational` —— argus RPC server 有实例冲突，
以及老朋友 `nvbuf_utils: Could not get EGL display connection`。

### 🎯 下一轮建议改走**路线 B**（把 reloc 挂到内核内部路径）

路线 A 的三次尝试都卡在**用户态的复杂度**（GStreamer 编码器链 / EGL / ROS lifecycle / argus RPC 冲突），
每一层都与本工程的内核改动无关，纯属排障噪音。

**路线 B 的优势**：
- `v4l2-ctl` 一条命令即可验证，**完全不依赖 chroot 用户态**
- 排障面积从「四层用户态」缩到「一个内核函数」
- 出图后再回头修用户态，因果链清晰

**做法**：在 `vi_capture_request()`（内核内部路径）里门控调用 reloc。
⚠️ 现有 `r32_reloc_vi_capture_request_buffers_locked()` 从 `req->reloc_relatives`
读**用户态指针**（`copy_from_user`），内核内部路径需要一个不走 `copy_from_user` 的变体 ——
或者更简单：v4l2 路径下 `num_relocs=0`，只需要把 `atomp` 里已经写好的 IOVA
按 R32 范式做一次 `dma_sync` + 就地写回即可（stage4 已经写了地址，缺的是 reloc 语义的其余部分）。

**先读**：`0002` 补丁里 `r32_reloc_vi_capture_request_buffers_locked()` 全文
（`build/r32-capture-backport/0002-*.patch` 第 163-315 行），看它除了 reloc 还做了什么。

## 🔬 变体 J（路线 B / dma_sync）：假设不成立，但排除法又收紧一格（2026-07-28 终章）

**实测**：变体 J 构建部署正常启动，但 **`r32-sync` 标记根本没打印** ——
我的守卫条件 `capture->requests.iova != 0` 正确地挡住了执行。

**查证结果**：两条路径的描述符环内存来源根本不同
| 路径 | 描述符环 | 是否需要 sync |
|---|---|---|
| ioctl（argus） | `capture->requests` = 从用户态 nvmap handle **pin** 出来的 | 需要 → reloc pass 末尾确实做了 |
| v4l2（内核内部） | `chan->request[] = dma_alloc_coherent(rtcpu_dev, ...)` | **不需要** —— 一致性内存 |

→ **dma_sync 假设不成立**，v4l2 路径的描述符本来就对 RCE 可见。
守卫条件把它挡住是对的（否则会对一段 `iova=0` 的内存做 sync，可能更糟）。

### 这一轮仍有净收获

1. **确认 v4l2 路径的描述符环是 coherent 的** —— 可见性问题彻底排除
2. **`config->requests` 由 `setup.iova` 正确传给固件**（`r32-abi ... request_size=704` 证明 setup 被接受）
3. 排除法名单再加一项，剩余面积继续缩小

### 累计已排除（全部有实测或逐字节证据）

电源域 ✅ / prod ✅ / MIPI 校准 ✅ / 传感器实测在流出 ✅ / 控制面 0x10 ✅ /
csi5 三消息 R32 语义 ✅ / 描述符布局 ✅ / 内联 IOVA ✅ / GoS ✅ / capture_flags ✅ /
CHANNEL_SETUP 填值 ✅ / **描述符可见性(dma_sync)** ✅

### 下一轮最该做的一件事：**让 argus 真正跑起来**

三次路线 A 尝试都没到内核，但**根本原因各不相同且都可修**：
- `nvgstcapture` → GStreamer 编码器链（用 `--mode=1` 纯图像绕开）
- `maincamera` → ROS2 lifecycle 节点，需 **ROS service 触发**才开流
  （出厂栈起来时它本来就会被触发 —— 值得试：**门控武装后直接起整个栈**，
   让出厂 camera_server 走它自己的正常流程）
- argus RPC "Server already operational" → 需先确保没有残留 daemon

**最省事的做法**：`echo 1 > r32_camera_power` + rtcpu rebind **之后**，
直接 `systemctl start jp5-cyberdog-stack`，让出厂相机节点按它自己的设计跑。
这既是最真实的验证，也绕开了所有手工触发的复杂度。
⚠️ 红线仍在：不对 active 的 `camera_server` 调 configure —— 让它自己走。

## 🎯 出厂 argus 全链路已打通到用户态最后一层：`RESULT_INVALID_STATE`（2026-07-28 终点）

**这是本工程真正的目标场景**，全部按出厂设计走，红线全程遵守：
```
门控武装 + rtcpu rebind (ve=1 ispa=1)  →  systemctl start jp5-cyberdog-stack
  →  出厂 camera_server 自行到达 active [3]        ← 未碰它的 lifecycle
  →  ros2 service call /mi1045904/camera_service {command: 1}   ← TAKE_PICTURE
```
**结果**：`CameraService_Response(result=5)` = **`RESULT_INVALID_STATE`**，
内核层零活动（`timed out` 0 / `r32-abi` 0 / `r32-vi5` 0）。

→ 请求在**用户态就被拒绝**，根本没走到 argus → ioctl → reloc。

### 关键定位：`camera_server` 自认为相机不可用

它是 `active [3]`（lifecycle 层正常），但业务层判定 INVALID_STATE。
最可能：**启动时打开相机失败并记住了失败状态**，之后拒绝一切拍照请求。

⚠️ **诊断被挡住**：栈日志里 `camera` 相关记录 **0 条** ——
又是 `chroot … su - mi -c` 无 tty 吞 stdout 的老问题（0727 已记档，影响面比想象的大）。
**下一轮第一件事就是把这个观测性缺口补上**，否则用户态问题全是瞎子摸象。

### 下一轮的三步（顺序不可换）

1. **补观测性**：改 `jp5-stack-inner.sh`，把内层输出抓进变量再逐行 echo
   （与 `cyberdog-sensors-enable.sh` 同一修法，已验证有效），
   或直接让出厂节点日志落到 `/mnt/jp4/tmp/stack.log`。
2. **读 camera_server 的真实报错**，确定 INVALID_STATE 的来源
   （最可能是 argus `CameraProvider` 创建失败 —— 0725 见过 `Error IoctlFailed`）。
3. 按报错定位，再决定是内核侧还是用户态侧的修复。

### 本轮净收获

- **确认了完整的目标调用链可达**：门控 → 出厂栈 → camera_server active → 业务 service
- **确认拒绝发生在用户态**（内核零活动是硬证据），内核侧不用再盲改
- 找到了 `/mi1045904/camera_service`（`interaction_msgs/srv/CameraService`，
  `TAKE_PICTURE=1`）这个正确的触发入口
- 红线遵守记录：全程未对 active 的 `camera_server` 调 configure

---

## 🏆 三堵墙连倒：argus 全栈起来了，采集链推进到「等 MIPI 帧」（2026-07-28 决定性突破）

**上一节留的三步（补观测性 → 读真因 → 定点修复）全部走完，且结论完全推翻了之前的判断。**

### 第一步：观测性缺口补上了（而且比想象的更严重）

出厂节点的诊断信息全打 stdout，但 `chroot … su - mi -c` 无 tty 把它整个吞掉，
journal 里只有 **2 行**。更坑的是 **rcl 文件日志（`~/.ros/log/*.log`）也指望不上**：
spdlog 带缓冲，低产量节点（比如 `maincamera`）一直停在 **0 字节**，
而 decisionmaker 因为写到 5MB 撑满缓冲反而看得见 —— 极易误判成「相机什么都没打」。

修法：`jp5-stack-inner.sh` 里 `exec >/tmp/jp5-stack.log 2>&1`（用 exec 重定向而非
`| tee`，保持单进程语义，systemd 主 PID 跟踪和 `KillMode=mixed` 不受影响），保留一代 `.prev`。

### 第二步：`RESULT_INVALID_STATE` 是**误判**，不是故障

读 `cyberdog_camera` 源码（本仓库自带）：

```cpp
int ArgusCameraContext::takePicture(...) {
  if (!m_isStreaming) { CAM_ERR("Device is not stream on."); return CAM_INVALID_STATE; }
```

`m_isStreaming` 只在 `startCameraStream()` 里 `startRepeat` 成功后置 true；
而 `on_activate → startCamera() → initCameraContext()` 是**空函数 `return true`**。
⇒ **刚 activate 的 camera_server 收到 TAKE_PICTURE 必然返回 5，在出厂 JP4 上也一样。**
正确契约是先 `START_LIVE_STREAM`(命令7) 再 `TAKE_PICTURE`(命令1)。

> ⚠️ 源码坑：`startCameraStream()` 在 `createSession` 失败时 `return false` → `0` → 而
> `CAM_SUCCESS == 0`。**START_LIVE_STREAM 返回 0 不等于成功**，必须靠内核活动佐证。

### 第三步：真正的墙是 **R32 用户态 vs R35 内核的 GPU ABI**，跟采集 ABI 无关

用对命令后，`camera_server` 的真实死因终于现形（进程直接 abort）：

```
SCF: Error InsufficientMemory: Unable to initialize EGL (GLService.cpp:144)
  → createCameraProvider 失败 → assert(m_initialized) → exit -6
```

#### 墙 1：EGL（`NVGPU_GPU_IOCTL_ALLOC_AS`）

ctypes 探针 + strace **差分**（R32 用户态 vs R35 用户态，同一颗内核）：
整条 EGL 初始化链上 11 个 `'G'` 类 nvgpu ioctl **逐条完全一致**，只差最后一个：

| | R32 用户态 | R35 用户态 |
|---|---|---|
| `'G'` nr=8 | size **16** → **ENOTTY** | size **64** → 0 ✅ |

`struct nvgpu_alloc_as_args` 从 16 字节涨到 64 字节；ioctl 号把 size 编进去，
内核 `switch(cmd)` 直接落 default。**整个 GPU/EGL/argus 栈就卡在这一个 ioctl 上。**

不能零填充：R35 `common/mm/as.c:95` 对 `va_range_start/end` 为零一律 `-EINVAL`。
补什么值不靠猜 —— 在宿主上 `LD_PRELOAD` 把 R35 自己传的 64 字节原样 dump 出来：
`va_range_start=0x4000000`、`va_range_end=0x2000000000`、`flags=0x2(UNIFIED_VA)`、`split=0`。

#### 墙 2：CUDA（`NVGPU_AS_IOCTL_ALLOC_SPACE`）

同样手法：`'A'` nr=6，`pages` 从 `u32` 拓宽到 `u64`，后续字段整体挪位（24 → 32 字节）。

#### 墙 3：芯片 ID（`libnvscf` 有**自己**的读取器）

`strings libnvscf.so` 挖出并排的两条路径：

```
/sys/module/tegra_fuse/parameters/tegra_chip_id     ← R35 无此模块
/tmp/tegra_chip_id                                  ← NVIDIA 官方覆盖钩子
```

**libnvscf 不走 libnvrm，因此没有 `/sys/devices/soc0` 回落**（libnvrm 自己是能回落的，
所以它读 chip_id 一直是成功的 —— 这点很容易看漏）。读不到就
`Unknown HW element!` → `Tegra chip ID not supported`(PowerServiceHwIsp.cpp:74)。

> 附带纠正：`tegra_platform` 这个参数 R32 收的是**名字**（`silicon`），
> 把 R35 的 `soc0/platform`（数字 `0`）直接抄过去会得到 `Unknown platform '0'`。

### 落地：一个 LD_PRELOAD 垫片，**零内核改动**

`dog-scripts/src/nvgpu-r32-shim.c` → `/opt/nvgpu-r32-shim.so`（必须在 chroot 内用
gcc 7.5 编，宿主 gcc 9.4 编的会带 GLIBC_2.29+ 需求而加载失败；构建脚本
`nvgpu-r32-shim-build.sh` 带装载自检 + 功能自检）：

1. `'G'` nr=8 `ALLOC_AS` 16 → 64 字节
2. `'A'` nr=6 `ALLOC_SPACE` 24 → 32 字节
3. `tegra_fuse` sysfs 路径改道到 `/opt/nvgpu-r32-compat/`（**文件不存在就放行走原路**，
   避免把本来能正确回落的 chip_id/chip_rev 塞错值）
4. 诊断：任何 `'G'/'A'/'H'` ioctl 被 ENOTTY 拒都记一笔 —— 实测**已无第四条**

开机自动生效：`jp5-chroot-prep.sh` 按 `soc0` 生成 compat 文件（非致命兜底，
遵守"三服务共用 ExecStartPre 不能硬失败"的既有约束）；`jp5-stack-inner.sh` 挂 `LD_PRELOAD`
并**取消 `DISPLAY=:0`**（无 X 服务器时 GLVND 会走 X11 平台，`eglGetDisplay` 直接返回
`EGL_NO_DISPLAY`，日志里那句 `No protocol specified` 就是它）。

### 战果：从「进程崩溃」推进到「等 MIPI 帧」

```
tegra194-isp5: r32-abi: ISP channel setup accepted: hw_channel_id=0 ...
tegra194-vi5 : r32-abi: VI  channel setup accepted: hw_channel_id=1 queue_depth=9 request_size=704
[RCE] vi5_hwinit: firmware CL2018101701 protocol version 2.2      ← RCE 固件自己报到
tegra194-vi5 : r32-sync: descriptor sync active (iova=0xbfe78000 size=704)
```

用户态则走到了：

```
SCF: Timeout waiting on frame end sensor guid 0, capture sequence ID = 1, channel = 1/1
     (NvCaptureViCsiHw.cpp:897)
```

**ISP 通道 ✅ VI 通道 ✅ RCE 固件握手 ✅ 描述符下发 ✅ ——差最后一步：传感器不出帧。**
`camera_server` 也不再 abort 循环，进程稳定存活。

### 改判与教训

- 🔴 **「AI 相机的墙是采集 ABI」这个判断是错的**。真正卡死全栈的是 **GPU/EGL 的
  `ALLOC_AS`**，一个 ioctl。之前十几轮针对采集 ABI 的排除工作（GoS/capture_flags/
  描述符布局/内联 IOVA/dma_sync…）**结论仍然有效**，但它们从来不是当时的瓶颈 ——
  因为 argus 根本没起来过，那些代码路径压根没被执行到。
- 🔴 **观测性欠债的代价被严重低估**。真因（EGL 初始化失败）在第一次跑对命令时就
  打在 stdout 上了，只是没人收得到。补一行 `exec >` 重定向，一小时内连倒三堵墙。
- 💡 **strace 差分是这类 ABI 问题的利器**：同一颗内核上跑 R32 和 R35 两套用户态，
  逐条比对 ioctl 序列，差异一眼可见，不需要任何猜测。
- 💡 **R35 自己的用户态就是最好的参考实现**：不确定该往新结构体里填什么，
  就 `LD_PRELOAD` 把它传的字节 dump 出来。

### 下一轮：唯一剩下的问题是**传感器不出帧**

现在的失败点干净且单一 —— 上下游全通，`waitCsiFrameEnd` 超时。可查方向：
1. `vi capture get status failed`（内核）与 SCF 超时的对应关系
2. ov13b10 是否真的被下了 stream-on（之前 v4l2 路径实测「传感器在流出」，
   但那是另一条路径，需在 argus 路径下重验）
3. NVCSI 通道/lane 配置与 argus 请求的分辨率是否匹配
4. 此前所有采集 ABI 的排除工作**现在才真正到了能被验证的时候**

---

## 🔬 传感器不出帧：定位到「argus 从不让 v4l2 通道进入流状态」（2026-07-28 续）

三堵 GPU/EGL 墙倒掉后接着攻唯一剩余问题。本轮**没有修好**，但把问题从「不知道哪一层」
收敛成了一个具体、可复现、有硬证据的单点，并顺手修好了 ISP 配置加载。

### 逐层排除（每层都有实测数据，不是推断）

**① VI/CSI 接收端一片死寂** —— 用 RCE 固件视角的 ftrace（`tegra_rtcpu` 事件组）：

| 事件 | 计数 |
|---|---|
| `rtcpu_vinotify_event`（帧起止） | **0** |
| `rtcpu_nvcsi_intr`（MIPI 链路错误） | **0** |
| `rtcpu_vinotify_error`（VI 错误） | **0** |

连一个错误中断都没有 ⇒ 不是「收到坏帧」，是**线上根本没有数据**。RCE 固件本身健康
（`vi5_hwinit: firmware CL2018101701 protocol version 2.2`）。

**② 传感器根本没上电** —— 采集进行中三路交叉取证，连采 24 秒：

| 探测 | 结果 |
|---|---|
| 驱动 `debugfs .../camera-ov13b10_e/streaming` | 全程 **0** |
| `i2ctransfer` 读 reg 0x0100 | 全程**无应答**（芯片断电） |
| `ov13b10` ftrace 事件 | **0** |

**③ 但 PCL 那一层原来全军覆没** —— `NvPclHwGetModuleList: No module data found` ×3，
伴随 `Could not map module to ISP config string`。

### 🏆 顺手修好的：ISP 配置加载（badge 命名）

对比出厂 DTB（`dtc -I dtb` 解 `/mnt/jp4/boot/tegra194-mi-k91.dtb`）：

| | 出厂 JP4 | 我们移植的 |
|---|---|---|
| badge | `ov13b10_bottom_RBP194` | `ov13b10_2_P2151X` |
| position | `"bottom"` | `"2"` |
| **模块序** | **module0 = ov13b10（主相机）** | module2 = ov13b10 |

`RBP194` 是小米出厂板标识，`P2151X` 是 **NVIDIA 参考板** —— 移植时 `tegra-camera-platform`
节点用成了参考板的 `tegra194-camera-p2151.dtsi`。

关键证据：`strings libnvodm_imager.so` 里位置名是一个**固定集合**
`bottom / center / centerleft / centerright / front / rear`，`"0"/"1"/"2"` 不在其中。
（注意：它不读 `position` 属性本身，而是在 **badge 字符串里做子串匹配**。）

用 shim 的 DT 覆盖机制把 badge 改成出厂值后：

```
---- imager: Found override file [/var/nvidia/nvcam/settings/ov13b10_bottom_RBP194.isp]. ----
---- imager: Found override file [/var/nvidia/nvcam/settings/ov7251_top_RBP194.isp]. ----
---- imager: Found override file [/var/nvidia/nvcam/settings/ov7251_l_center_RBP194.isp]. ----
```

**三个 ISP 配置全部加载成功**（此前是三次 `No override file found`），
且 SCF 现在能成功获取 **index 0/1/2 三个 MIPI 相机源**（失败的 3/4/6/8 是 USB 外接设备）。

### 🎯 收敛到的单点：argus 只枚举、从不开流

对 `/dev/video*` 全程 ioctl 追踪 + 内核 function tracer 双向取证：

| 侧 | 观察 |
|---|---|
| 内核 | `tegra_channel_querycap`×15、`camera_common_enum_framesizes`×9、`camera_common_s_power`×3、`tegra_channel_set_power`×2 |
| 用户态 | **只有 `VIDIOC_QUERYCAP` 和 `VIDIOC_QUERY_EXT_CTRL`** |

**没有 `VIDIOC_S_FMT`、没有 `VIDIOC_STREAMON`、没有 `VIDIOC_S_CTRL`。**
argus 把 v4l2 节点当成了纯粹的「能力/控件枚举接口」，从没让通道进入流状态 ⇒
`tegra_channel_start_streaming` 不跑 ⇒ 传感器不上电 ⇒ MIPI 无数据 ⇒
`waitCsiFrameStart` 超时（`NvCaptureViCsiHw.cpp:1010`）。

### 下一轮的两条路（按把握度排序）

1. **修 DTB 的 `tegra-camera-platform` 节点**（正解，把握较高）
   - badge/position 换回出厂值（当前靠 shim 运行时覆盖兜着，已验证有效）
   - **模块顺序换回出厂的 `module0 = ov13b10`** —— `camera_server` 打开的是
     camera **id 0**，出厂那是主相机，我们这儿是鱼眼 ov7251。这条**尚未验证**，
     但很可能是「argus 认为该设备不需要 v4l2 开流」的上游原因。
   - 补 `devnode`（出厂有、我们没有；不过实测 PCL 本轮没读它）
   - 工具现成：`jp5-exp` 一次性实验启动项，DTB 改坏了自动拨回。
2. **查 argus 为何不走 v4l2 开流路径**：R32 的 argus 在 bypass 模式下应由
   `VIDIOC_STREAMON` 触发 `tegra_channel_start_streaming` → 传感器 `s_stream(1)`。
   需确认 R35 的 `tegra-capture-vi` 是否改变了这个契约
   （bus_info 已从 `platform:<addr>.vi:N` 变成 `platform:tegra-capture-vi:N`）。

### 本轮沉淀的工具（`tools/camera-probes/`）

`frame-trace.sh`（RCE 固件视角）、`sensor-live.sh`（采集中实况采样 I2C+debugfs）、
`v4l2-ioctl-trace.sh`（ioctl + 内核 function tracer 双向）、`mc-strace.sh`（确定性复现器）。
四个脚本全部遵守红线：出厂栈停着、只起全新实例、不触碰 active 的 `camera_server`。

---

## 🏆 DTB 相机节点修好：**传感器上电并进入 streaming**（2026-07-28 晚）

上一节的核心假设（模块顺序反了）**验证成立**。

### 改了什么

`tegra-camera-platform/modules` 换回出厂 `tegra194-mi-k91.dtb` 的描述：

| | 改前（NVIDIA 参考板 P2151） | 改后（出厂 RBP194） |
|---|---|---|
| module0 | ov7251_a@61 / `ov7251_0_P2151X` / `"0"` | **ov13b10@36 / `ov13b10_bottom_RBP194` / `"bottom"`** |
| module1 | ov7251_b@62 / `ov7251_1_P2151X` / `"1"` | ov7251_a@61 / `ov7251_l_center_RBP194` / `"center"` |
| module2 | ov13b10@36 / `ov13b10_2_P2151X` / `"2"` | ov7251_b@62 / `ov7251_front_RBP194` / `"front"` |

`devname` 与 `proc-device-tree` **保持指向本树自己的节点名**（`ov13b10_e@36` 等），
不能抄出厂的（出厂叫 `ov13b10@36`），否则 PCL 解析不到。

### 结果：`camera_server` 开 camera id 0 终于指向主相机

采集进行中实况采样（`tools/camera-probes/sensor-live.sh`）：

```
T+15s  driver-streaming=0   i2c reg 0x0100: 无应答
T+16s  driver-streaming=1   i2c reg 0x0100: 0x01     ← 上电 + 进入 streaming
 …     持续到 T+24s
```

**驱动 streaming 标志 1、I2C 直读 mode-select = 0x01** —— 传感器真的在发数据了。
这是整个 AI 相机战役里第一次看到传感器被点亮。

### 现在的墙：NVCSI 收不到

```
r32-power: group_busy (gated ON)
r32-stage2: prod applied (cphy=0) / mipi calibrate(on) rc=0 [direct]
r32-abi: ISP channel setup accepted
r32-abi: VI channel setup accepted (queue_depth=9 request_size=704)
[RCE] vi5_hwinit: firmware CL2018101701 protocol version 2.2
r32-sync: descriptor sync active (iova=0xbfe7c000 size=704)
vi capture get status failed          ← 仍然
```

RCE 追踪三计数仍是 **`vinotify_event=0` / `nvcsi_intr=0` / `vinotify_error=0`**。
**传感器在发、NVCSI 一个中断都收不到** —— 问题现在明确落在 MIPI 接收层
（lane 配置 / CIL 时钟 / 校准 / cphy-vs-dphy），正是 stage2/stage3 那批工作的靶心。

### ⚠️ 本轮的操作教训（重要）

**`jp5` 这个 good 条目的 Image（`b082b8ea`，7/26 构建）从来就不含 r32 相机补丁** ——
那批工作一直挂在 `jp5-exp` 上没转正（「E2 转正待机主拍板」）。狗在两次实验之间
**一直跑着上一轮实验的 `Image.exp`**（一次性机制只把 DEFAULT 拨回，不动文件）。
我第一次 arm 时错把 good Image 当成"当前内核"传了进去，重启后门控参数直接消失
（`/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power: No such file`），
整轮实验作废。

⇒ **做 DTB 实验前必须确认 `Image.exp` 是不是当前真正在跑的那个**，
   判据：`sudo strings -a <Image> | grep -c r32_camera_power`（good 件是 0）。

由此还导致第二个问题：变体 J 的 DTB（`b188ab22`）与 good DTB（`2228d7ab`）本就不同
（J 的 DTB 额外含电源拓扑 / nvcsi reg / mipical okay），而当前内核树已把那批 DTS
改动还原了，走源码路线会编出**不含**它们的 DTB。
解法：**直接对 J 的 DTB 反编译产物做手术**（`build/dtb-camera-modules-dts.py`），
保证与 J 的差异只有相机 modules 块（实测 44 行 diff，全在该块内）。
`dtc` 往返保真已自检（唯一差异是 `\007` vs `\a` 的转义写法，同一字节）。

> 🔴 又一次踩到 **`cmd | head -n` 的 SIGPIPE**：`dtc … 2>&1 | head -5` 把 dtc 杀了，
> 产物没生成却看不出错。这个坑今天第二次咬人 —— 输出一律落文件再看。

### 落地

- `build/dtb-camera-modules.py` —— 源码级（改 `tegra194-camera-p2151.dtsi`，
  已应用到内核树，下次整树构建自动带上）
- `build/dtb-camera-modules-dts.py` —— 二进制级（对已编好的 DTB 反编译后手术）
- `jp5-chroot-prep.sh` 的运行时覆盖改成**自纠正**：badge 里已含位置名就自动撤除，
  不再和修好的 DTB 打架（实测重启后覆盖目录已空，ISP 配置直接由 DTB 提供）

---

## 🔬 连拆三层 MIPI 校准空桩，并测定 argus 完全绕过内核 csi5（2026-07-29）

传感器点亮之后继续攻"NVCSI 收不到"。**没打通**，但拆掉了三层真实的空桩，
并测出一条改变后续方向的架构事实。

### 三层空桩，一层比一层深

**① `csi5_mipi_cal` 是 `return 0`（stage6）**

```c
static int csi5_mipi_cal(struct tegra_csi_channel *chan)
{
	/* Camera RTCPU handles MIPI calibration */
	return 0;
}
```

stage2 那句 `mipi calibrate(on) rc=0` 一直被当成"校准成功"，其实是**这个空桩的返回值**。
照 `csi4_mipi_cal` 补出真实现后，lane 掩码算得完全正确：
ov13b10 → `lanes=0x3000000` = CSIE|CSIF（port-index=4、4 lane）。

**② T194 的整套校准 SoC ops 也是空桩（stage7）**

```c
static int tegra_mipical_no_op(struct tegra_mipi *mipi, int lanes_info)
{  return -1;  }

static const struct tegra_mipi_soc tegra19x_mipi_soc = {
	.pad_enable = &tegra_mipi_bias_pad_no_op,
	.pad_disable = &tegra_mipi_bias_pad_no_op,
	.cil_sw_reset = NULL,
	.calibrate = &tegra_mipical_no_op,          ← 恒 -1
};
```

补上 stage6 后立刻现形：`calibration failed with -1 error`。
而 `mipi_cal.c` 自己的注释写着 *"For t19x, the register space is same as t18x"* ——
换回 T186 的真实现（`tegra_mipical_using_prod`）后 **`-1` 消失，`tegra_mipi_wait()`
返回 0，校准这条路彻底打通**。硬件侧本就就位（`mipical@3990000` okay、
`tegra_mipi_cal` 驱动已绑）。

**③ `cil_settletime=0` 没人算（stage8）**

DT 里 `cil_settletime = "0"` 是「自动计算」的约定，R35 固件会自己算、R32 不会。
按同树现成的 `tegra_csi_ths_settling_time()`（csi4 就是这么用的）补算，预期 19。

### 🔑 但真正改变方向的是这条测定

ftrace 内核相机函数，argus 取流全程：

| 函数族 | 调用次数 |
|---|---|
| `vi_capture_*` | 18 / 12 / 10 / 9 … |
| `vi5_*` | 2 |
| **`csi5_*`** | **0** |

**argus 只走 fusa-capture 的 VI 通道 ioctl，完全绕过内核的 `csi5_fops`。**
NVCSI 的流配置全部由 RCE 固件依 `CAPTURE_CHANNEL_SETUP` 消息完成，内核只是传声筒。

⇒ **stage3（csi5 的 R32 消息语义）和 stage8 对 argus 路径都是死代码**
（这也直接解释了为什么 stage8 部署后 dmesg 里一条 `r32-settle` 都没有）。
stage6 仍然有效 —— 它是经 stage2 的 `nvcsi_finalize_poweron → tegra_csi_mipi_calibrate`
进入的，与 csi5 的取流路径无关。

> 顺带排除：把 `cil_settletime` 用 shim 的 DT 覆盖直接喂成 19（argus 确实会读这个
> 属性，strace 有据），零帧依旧 —— 所以问题不在 settle time 这个值本身。

### 现状与下一轮靶心

传感器在发 ✅ 校准已成功 ✅ ISP/VI 通道全建好 ✅ RCE 握手正常 ✅ 描述符下发 ✅ —— 仍零帧。

既然 NVCSI 由 RCE 依消息配置，下一轮应转向 **`CAPTURE_CHANNEL_SETUP` 里 argus 填的
CSI/CIL 配置**：R32 固件期待的字段布局/语义与 R35 argus 填的是否一致
（此前 stage4 只逐字节核过描述符环的布局，没核过 channel config 里的 CSI 部分）。

产物：`build/stage6-csi5-mipical.py`、`stage7-mipical-t194.py`、`stage8-settletime.py`，
以及 `build-variant-{K,L,M}.sh`（断言均已扩展，DTB 复核新增"出厂 badge×3 + module0=主相机"两项）。

### 续：stage9/10/11 —— 把 R32 缺失的 CSI 配置链补齐（仍零帧）

顺着"R35 把 csi_stream 塞进 CAPTURE_CHANNEL_SETUP、R32 没有这个字段"这条线补下去：

| stage | 做了什么 | 实测结果 |
|---|---|---|
| 9 | 内核主动 `tegra_csi_start_streaming()` | 消息真的发出去了：`stream=4 port=4 lanes=4 mipi=448000kHz`。**但引入回归**：ISP 通道建立超时 |
| 10 | settle time 补算挪到 stage3 的 R32 路径 | `settle=19`（主相机）/ `28`（鱼眼）—— 与公式预测完全一致 |
| 11 | 把 CSI 流启动挪到 **VI 通道建立之后** | ISP 回归消失，传感器恢复出流 |

> stage8 打在了上游的 R35 版 `csi5_stream_set_config` 上，而实际发消息的是 stage3
> 自建的 R32 版函数 —— 所以它一直是死代码（`settle=0` 且没有任何 `r32-settle` 输出）。
> stage9 让消息真的发出去之后才暴露出来，stage10 才补对位置。
>
> stage9 的回归很有信息量：在**采集通道还不存在**时就用 `R32_TEMP_CHANNEL_ID` 发
> CSI 消息，会让 RCE 进入一个后续 ISP 通道建立必然超时的状态 ——
> **R32 的真实顺序是「先建采集通道、再开 CSI 流」**。

至此整条链每一环都已验证正确：

```
传感器 streaming(i2c 0x01) ✅   MIPI 校准成功 ✅
CSI 配置 stream=4/port=4/lanes=4/settle=19/mipi=448000kHz ✅（且在通道建立之后）
ISP 通道 ✅   VI 通道 ✅   RCE 握手 ✅   描述符下发 ✅
```

**仍然零帧**（`vinotify_event=0` / `nvcsi_intr=0` / `vi capture get status failed`）。

### 踩到的两个工程坑（都记账）

- **`-Werror=declaration-after-statement`**：把语句插在 `unsigned int x = f();` 之后，
  而后面还有声明 —— 项目内第二次踩。注入器要挑「声明区之后的第一条语句」当锚点。
- **子串重叠导致断言误判**：`"\t\tfoo();\n"` 包含 `"\tfoo();\n"`，
  先删单 tab 版会数出 2 次。**缩进不同的同名锚点必须从最长的先删**。

### stage12（诊断工具，未成功）：NVCSI 寄存器 debugfs

想要一个**不依赖 RCE、不依赖 trace 解码**的独立测量 —— 直接读 NVCSI 接收端寄存器，
判断"有没有看到 HS 跳变"。（`CONFIG_STRICT_DEVMEM=y` 挡住了用户态 `/dev/mem`，
只能加 debugfs。）

文件建起来了、能读出值，但**变体 Q 引入了 VI 回归**：`vi capture set config failed`
（P 上是更靠后的 `vi capture get status failed`，且传感器能出流）。
去掉寄存器读之后仍然复现 ⇒ **不是读寄存器扰动，是 stage12 本身**。

推测：`debugfs_create_file()` 挂在 `tegra194_nvcsi_finalize_poweron()` 里，
而那条路径可能持锁 / 不可睡眠，`debugfs_create_file` 会分配内存并取互斥锁 ——
拖慢之后让后续的 RCE 消息超时。**下次应改到 probe 时创建**。

> 目前最好的实验状态是**变体 P**（Image `1eb4f2ad` / DTB `9562d2d7`）：
> 传感器出流、CSI 配置参数与时序全对、无 VI/ISP 回归，只是零帧。


### 🔑 找到并补上了一个真实缺失：NVCSI 的 CIL 低功耗时钟（补丁 0004）

排除完 `match` 之后（见下），回头审构建脚本里那条一直存在的断言
`nvcsilp=0 ✅（仍不含 0004）` —— 补丁 **0004-t194-nvcsi-vi-r32-clocks-keepalive**
被每个变体刻意排除了。它的内容正对症：

```c
/*
 * R32 parity: the CIL low-power clock.  R35 dropped it (and the matching DT
 * property) because its own RCE firmware programs NVCSI clocks over BPMP.
 * The factory R32 firmware expects the kernel to have enabled both.
 */
{"nvcsilp", 204000000},
...
.poweron_reset = true,
.keepalive     = true,
```

**现场实测坐实**：

```
nvcsilp:  enable_cnt = 0   prepare_cnt = 0   rate = 204 MHz    ← 从未被使能
nvcsi:    enable_cnt = 1   prepare_cnt = 1   rate = 314 MHz
```

没有 CIL 低功耗时钟，CIL 检测不到 LP→HS 跳变 —— 接收端字面意义上什么都看不见，
与「零中断零帧零错误」完全吻合。DT 侧（`camera-power.dtsi`）本来就已经声明了
`clocks = <NVCSI>, <NVCSILP>`，缺的只是内核侧的时钟表。

变体 T（P + 0004）实测：**`nvcsilp enable_cnt` 0 → 2，时钟真的起来了**，传感器照常出流。
⚠️ 但**仍然零帧**。且注意 `nvcsi` 停在 **314 MHz**（0004 请求 400 MHz，父时钟
`pll_nvcsi` 无上限限制）—— 这是下一条线索。

> ⚠️ 打补丁顺序：0004 必须在 stage2 **之后**打 —— 两者都改 `t194.c` 的
> `t19_nvcsi_info`，先打 0004 会让 stage2 的 `.can_powergate` 锚点失配。

### 排除掉的：VI 通道的包匹配条件完全正确

stage13 挂在 `vi5_setup_surface` 上，实测 `r32-vi5` 计数为 **0** ——
**stage4/13 在 argus 路径下也是死代码**（`vi5_setup_surface` 属 v4l2 路径；
argus 自己在用户态填整个描述符）。这已是本工程**第三次**踩「改了没被走到的路径」
（stage3 / stage8 / stage4）。

stage14 改挂真正被调用的 `vi_capture_request`，读出 argus 填的匹配条件：

```
r32-match: dt=0x2b/0x3f  stream=16/0x3f  vc=1/0xffff
```

`stream=16` / `vc=1` 乍看是错的，但内核自己的参考实现给了权威答案：

```c
desc->ch_cfg.match.stream = (1u << nvcsi_stream); /* one-hot bit encoding */
desc->ch_cfg.match.vc     = (1u << chan->virtual_channel); /* one-hot bit encoding */
```

**是 one-hot 位编码** ⇒ `16 = 1<<4` = stream 4 ✅、`1 = 1<<0` = VC0 ✅、
`0x2B` = RAW10 ✅。匹配条件完全正确。

### 排除掉的：发射侧逐寄存器验证通过

采集进行中直接读传感器 I2C：

| 寄存器 | 读回 | 期望 |
|---|---|---|
| `0x300a/0b` chip_id | 0x560D | ov13b10 ✅ |
| `0x3808/09` X_OUT | 4208 | DT `active_w` ✅ |
| `0x380a/0b` Y_OUT | 3120 | DT `active_h` ✅ |
| `0x380c/0d` HTS | 1176 | DT `line_length=4704` = 1176×4 ✅ |
| `0x0100` | 0x01 | streaming ✅ |

### 排除掉的：RCE trace 解码本身没问题

全量事件统计：只有 6 个 `rtcpu_string` + 1 个 `rtcpu_start`，
**未知类型事件 0 个** ⇒ 解码器没在丢记录，「三计数全 0」是真的 ——
RCE 确实没观察到任何 VI 活动。

> **补充排除**：`nvcsi` 停在 314 MHz **不是 bug**。BPMP 层面
> `/sys/kernel/debug/bpmp/debug/clk/nvcsi/max_rate = 314000000` ——
> 314 MHz 就是这颗片子上该时钟的硬上限，0004 请求 400 MHz 被钳到 314 是正确行为
> （R32 当年在同一颗片子上也会被钳）。这条线索作废。

### 当前状态小结（2026-07-29 收尾）

**全部已验证正确 / 已排除**（每项都有逐字节、寄存器直读或 ftrace 实测证据）：

| 层 | 证据 |
|---|---|
| 传感器发射 | I2C 直读：chip_id `0x560D`、4208×3120、HTS×4=4704 与 DT 一致、`mode_select=0x01` |
| MIPI 校准 | stage6+7 之后真执行且 `tegra_mipi_wait` 返回 0 |
| CIL 低功耗时钟 | 补丁 0004：`nvcsilp enable_cnt` 0 → 2 |
| NVCSI 数据路时钟 | 314 MHz = BPMP 硬上限，正确 |
| CSI 流配置 | `stream=4 port=4 lanes=4 settle=19 mipi=448000kHz`，且在通道建立之后下发 |
| VI 包匹配 | `dt=0x2b/0x3f stream=16(1<<4) vc=1(1<<0)` —— one-hot 编码，全对 |
| 描述符 | 布局逐字节核过；IOVA 由 argus 自己填（stage4 是死代码）；`r32-sync` 生效 |
| 消息 ABI | CIL/brick 结构体两代逐字段相同；CSI 消息 ID 相同 |
| RCE | 握手成功（`CL2018101701 v2.2`）；trace 解码正常（未知类型事件 0） |

**仍然零帧。** RCE 确实没观察到任何 VI 活动。

**下一轮最该做的**：把 stage12 的 NVCSI 寄存器 dump 重做一遍（`debugfs_create_file`
挪到 **probe**，别挂在 `finalize_poweron` 那条被计时的握手路径上），
直接读 CIL 的链路状态寄存器 —— 这是唯一还没拿到的一手证据：
**接收端到底有没有在物理层看到任何跳变**。

### stage15：寄存器 dump 重做成功（挂 probe），但偏移取错

把 `debugfs_create_file` 从 `finalize_poweron` 挪到 `t194_nvcsi_late_probe`（冷路径）
之后，**stage12 的 VI 回归消失**，dump 能正常读了 —— 挂点的教训得到验证。

读到的 stream 4 块（+0x000..0x0FF）是一段 **6 值循环**：

```
+0x010: 00000012 00000028 00000029 0000002a
+0x020: 0000002b 0000002a 00000012 00000028   ← 12 28 29 2a 2b 2a 循环
```

`0x12/0x28/0x29/0x2A/0x2B/0x2A` = Embedded / RAW6 / RAW7 / RAW8 / **RAW10** / RAW8
—— 这是 **NVCSI 的数据类型配置表**，不是状态计数器。

⇒ 两点：
1. **NVCSI 的数据类型表里确实有 0x2B（RAW10）**，与传感器一致（又一项对上）。
2. 我用的偏移（借自 `csi4_registers.h`）**在 T194 上不对应状态寄存器**，
   所以"两次快照无差异"在这里**不构成**"物理层无活动"的结论。
   下次要找的是 PHY/CIL 块（`CSI5_PHY_OFFSET = 0x010000`）里的
   链路状态 / 错误计数，而不是 stream 块的前 256 字节。

> ⚠️ 另记：本轮多次观察到**运行间偶发** —— 同一个内核、同一个脚本，
> 约一半概率传感器不开流，`vi_channel_mask` 回 `0x0` 且 argus 报
> `Element not found` / `Mutex has not been initialized`（argus 自身状态乱）。
> 判据：`vi_channel_mask=0x800000000` 才是正常那次。做实验要看这个值，
> 别把偶发失败当成变体的结论。

### 🆕 新仪器：RCE 自己的中断计数（`camrtc/irqstat`）

`/sys/kernel/debug/camrtc/irqstat` 直接给出 **RCE 固件侧**的中断统计 ——
这是之前一直没用过、也不依赖 trace 解码的一手证据：

```
Irq#  Count   Runtime  Max rt  Name
  6    5077     5533     46    mbox
 23    4249    93590     79    vi-hp     ← VI 高优先级中断触发了 4249 次
 64       0        0      0    isp
 65       1        5      5    nvcsi
```

**这推翻了"接收侧什么都没发生"的直觉**：VI 硬件在持续给 RCE 产生中断
（`vi-hp` 4249 次、累计 runtime 93.6 ms），而 `nvcsi` 只有 1 次、`isp` 0 次。

⇒ 下一轮的靶心应转向：**RCE 收到这些 VI 中断后为什么不上报帧完成**
（而不是继续找"为什么没数据"）。可用 `irqstat` 做采集前后的增量对比
（注意 RCE 复位会把计数清零，前后快照必须在同一 RCE 会话内）。

### ⚠️ 实验方法学：同一次开机内不能反复做

实测：**成功的运行几乎都是重启后的第一次**。同一次开机内反复实验会累积坏状态，
表现为 `vi_channel_mask` 回 `0x0`、argus 报 `Element not found` /
`Mutex has not been initialized`（argus 自身状态乱），连续三轮全失败。

**判据：`vi_channel_mask=0x800000000` 才是有效运行。**
做变体对比时必须「一次重启 = 一次有效实验」，否则会把状态污染误判成变体结论。

### 🎯 故障点钉死：NVCSI 在链路层完全静默（RCE 中断增量实测）

有效运行（`vi_channel_mask=0x800000000`、传感器 `0x01`），
一次 `START_LIVE_STREAM` 期间 RCE 固件侧的中断增量：

| 中断源 | Δ | 含义 |
|---|---|---|
| **`vi-hp`** | **413** | VI 在疯狂产生中断（多半是超时/错误） |
| **`nvcsi`** | **0** | **CSI 接收器一个中断都没有** |
| `isp` | 0 | |
| `mbox` | 25 | IVC 消息往来正常 |

**结论：VI 在空转超时，NVCSI 在链路层从未看到任何东西。**

这与「发射侧逐寄存器验证通过 + 接收侧配置逐项验证通过」并存，说明问题不在
配置的**内容**，而在配置是否真的**落到了硬件上**，或者链路的物理层本身。

### 下一轮的三个方向（按可验证性排序）

1. **确认 RCE 是否真的执行了 CSI 配置**：我们发的 `STREAM_SET_CONFIG` /
   `PHY_STREAM_OPEN` 是 stage3 的 **fire-and-forget**（`rc=264` 只是 IVC 写入的
   字节数，不代表 RCE 处理了）。R32 固件本应回 RESP —— 应该改成等应答并检查
   返回码，而不是发完就走。这是目前最大的未验证假设。
2. ~~**`lane_swizzle` / `lane_polarity`**~~ —— **已排除**：`dtc` 解出厂
   `tegra194-mi-k91.dtb` 全文搜 `lane_polarity|lane_swizzle|swizzle|deskew`
   **一条都没有**，我们的运行时 DT 同样没有，`port-index=0x04` 两边一致。
   ⇒ 不需要 swizzle，stage3 的清零是对的。
3. **PHY/CIL 寄存器的链路状态**：stage15 的 dump 偏移取错了（读到的是数据类型表）。
   要读 `CSI5_PHY_OFFSET = 0x010000` 那一族里的链路/错误状态。

### ✅ 排除最大假设：RCE **接受了**全部 CSI 配置（stage16）

之前 stage3 的三条 CSI 消息是 **fire-and-forget**，且把 `channel_id` 硬编码成
`R32_TEMP_CHANNEL_ID = 64+1 = 65`。而 capture-ivc 的路由约定是：客户端必须先
`tegra_capture_ivc_register_control_cb(cb, &trans_id, priv)` **申请**一个 trans_id
（范围 `[NUM_CAPTURE_CHANNELS, TOTAL_CHANNELS)`），RCE 的应答才会路由到自己的回调。
硬编码 65 意味着应答被丢，甚至可能串到别的客户端的槽位上。

stage16 改成正规流程（申请 → 提交 → 等 250ms → 查 result → 注销；
拿不到 trans_id 时退回原行为）。实测：

```
r32-resp: STREAM_SET_CONFIG result=0 (0=OK) trans_id=70
r32-resp: PHY_STREAM        result=0 (0=OK) trans_id=71
…六条消息全部 result=0
```

**RCE 收到了、处理了、并且接受了每一条 CSI 配置。** 这条最大的未验证假设就此排除，
同时 stage16 本身是个真实的正确性修复（消除了硬编码 trans_id 的串槽风险）。

### 当前的完整证据面（软件能控的都已验证正确）

| 环节 | 状态 |
|---|---|
| 传感器发射 | ✅ 逐寄存器验证（chip_id / 分辨率 / HTS / streaming 位） |
| MIPI 校准 | ✅ 真执行且 `tegra_mipi_wait` 返回 0 |
| CIL 低功耗时钟 | ✅ `nvcsilp enable_cnt` 0→2（补丁 0004） |
| NVCSI 数据路时钟 | ✅ 314 MHz = BPMP 硬上限 |
| CSI 配置内容 | ✅ `stream=4 port=4 lanes=4 settle=19 mipi=448000kHz` |
| CSI 配置时序 | ✅ 在 VI 通道建立之后 |
| **RCE 是否接受** | ✅ **六条消息全部 `result=0`** |
| VI 包匹配 | ✅ one-hot：stream4 / VC0 / RAW10 |
| lane 交换/极性 | ✅ 出厂 DTB 同样没有 ⇒ 不需要 |
| 描述符 / 消息 ABI | ✅ 布局与消息 ID 逐字段核过 |
| **NVCSI 中断** | ❌ **Δ=0（VI 却有 Δ=413）** |

**软件侧已无可查之处** —— 所有能配置的都配置对了，RCE 也确认接受了，
但 CSI 接收器在链路层依然完全静默。

### 下一轮唯一剩下的方向

问题已窄到「**RCE 接受了配置，但 NVCSI 硬件没有真正进入接收状态**」。
可查的只剩两条，都需要看寄存器：

1. **PHY/CIL 链路状态寄存器**（`CSI5_PHY_OFFSET = 0x010000` 那一族）——
   stage15 的 dump 偏移取错了（读到的是数据类型配置表）。需要 T194 的 NVCSI
   寄存器映射，树里没有，可能要从 R32 内核源或 TRM 找。
2. **R32 固件在 PHY 上电/使能上是否还有一步没做**。
   已顺手排除两项：
   · `PHY_STREAM_OPEN` 的第三个字段 `phy_type` —— stage3 没显式填，但
     `NVPHY_TYPE_CSI = 0`，memset 后的 0 **恰好就是正确值**；
   · deskew（`NVCSI_IOCTL_DESKEW_SETUP/APPLY`）—— 只在 lane 速率 >1.5 Gbps 时需要，
     本机 1.12 Gbps 用不上。
   剩下的候选是 `PHY_STREAM_RESET` 之类的显式复位序列。

### stage17：`PHY_DUMPREGS` 被固件拒绝（`result=1`）—— 但这是个有价值的反证

R32 消息集里有 `CAPTURE_PHY_STREAM_DUMPREGS_REQ (0x3C)`，应答只回 `result`、
寄存器内容由固件打进自己的日志 —— 本来是绕开「本树没有 T194 NVCSI 寄存器映射」
的完美工具。实测：

```
r32-resp: PHY_DUMPREGS      result=1   ← 被拒
r32-resp: STREAM_SET_CONFIG result=0   ← 接受
r32-resp: PHY_STREAM        result=0   ← 接受
```

**这台固件没实现 DUMPREGS。** 但它同时构成一个有力的反证：
**RCE 是会区分的** —— 对能处理的命令回 0、对不能处理的回 1。
⇒ 之前那些 `result=0` 是**真正的接受**，不是笼统返回。CSI 配置确实被固件吃下去了。

### 本轮结束时的状态

软件可控的每一项都已逐条验证正确，RCE 也确认接受了配置，
**NVCSI 依然在链路层完全静默**（中断 Δ=0，而 VI 有 Δ=413 的超时中断）。

已排除的（本轮新增）：`phy_type`（`NVPHY_TYPE_CSI=0`，memset 后恰好正确）、
deskew（只在 >1.5 Gbps 需要，本机 1.12 Gbps）、
CSI 消息未被处理（六条 `result=0`，且与 DUMPREGS 的 `result=1` 形成对照）。

~~**唯一还没试过的东西**：`CAPTURE_PHY_STREAM_RESET_REQ (0x3A)`~~ ——
**已试，也排除**（stage18 / 变体 X）：固件**支持并执行了**它
（`r32-resp: PHY_RESET result=0`，四条全 0），**仍然零帧**。

### 软件侧搜索空间已穷尽

到此为止，软件能控制、能观测的每一项都已逐条验证或排除：

配置内容 ✅ 配置时序 ✅ RCE 接受 ✅（且会区分——`DUMPREGS` 回 1）
PHY 复位 ✅ 传感器发射 ✅ MIPI 校准 ✅ 全部时钟 ✅ 包匹配 ✅
lane 极性 ✅ 描述符与消息 ABI ✅ trace 解码 ✅
—— **NVCSI 中断依然 Δ=0**。

再往下需要本树没有的信息：
1. **T194 的 NVCSI 寄存器映射**（`csi4_registers.h` 的偏移在 T194 上不对应；
   固件自带的 `PHY_DUMPREGS` 这台 R32 固件没实现）——
   得从 R32 内核源或 Tegra TRM 找。
2. **R32 固件内部行为**：它接受了全部配置、执行了 PHY 复位，却不让 NVCSI 进入
   接收态。剩下的可能性偏向"某个 R32 期待的前置状态由 R32 内核在别处建立，
   而我们还没找到那一处" —— 这类东西只能靠拿到 **R32 的 nvcsi/csi5 内核源**
   逐函数比对。

### 🔓 拿到 R32.5.2 的公开内核源（本轮最有价值的资产）

容器有网络，直接取到了**狗上跑的那个版本**的官方源码：

```
https://developer.download.nvidia.com/embedded/L4T/r32_Release_v5.2/sources/T186/public_sources.tbz2   (174 MB)
  └─ Linux_for_Tegra/source/public/kernel_src.tbz2 (132 MB)
       └─ kernel/nvidia/drivers/media/platform/tegra/camera/{csi,nvcsi,vi}/
          kernel/nvidia/drivers/video/tegra/host/nvcsi/
```

已抽出并固化到容器 **`/work/r32-reference/`**（62 个文件，800 KB）——
以后任何「R32 到底怎么做的」都能直接查，不用再猜。

### stage19：拿 R32 原版一比，stage6 漏了最关键的一半

R32 的 `csi5_mipi_cal()` 在调 `tegra_mipi_calibration()` **之前**还写四次 PHY 寄存器：

```c
cila = (1<<E_INPUT_LP_IO0)|(1<<E_INPUT_LP_IO1)|(1<<E_INPUT_LP_CLK)
     | (0<<PD_CLK)|(0<<PD_IO0)|(0<<PD_IO1);
csi5_phy_write(chan, csi_port>>1, CIL_A_BASE + PAD_CONFIG_0, cila);
csi5_phy_write(chan, csi_port>>1, CIL_B_BASE + PAD_CONFIG_0, cilb);
csi5_phy_write(chan, csi_port>>1, CIL_A_SW_RESET, SW_RESET1_EN|SW_RESET0_EN);
csi5_phy_write(chan, csi_port>>1, CIL_B_SW_RESET, SW_RESET1_EN|SW_RESET0_EN);
```

`E_INPUT_LP_*` 是 **D-PHY 低功耗输入接收器的使能位**，`PD_*` 是**下电位**。
stage6 当初照 csi4 写、并**刻意跳过了这一段**（以为 prod settings 会管）——
**那个假设是错的**。补上后实测 `r32-padcfg: cila=0x700000 cilb=0x640000`，
与 R32 逐位一致。

> 顺带解释了 stage15 为什么读到数据类型表：PHY 块在
> `iomem_base + CSI5_BASE_ADDRESS(0x011000) + CSI5_PHY_OFFSET(0x010000)*index`，
> port4 ⇒ index2 ⇒ **0x031000**，我读的是 0x30000，差了 0x1000。
> （`csi5_registers.h` 两代逐字节相同，已 diff 验证。）

### stage20：pad 配置的重跑时机（与 0004 的 keepalive 冲突）

pad 配置 + 校准挂在 `finalize_poweron` 且被 `nvcsi->on` 守卫，一次开机只跑一次；
而补丁 0004 的 `keepalive = true` 让 NVCSI 不再掉电 ⇒ 永不重跑。
可日志里有 `r32-power: group_reset` —— **复位会把 NVCSI 寄存器清掉**。
R32 上 NVCSI 会在会话间掉电、每次采集前重跑一遍。stage20 在 CSI 流启动时补跑，
实测 `r32-recal: pad+cal rerun rc=0`。

**两者都是与 R32 对齐的真实修正，但仍然零帧。**

### ✅ 逐函数比对完成：内核侧对 R32 的还原已经**完整**

拿 `/work/r32-reference/` 里的 R32.5.2 官方源与本树逐文件比对（列出「R32 调用而
R35 不调用」的函数，再逐个判定）：

| 文件 | R32 独有的动作 | 覆盖情况 |
|---|---|---|
| `camera/nvcsi/csi5_fops.c` | `csi5_phy_write` / `writel` / `tegra_mipi_calibration` / `tegra_capture_ivc_control_submit` | stage3 + stage6 + **stage19** ✅ |
| `video/tegra/host/nvcsi/nvcsi-t194.c` | prod / 校准 / `host1x_writel`(cil_sw_reset) | stage2 ✅；`cil_sw_reset` 只在 `TEGRA_MIPI_IOCTL_*` 路径被调，正常采集流程不经过 |
| `camera/vi/capture.c` → `fusa-capture/capture-vi.c` | 仅 `nvhost_eventlib_log_submit` / `speculation_barrier` / `wait_for_completion` | **无任何硬件初始化动作** ✅ |
| `mipical/mipi_cal.c` | t19x soc ops | stage7 ✅ —— 且已核实 R32 的 `_tegra_mipi_bias_pad_enable` 与 R35 的 `_t18x_tegra_mipi_bias_pad_enable` **逐字节相同**（只是改了名）；唯一真差异是 R32 的 `.cil_sw_reset = NULL`，而它是 ioctl-only，无影响 |
| `camera/csi/csi.c` | 仅 `read_pixel_clk_from_dt` / `read_discontinuous_clk_from_dt` 两个 DT 读取 helper | 与硬件无关 ✅ |
| DTB prod-settings | `mipical`: `prod` / `prod_c_cphy_csi` / `prod_c_dphy_csi`；`nvcsi`: `prod` / `prod_c_cphy_mode` / `prod_c_dphy_mode` | **两处都齐全且命名正确** ✅ |

**结论：内核侧已经忠实还原了 R32 的全部行为，相机仍然零帧。**

### 这把问题推到了内核之外

到此为止，可以有把握地说：**问题不在内核**。剩下的可能性只有两类：

1. **R32 RCE 固件需要某个我们无法从 R35 内核提供的前置条件**。
   已知固件本身工作正常：接受全部 CSI 配置（`result=0`，且会拒绝
   `DUMPREGS` 回 `1`，证明它在真判断）、`vi5_hwinit` 握手正常、
   持续产生 VI 中断（Δ=413）。但它就是不让 NVCSI 进入接收态。
2. **板级/硬件差异** —— 例如某个电源域、复位、或 pinmux 由 JP4 的
   **引导器（cboot/MB2）**建立，而 JP5 的引导链没做。
   注意本工程一直跑的是 **R32 引导器 + R35 内核**的混血配置，
   引导器侧从未被审计过。

**下一轮建议从第 2 条切入**：对比 JP4 与 JP5 启动后
（相机相关的）电源域 / reset / pinmux 寄存器状态。
JP4 是可启动的（双系统），可以直接开进 JP4 抓一份基线再回来比。

> **再排除一项**：NVCSI 的 prod 数据与出厂 DTB **逐值相同** ——
> 三张表长度一致（`prod`=112 / `prod_c_cphy_mode`=160 / `prod_c_dphy_mode`=32 个 u32），
> 首 8 个值 `00011018 00070000 00020000 … 0001109c e000e000 c000c000` 逐字节吻合。
> ⇒ stage2 写进 NVCSI 的寄存器值与出厂完全一致。

### stage21：DTB 逐节点比对，补回三处缺失属性（仍零帧）

内核侧比对完毕后转去比 DTB：把出厂 `tegra194-mi-k91.dtb` 与运行时
`/proc/device-tree` 的**属性集合**逐节点做差。

| 节点 | 出厂有、我们缺 | 出厂值 |
|---|---|---|
| `nvcsi@15a00000` | `interrupts` | `<0x00 0x77 0x04>` |
| `nvcsi@15a00000` | `num-ports` | `<0x06>` |
| `isp@14800000` | `reg` | `<0x00 0x14800000 0x00 0x10000>` |

ISP 的 `reg` 与当年 nvcsi 的情况完全平行 —— R35 因为「RCE 自己管」删掉 MMIO 窗口，
stage2 补回了 nvcsi 的，**没人补 ISP 的**。三条全部补回（变体 AA），**仍然零帧**。

同时核实为**一致**的（都逐字节比过）：
`clocks` / `resets` / `power-domains` / `prod`（三张表 112/160/32 个 u32）/
`rtcpu` 的 `nvidia,camera-devices`（指向 isp/vi/nvcsi 三个设备）。

### 另：用 R32 源反证了 stage3 是忠实的

R32 原版的 `csi5_stream_set_config()` 与 stage3 实现**逐行一致** ——
包括 `error_config` 就是不设（memset 后为零）、`channel_id` 用硬编码的
`TEMP_CHANNEL_ID`、以及 fire-and-forget（不等应答）。
⇒ 之前怀疑「error_config 全零屏蔽了错误上报」是**误判**，R32 本来就这样。
（stage16 改成申请 trans_id 反而偏离了 R32；它作为诊断手段有价值，
 但不应进最终件 —— 变体 Z/AA 都没带它。）

### 固件侧也问完了

- `camrtc/log-level` **最大只接受 3**（之前脚本一直试 6/5/4，全部写入失败 ——
  等于**从没真正提高过**）。改对之后重跑，RCE 仍然只吐同样那 6 条
  （ISP 的 error-notification 警告 + `vi5_hwinit` 版本行）——
  **固件对 CSI 流的处理是真的不打日志**。
- `camrtc/version` = `cpu=rce cmd=5 sha1=cf2bef3a…`；`memstat` 正常（heap 45 KB / free 129 KB）；
  `mods` / `rtos` 读出为空。
- `PHY_DUMPREGS` 这台固件没实现（`result=1`）。

⇒ **固件侧能问的都问完了，它不肯多说。**

---

## 📍 本轮收尾时的完整状态

**已逐项验证正确 / 已排除**（每条都有官方源、出厂 DTB、寄存器直读或 ftrace 实测为据）：

传感器发射 · MIPI 校准 · CIL pad 配置 · CIL 低功耗时钟 · NVCSI 数据路时钟 ·
CSI 配置内容与时序 · RCE 接受配置 · PHY 复位 · VI 包匹配 · lane 极性/交换 ·
描述符与消息 ABI · trace 解码 · prod 数据 · DTB 节点与属性 · 内核逐函数

**现象**：`nvcsi` 中断全程 Δ=0，`vi-hp` 有 Δ=413 的超时中断。

**剩下唯一的解释**：R32 RCE 固件需要某个我们观察不到的前置条件。
固件是 eMMC boot0 里的二进制、不可刷写、不肯多说 —— 这是本工程从一开始就知道的
最硬的约束，现在所有别的可能性都被排除之后，它成了唯一剩下的那个。

**若要继续，唯一有信息增量的做法是开进 JP4 做在线对照**
（同一颗 RCE 固件、同一块板子，唯一变量是内核）：抓 JP4 的
`camrtc/irqstat` / `tegra_rtcpu` trace / NVCSI 寄存器基线，回来逐项比。
⚠️ 需要切换启动项，按本项目安全红线**应在机主在场时做**。
