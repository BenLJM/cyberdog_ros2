# CyberDog 相机→VIO→里程计→站立：续做交接（2026-07-22）

> ## ⚠️ 2026-07-22 当日晚些时候已被推翻——先读 STAND-TRUTH-2026-07-22.md
> 本文档"DDS 不通→无 odom→不能站立"的因果链是**误诊**：odom_out 来自运动板 LCM 腿部里程计（已验证 500Hz 健康流动），与相机 VIO 无关；"Odom offline"日志是 DEFAULT 模式正常噪音；站立唯一阻碍是**电池（1%/16.7V，充电通路失效）**；"抱狗晃初始化 VIO"是伪需求。
> 本文档中 RSUSB/rs_bridge/ov_msckf 的**技术成果与操作细节仍然有效**（未来导航用），§3 的 DDS 问题降级为 Phase 5 导航项。

给续做的新会话：这是一份**可直接执行**的交接。目标是让机器狗能站立；卡点是一个很具体的 ROS2 DDS 投递问题（见 §3）。相机驱动本身**已经打通**，别重做。

---

## 0. 一句话现状
在 **JP4 出厂系统**上，自建的 RSUSB 版 librealsense + 自写的 `rs_bridge` 节点**已经在稳定出流** infra1+IMU；`ov_msckf`（改成单目）已 active 并订阅了桥。**唯一没通的最后一环：桥（独立进程）发布的数据传不到栈里的节点**，导致 `odom_out` 没数据 → `motion_manager` 报 "Odom offline" → 拒绝站立。

## 1. 访问方式（重要：变了）
- **直连 Wi-Fi：`ssh mi@10.0.0.219`**（当前可用）。
- 旧的笔记本桥 `ben@10.0.0.176 → mi@192.168.55.1` **现在挂了**（笔记本睡了/掉线）。若要用，先让机主唤醒笔记本。
- JP4 上 `mi` 是**免密 sudo**。
- 跑任何 `ros2` 命令前**必须**先设这套环境（否则发现不到栈）：
  ```bash
  source /opt/ros2/foxy/setup.bash; source /opt/ros2/cyberdog/setup.bash
  export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1 CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml
  ```
- 节点命名空间前缀是 `/mi1045904`。

## 2. 已部署、可用的东西（别重做）
- **RSUSB librealsense 2.48.0**：`/home/mi/librealsense-2.48.0/build/librealsense2.so.2.48.0`（202MB，`cmake -DFORCE_RSUSB_BACKEND=true`，用了系统 `libusb-1.0-0-dev`）。**系统库已换成它**：`/usr/lib/aarch64-linux-gnu/librealsense2.so.2.48` → `.2.48.0`（RSUSB）。旧 V4L2 库备份在 `/home/mi/librealsense2.so.2.48.0.v4l2backup`。装了 udev 规则 `/etc/udev/rules.d/99-realsense-libusb.rules`。
  - **为什么必须 RSUSB**：出厂 `realsense2_camera` 节点走 V4L2(uvcvideo)在 4.9 内核上**启流必失败**（`IR/Depth stream start failure, Hardware Error`）；而 librealsense 的 pipeline API（RSUSB）能出帧。`-32` uvcvideo 报错是无害噪音（Intel 官方确认），别追。
- **`rs_bridge` 节点**：colcon 包在 `/home/mi/rs_ws`；二进制 `/home/mi/rs_ws/install/rs_bridge/lib/rs_bridge/rs_bridge`。源码 `.../src/rs_bridge/src/bridge.cpp`。它用 pipeline 抓 infra1(mono8) + 融合 IMU（copy 最近 accel 到每个 gyro），发到 `/mi1045904/camera/{infra1/image_rect_raw, imu}`（**reliable QoS**，ns=`/mi1045904/camera`，node name=`camera`）。当前是**回调直接发布**版（稳定不崩，跑了几小时几十万帧）。
  - 开机自启服务 `/etc/systemd/system/rs-bridge.service`（enabled）。
  - **RSUSB 重抓设备不稳**：桥被 kill -9 或崩溃后重启常"No device"，得靠开机干净设备。所以别频繁手动起杀；改动后优先 `sudo reboot` 让服务在干净设备上起。
- **ov_msckf 改单目**（`/opt/ros2/cyberdog/share/ov_msckf/launch/ros2.launch.py`）：`use_stereo=false, max_cameras=1`，`stereo_pairs` **保持 `'[0, 1]'` 别改成 `[]`**（launch_ros 不接受空序列，会崩 `TypeError: Expected a non-empty sequence`）。remapping 已对：`topic_camera0:=camera/infra1/image_rect_raw`、`imu:=camera/imu`。
- **on_dog.py**：`enable_infra2=false, enable_sync=false`（避开双红外硬限+同步器饿死）。
- **出厂相机节点已禁**：`automation_launch.py` 第91行 `#ld.add_action(realsense_cmd)`。
- **ov_msckf 是 cascade_lifecycle 节点、开机默认 unconfigured**；靠 `/etc/systemd/system/ov-activate.service`（enabled，开机 `ros2 lifecycle set ... configure`+`activate`）激活，否则它不订阅相机。
- **cyclonedds 配置**：`/etc/systemd/system/cyclonedds.xml`，已把 `MaxAutoParticipantIndex` 从 30 改成 **200**（备份 `.bak` 是 30）。lo 接口、`AllowMulticast=false`、单播 peers=localhost、48 个节点。

**回滚**：所有 `.v4l2backup`/`.stereobak`/`.bak` 都在（见 §2 各路径）。恢复系统库=把 v4l2backup 拷回 `.2.48.0` + `ldconfig`。

## 3. ⚠️ 核心未解问题：DDS 投递
**症状（已多次复现）**：
- `ros2 topic echo /mi1045904/status_out`（**栈发的**）→ 我的 CLI **能收到**数据。
- `ros2 topic hz /mi1045904/camera/infra1/image_rect_raw --qos-reliability reliable`（**桥发的**）→ **NO-DATA**。
- `ros2 topic info` 显示桥是 Publisher(1)、ov_msckf 是 Subscriber(1)——**发现是成功的**，但**数据不流**。ov_msckf 完全静默（OpenVINS 有图会打日志）。
- QoS 已对齐（桥 reliable、ov_msckf reliable；reliable 发布者也能喂 best_effort 订阅者）。
- 桥和栈的 DDS 环境变量**完全一致**（已 `/proc/PID/environ` 比对）。

**结论**：栈自己的发布者能投递给新订阅者；但**我的桥（一个独立 systemd 服务起的新参与者）的发布，别人收不到**。不是发现、不是 QoS、不是环境、不是参与者索引（改 200 无效）。

**已排除/试过无效**：改 reliable QoS、MaxAutoParticipantIndex 30→200、重启 ros2 daemon、多次整机重启、把回调发布改成"入队+定时器在执行器线程发布"（还踩了 `rs2::frame` 跨线程生命周期崩溃 `null frame_ref`——注意 `std::queue<rs2::frame>` + `f.keep()` 都没解决那个崩溃，最后退回回调直接发布才稳定；崩溃这条线是死胡同，别再走）。

## 4. 最可能的正解（优先试这个）
**把桥塞进栈的那个 launch 里跑**，而不是独立 systemd 服务。依据：出厂的"相机→ov_msckf"能通，是因为出厂相机节点是被 `automation_launch.py` 和 ov_msckf **同一个 launch** 起的；独立服务起的参与者投递不出去。做法（未验证，需你实现+验证）：
1. 把 `rs_bridge` 装进栈能找到的地方（`colcon build --install-base /opt/ros2/cyberdog --merge-install`，或让 `cyberdog_ros2.service` 也 source `/home/mi/rs_ws/install/setup.bash`）。
2. 在 `automation_launch.py` 里加一个 `Node(package='rs_bridge', executable='rs_bridge', name='camera', namespace=<ns>/camera)` 并 `ld.add_action(...)`（注意 namespace 拼接，参考里面其它 Node/Include 怎么用 `namespace`）。
3. 停用 `rs-bridge.service`（`sudo systemctl disable --now rs-bridge`）免得双起抢相机。
4. `sudo reboot`，验证 §3 的 `hz` 这次有没有数据、ov_msckf 是否开始出 `odom_out`。

**其它可试的 DDS 方向**（若正解不行）：`AllowMulticast` 改 `spdp` 或 `true`（本机 lo 多播发现是否更稳）；给桥的参与者一个固定低 `ParticipantIndex`；对比出厂相机节点被杀重启后（同样独立进程）能不能投递，以判断到底是不是"launch vs 独立进程"。

## 5. 站立测试流程（正解通了之后）
1. **机主必须在场**（物理运动 + 看着狗）。**电池要够**（当前 `soc:1 / 17.2V` 且在慢掉，见 §6——站立电机猛抽电，太低会掉电）。
2. odom 通道通了还不够——**单目 VIO 静止不能初始化尺度**：让机主**抱起狗左右前后平移晃 15-20 秒**，盯 `ros2 topic hz /mi1045904/odom_out`；出数了就说明 VIO 初始化成功。
3. odom 上来后，`motion_manager` 的 "Odom offline" 会消失。命令站立：
   ```bash
   # 先 checkout_mode 到 MANUAL(3)，再 exe_monorder STAND_UP(9)；趴下=PROSTRATE(10)
   ros2 action send_goal /mi1045904/exe_monorder motion_msgs/action/ExtMonOrder "{orderstamped: {timestamp: {sec: $(date +%s), nanosec: 0}, id: 9, para: 0.0}}"
   ```
   之前静止时发 STAND_UP 返回 `err_code:7 UNAVAILABLE`（被 odom-offline 挡）——这正是要 odom 通了才行的证据。

## 6. 硬件/物理限制（不是软件能解的）
- **双红外硬限**：这颗 D455 在本机 USB 拓扑下**立体模块一次只能出一路**（depth XOR infra1 XOR infra2；每路单独都能出，任意两路同时=只出一路，连 424×240 都不行→不是带宽，是端点/拓扑结构限制）。所以**双目立体 VIO 做不到，只能单目**。机主问"能不能彻底解决只出一路"——软件解不了，除非换 USB 走线/相机模块，或在 xHCI/内核层动 endpoint 限制（JP4 是 4.9 内核，难）。
- **电池**：机主插了电池但 `soc` 一直读 1%、电压 18.2→17.6→17.2V **在慢慢掉**（适配器没把它充上，或在放电）。站立前务必确认电池够，否则会像 day1 那样掉电重启。
- 狗访问怪癖见 [[cyberdog-retrospective-0719]]（Wi-Fi 芯片赖床、USB 插着冷启动可能进 RCM 等）。

## 7. 手上的诊断工具（狗上）
- `/tmp/rstest_rsusb`（可能已被重启清掉，源码 `/home/mi/rstest2.cpp`、`/home/mi/rstest3.cpp`）：链 RSUSB 库、数各路流帧数，用法 `LD_LIBRARY_PATH=/home/mi/librealsense-2.48.0/build /tmp/rstest3 <mode> [w h fps]`，mode= infra1/infra2/infra/depth/color/stereo/all。**这是验证"相机硬件+RSUSB出流"的黄金工具**。
- `rs-enumerate-devices`（系统装了 rs-* 全套工具）、`rs-save-to-disk`（存图证明相机好）。
- 快照脚本思路见 `/tmp/sn.sh`（已删，逻辑：查服务/流/DDS症状/配置/备份）。

## 8. 别踩的坑
- 别重做 RSUSB 库/桥（已通）。别追 uvcvideo `-32`（无害）。别把 `stereo_pairs` 改空（崩）。别频繁 kill 桥（RSUSB 重抓不稳）。别在机主不在时测站立。别动相机 bootloader/固件（变砖，且没必要）。别盲驱动 MCU 使能脚（会敲掉 Wi-Fi，见旧记忆）。
