#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CyberDog 全传感器 + VIO 在线普查 —— 纯订阅，只读，不发任何指令。

在 chroot 内跑（需 ROS2 环境）。对每个关心的话题订阅一段时间，报实际频率、
最新一条的关键字段，并给出健康判定。

判据说明：话题存在 ≠ 有数据。本工具一律以**实际收到的消息**为准。
"""
import importlib
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSReliabilityPolicy, QoSHistoryPolicy

NS = "/mi1045904"
DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0

# (话题, 消息类型, 期望最低频率Hz, 摘要函数名)
TOPICS = [
    # ── VIO / 里程计 ──（⚠️ 话题在命名空间下，写全局路径会误判成"无发布者"）
    (NS + "/odom_out",              "nav_msgs/msg/Odometry",        0.5, "odom"),
    (NS + "/ov_msckf/poseimu",      "geometry_msgs/msg/PoseWithCovarianceStamped", 0.2, "pose"),
    (NS + "/ov_msckf/pathimu",      "nav_msgs/msg/Path",            0.2, "path"),
    (NS + "/ov_msckf/odomfusion",   "nav_msgs/msg/Path",            0.2, "path"),
    (NS + "/ov_msckf/trackhist",    "sensor_msgs/msg/Image",        0.2, "img"),
    (NS + "/dog_pose",              "motion_msgs/msg/SE3Pose",      0.5, "raw"),
    # ── 运动 ──
    (NS + "/status_out",            "motion_msgs/msg/ControlState", 1.0, "ctrl"),
    (NS + "/motion/imu",            "sensor_msgs/msg/Imu",         10.0, "imu"),
    (NS + "/motion/joint_states",   "sensor_msgs/msg/JointState",   5.0, "js"),
    (NS + "/safe_guard",            "motion_msgs/msg/Safety",       0.0, "raw"),
    # ── 相机 ──
    (NS + "/ai_camera/image_raw",               "sensor_msgs/msg/Image", 5.0, "img"),
    (NS + "/ai_camera/fisheye_left/image_raw",  "sensor_msgs/msg/Image", 5.0, "img"),
    (NS + "/ai_camera/fisheye_right/image_raw", "sensor_msgs/msg/Image", 5.0, "img"),
    (NS + "/camera/infra1/image_rect_raw",      "sensor_msgs/msg/Image", 5.0, "img"),
    (NS + "/camera/depth/image_rect_raw",       "sensor_msgs/msg/Image", 5.0, "img"),
    (NS + "/camera/imu",                        "sensor_msgs/msg/Imu",  50.0, "imu"),
    # ── 板载传感器（话题名以实际 ros2 topic list 为准，不要猜）──
    (NS + "/bms_recv",            "ception_msgs/msg/Bms",            0.2, "bms"),
    (NS + "/BodyState",           "ception_msgs/msg/BodyState",      0.2, "raw"),
    (NS + "/ObstacleDetection",   "ception_msgs/msg/Around",         0.5, "raw"),
    (NS + "/SceneDetection",      "motion_msgs/msg/Scene",           0.0, "raw"),
    (NS + "/TouchState",          "interaction_msgs/msg/Touch",      0.0, "raw"),
    (NS + "/wifi_rssi",           "std_msgs/msg/String",             0.0, "raw"),
    (NS + "/tracking_status",     "automation_msgs/msg/TrackingStatus", 0.0, "raw"),
]



def imp(t):
    pkg, _, cls = t.split("/")
    return getattr(importlib.import_module(pkg + ".msg"), cls)


def s_odom(m):
    p = m.pose.pose.position
    tw = m.twist.twist.linear
    return "位置(%.3f,%.3f,%.3f) 速度(%.3f,%.3f,%.3f) frame=%s" % (
        p.x, p.y, p.z, tw.x, tw.y, tw.z, m.header.frame_id)


def s_pose(m):
    p = m.pose.pose.position
    return "位置(%.3f,%.3f,%.3f)" % (p.x, p.y, p.z)


def s_path(m):
    n = len(m.poses)
    if n:
        p = m.poses[-1].pose.position
        return "%d 个位姿 末点(%.3f,%.3f,%.3f)" % (n, p.x, p.y, p.z)
    return "0 个位姿（VIO 未初始化）"


def s_ctrl(m):
    return "mode=%d gait=%d order=%d 错误=%d" % (
        m.modestamped.control_mode, m.gaitstamped.gait,
        m.orderstamped.id, m.error_flag.exist_error)


def s_imu(m):
    a = m.linear_acceleration
    g = m.angular_velocity
    mag = (a.x ** 2 + a.y ** 2 + a.z ** 2) ** 0.5
    return "acc模=%.2f 角速度(%.3f,%.3f,%.3f)" % (mag, g.x, g.y, g.z)


def s_js(m):
    return "%d 关节 首个 q=%.3f" % (len(m.position), m.position[0] if m.position else 0)


def s_img(m):
    return "%dx%d %s" % (m.width, m.height, m.encoding)


def s_bms(m):
    return "SOC=%d%% %.2fV %.2fA 温度%d°C 健康%d%%" % (
        m.batt_soc, m.batt_volt / 1000.0, m.batt_curr / 1000.0,
        m.batt_temp, m.batt_health)


def s_raw(m):
    fs = list(m.get_fields_and_field_types())[:4]
    out = []
    for f in fs:
        v = getattr(m, f, None)
        if hasattr(v, "__len__") and not isinstance(v, str):
            out.append("%s[%d]" % (f, len(v)))
        else:
            out.append("%s=%s" % (f, str(v)[:22]))
    return " ".join(out)


SUM = {"odom": s_odom, "pose": s_pose, "path": s_path, "ctrl": s_ctrl, "imu": s_imu,
       "js": s_js, "img": s_img, "bms": s_bms, "raw": s_raw}


class Survey(Node):
    def __init__(self):
        super().__init__("sensor_survey")
        self.n = {}
        self.last = {}
        self.pubs = {}
        for topic, tname, _, _ in TOPICS:
            try:
                cls = imp(tname)
            except Exception:                              # noqa: BLE001
                self.n[topic] = -1
                continue
            self.n[topic] = 0
            # ⚠️ 只订阅一次。上一版对同一话题同时订 RELIABLE + BEST_EFFORT，
            # 结果 best_effort 发布者的消息被两个订阅各收一遍 → 频率虚高近一倍
            # (鱼眼实际 30fps 报成 48.9Hz)。best_effort 订阅者能收 reliable 发布者，
            # 反之不行，所以统一用 best_effort。
            q = QoSProfile(depth=5, history=QoSHistoryPolicy.KEEP_LAST,
                           reliability=QoSReliabilityPolicy.BEST_EFFORT)
            try:
                self.create_subscription(cls, topic,
                                         lambda m, t=topic: self.cb(t, m), q)
            except Exception:                              # noqa: BLE001
                pass
            self.pubs[topic] = self.count_publishers(topic)

    def cb(self, t, m):
        self.n[t] = self.n.get(t, 0) + 1
        self.last[t] = m


def main():
    rclpy.init()
    s = Survey()
    t0 = time.time()
    while time.time() - t0 < DUR:
        rclpy.spin_once(s, timeout_sec=0.2)
    el = time.time() - t0

    print("═══ 传感器 / VIO 在线普查（%.0f 秒，纯订阅）═══" % el)
    groups = [("VIO / 里程计", 0, 6), ("运动", 6, 10), ("相机", 10, 16), ("板载传感器", 16, len(TOPICS))]
    alive = dead = 0
    for gname, a, b in groups:
        print("\n── %s ──" % gname)
        for topic, tname, minhz, sk in TOPICS[a:b]:
            cnt = s.n.get(topic, -1)
            if cnt == -1:
                print("  ⚪ %-46s 消息类型不可用(%s)" % (topic, tname))
                continue
            hz = cnt / el
            npub = s.pubs.get(topic, 0)
            if cnt > 0:
                alive += 1
                try:
                    det = SUM[sk](s.last[topic])
                except Exception as e:                     # noqa: BLE001
                    det = "(摘要失败 %r)" % e
                mark = "✅" if hz >= minhz else "⚠️"
                print("  %s %-46s %7.1f Hz  %s" % (mark, topic, hz, det))
            else:
                dead += 1
                print("  ❌ %-46s   0.0 Hz  发布者=%d %s"
                      % (topic, npub, "(有发布者但无数据)" if npub else "(无发布者)"))
    print("\n═══ 有数据 %d / 无数据 %d ═══" % (alive, dead))
    rclpy.shutdown()


if __name__ == "__main__":
    main()
