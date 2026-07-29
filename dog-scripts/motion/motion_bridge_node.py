#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CyberDog 运动板 ↔ ROS2 桥（**只读侧**）

把运动板 500Hz/1kHz 的 LCM 遥测接进 ROS2：
    myIMU            1kHz  → sensor_msgs/Imu           /mi1045904/motion/imu
    leg_control_data 500Hz → sensor_msgs/JointState    /mi1045904/motion/joint_states
    （诊断）                → diagnostic 文本            /mi1045904/motion/status

🔴 **本节点没有任何发送路径** —— 它只 recvfrom，不 sendto，不 import 安全闸门。
   写侧是完全独立的另一个组件（motion_safety.py），刻意不放在同一个进程里，
   这样"读桥跑着"这件事本身不可能导致狗动。

── 关于关节数据（必读）────────────────────────────────────────────────────
2026-07-29 实测：**没有电池时关节反馈是冻结的**（电机驱动器无电 → 无编码器）。
`leg_control_data` 的 q/qd/tau 会是逐关节恒定的配置限值，不是测量值。
本节点因此会**主动检测冻结**并在 `/motion/status` 里报出来，而不是把假数据
当真发布 —— 下游（状态估计、里程计）拿到冻结数据却不自知是很危险的。
判据：滑动窗口内 q 的逐关节标准差全为 0 ⇒ 标记 frozen。

── 坐标与单位 ────────────────────────────────────────────────────────────
IMU：microstrain_lcmt 给 quat[4]/rpy[3]/omega[3](rad/s)/acc[3](m/s²)。
     实测静止时 acc 合模 9.679，姿态 roll/pitch≈0（狗平放）—— 物理正确。
关节：12 个，顺序 = 腿(FR,FL,RR,RL) × 关节(abad,hip,knee)，与 MIT Cheetah 一致。

用法（在 chroot 里，需 ROS2 环境）：
    python3 motion_bridge_node.py
"""
import collections
import math
import socket
import struct
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSReliabilityPolicy, QoSHistoryPolicy
from sensor_msgs.msg import Imu, JointState
from std_msgs.msg import String

LCM_GROUP = "239.255.76.67"
LCM_PORT = 7667                 # 运动板内部遥测（只读）
MAGIC_SHORT = 0x4C433032
FP = 8

LEG_NAMES = ["fr", "fl", "rr", "rl"]
JOINT_NAMES = ["abad", "hip", "knee"]
JOINTS = ["%s_%s" % (l, j) for l in LEG_NAMES for j in JOINT_NAMES]


class MotionBridge(Node):
    def __init__(self):
        super().__init__("motion_bridge")
        ns = "/mi1045904/motion"
        qos = QoSProfile(depth=10, history=QoSHistoryPolicy.KEEP_LAST,
                         reliability=QoSReliabilityPolicy.RELIABLE)
        # 传感器数据用 best_effort 更合适（高频、丢一帧无所谓）
        sqos = QoSProfile(depth=10, history=QoSHistoryPolicy.KEEP_LAST,
                          reliability=QoSReliabilityPolicy.BEST_EFFORT)
        self.pub_imu = self.create_publisher(Imu, ns + "/imu", sqos)
        self.pub_js = self.create_publisher(JointState, ns + "/joint_states", sqos)
        self.pub_st = self.create_publisher(String, ns + "/status", qos)

        # ⚠️ 只创建接收 socket。本节点全程不调用 sendto。
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("", LCM_PORT))
        self.sock.setsockopt(
            socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
            struct.pack("4sl", socket.inet_aton(LCM_GROUP), socket.INADDR_ANY))
        self.sock.settimeout(0.5)

        # 降频：1kHz IMU 不必原速进 DDS
        self.imu_div = 5            # 1kHz → 200Hz
        self.js_div = 5             # 500Hz → 100Hz
        self.n_imu = self.n_js = 0
        self.pub_imu_n = self.pub_js_n = 0

        # 关节冻结检测：滑动窗口
        self.q_hist = collections.deque(maxlen=40)
        self.frozen = None          # None=未知, True/False
        self.t_report = time.monotonic()

        self.get_logger().info(
            "运动桥（只读）启动：监听 %s:%d，发布 %s/{imu,joint_states,status}。"
            "本节点无任何发送路径。" % (LCM_GROUP, LCM_PORT, ns))

    # ── 解码 ────────────────────────────────────────────────────────────────
    @staticmethod
    def dec_imu(p):
        quat = struct.unpack_from(">4f", p, FP)
        rpy = struct.unpack_from(">3f", p, FP + 16)
        omega = struct.unpack_from(">3f", p, FP + 28)
        acc = struct.unpack_from(">3f", p, FP + 40)
        return quat, rpy, omega, acc

    @staticmethod
    def dec_leg(p):
        q = struct.unpack_from(">12f", p, FP)
        qd = struct.unpack_from(">12f", p, FP + 48)
        tau = struct.unpack_from(">12f", p, FP + 192)   # q,qd,p,v 之后
        return q, qd, tau

    # ── 主循环 ──────────────────────────────────────────────────────────────
    def spin_once(self):
        try:
            data, _ = self.sock.recvfrom(65535)
        except socket.timeout:
            return
        if len(data) < 8 or struct.unpack_from(">I", data, 0)[0] != MAGIC_SHORT:
            return
        i = data.find(b"\0", 8)
        if i < 0:
            return
        ch = data[8:i].decode("utf-8", "replace")
        p = data[i + 1:]

        if ch == "myIMU" and len(p) == 80:
            self.n_imu += 1
            if self.n_imu % self.imu_div:
                return
            quat, rpy, omega, acc = self.dec_imu(p)
            m = Imu()
            m.header.stamp = self.get_clock().now().to_msg()
            m.header.frame_id = "imu_link"
            # microstrain 的 quat 顺序是 (w,x,y,z)
            m.orientation.w, m.orientation.x, m.orientation.y, m.orientation.z = quat
            m.angular_velocity.x, m.angular_velocity.y, m.angular_velocity.z = omega
            m.linear_acceleration.x, m.linear_acceleration.y, m.linear_acceleration.z = acc
            # 没有厂商给的协方差；用 -1 标记"未知"是 ROS 的约定
            m.orientation_covariance[0] = -1.0
            m.angular_velocity_covariance[0] = -1.0
            m.linear_acceleration_covariance[0] = -1.0
            self.pub_imu.publish(m)
            self.pub_imu_n += 1

        elif ch == "leg_control_data" and len(p) == 392:
            self.n_js += 1
            q, qd, tau = self.dec_leg(p)
            self.q_hist.append(q)
            if self.n_js % self.js_div:
                return
            js = JointState()
            js.header.stamp = self.get_clock().now().to_msg()
            js.name = JOINTS
            js.position = list(q)
            js.velocity = list(qd)
            js.effort = list(tau)
            self.pub_js.publish(js)
            self.pub_js_n += 1

    def check_frozen(self):
        """⚠️ 关键安全特性：把"关节数据是冻结的"这件事显式报出来。
        下游拿到冻结数据却不自知，比拿不到数据危险得多。"""
        if len(self.q_hist) < self.q_hist.maxlen:
            return None
        cols = list(zip(*self.q_hist))
        return all(len(set(c)) <= 1 for c in cols)

    def report(self):
        now = time.monotonic()
        if now - self.t_report < 5.0:
            return
        dt = now - self.t_report
        fz = self.check_frozen()
        if fz is not None and fz != self.frozen:
            self.frozen = fz
            if fz:
                self.get_logger().warn(
                    "⚠️ 关节数据【冻结】—— 逐关节标准差全为 0。"
                    "没有电池时这是预期行为（电机驱动器无电 → 无编码器反馈）。"
                    "joint_states 里的值是配置限值，**不是测量值**，请勿用于状态估计。")
            else:
                self.get_logger().info("✅ 关节数据已变为活数据（有电机供电）")

        st = String()
        st.data = ("imu=%.1fHz joints=%.1fHz frozen=%s"
                   % (self.pub_imu_n / dt, self.pub_js_n / dt,
                      "未知" if self.frozen is None else ("是⚠️" if self.frozen else "否✅")))
        self.pub_st.publish(st)
        self.get_logger().info(st.data)
        self.pub_imu_n = self.pub_js_n = 0
        self.t_report = now

    def run(self):
        while rclpy.ok():
            self.spin_once()
            self.report()

    def close(self):
        self.sock.close()


def main():
    rclpy.init()
    n = None
    try:
        n = MotionBridge()
        n.run()
    except KeyboardInterrupt:
        pass
    finally:
        if n:
            n.close()
            n.destroy_node()
        try:
            rclpy.shutdown()
        except Exception:
            pass


if __name__ == "__main__":
    main()
