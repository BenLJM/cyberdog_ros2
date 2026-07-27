#!/usr/bin/env python3
# =============================================================================
#  CyberDog 传感器开机自动使能  —— chroot(JP4 rootfs) 内执行体
#  部署路径: /mnt/jp4/home/mi/cyberdog-sensor-enable.py  (0755)
#  调用者:   JP5 host 的 /usr/local/bin/cyberdog-sensors-enable.sh
#
#  ─── 为什么需要这个东西 ────────────────────────────────────────────────────
#  超声/ToF/光流/光线这些板载传感器**出厂默认是静默的**：MCU 侧 enable_count=0,
#  必须有人调 SensorDetectionNode 服务把它点亮。
#  而整个开源 cyberdog_ros2 树里**没有任何节点会去发这个请求** ——
#  decision_maker/src/motion_manager.cpp 建了 ob_detect_client_ 这个 client,
#  但全树没有一次 async_send_request。真正会发的是**闭源的手机 App**。
#  => 不做动作的话, 这些传感器在 JP5 上永远是黑的。这不是移植缺陷, 是缺了 App。
#
#  ─── 实测 A/B(2026-07-27, 这不是推理) ──────────────────────────────────────
#      /ObstacleDetection   使能前 0.00 Hz  ->  使能后 9.58 Hz(真回波 0.2227m)
#      /BodyState           使能前 0.00 Hz  ->  使能后 23.87 Hz
#
#  ─── 一个已知的取舍 ────────────────────────────────────────────────────────
#  我们用 timeout=COMMAND_ALWAYSON 注册成一个常驻 client。服务端是引用计数语义
#  (clientcount), 只要还有一个 client 要求开着就不会关。也就是说手机 App 之后
#  **关不掉**这些传感器了。对一条要做避障的狗来说这是想要的行为, 而且功耗可忽略;
#  如果哪天需要让 App 能关, 把 clientid 那一路 DISABLE 一次即可(见 --disable)。
# =============================================================================
import argparse
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile

from ception_msgs.msg import Around, BodyState
from ception_msgs.srv import SensorDetectionNode

# SensorDetectionNode.srv 里的命令常量
ENABLE_ALL = 4
DISABLE_ALL = 5
ENABLE_ROTATION_VECTOR = 50
DISABLE_ROTATION_VECTOR = 51
ENABLE_SPEED_VECTOR = 52
DISABLE_SPEED_VECTOR = 53
ALWAYSON = 0xFFFFFFFFFFFFFFFF

# (服务名, [命令...], 验收话题, 话题类型, 期望最低 Hz)
GROUPS = [
    ("obstacle_detection", [ENABLE_ALL], "ObstacleDetection", Around, 1.0),
    ("athena_body_state", [ENABLE_ROTATION_VECTOR, ENABLE_SPEED_VECTOR], "BodyState", BodyState, 1.0),
]
DISABLE_MAP = {
    ENABLE_ALL: DISABLE_ALL,
    ENABLE_ROTATION_VECTOR: DISABLE_ROTATION_VECTOR,
    ENABLE_SPEED_VECTOR: DISABLE_SPEED_VECTOR,
}


def measure(node, topic, msgtype, secs):
    """数指定话题在 secs 秒里的消息数, 返回 Hz。"""
    c = {"n": 0}
    sub = node.create_subscription(msgtype, topic, lambda m: c.__setitem__("n", c["n"] + 1),
                                   QoSProfile(depth=10))
    t0 = time.time()
    while time.time() - t0 < secs:
        rclpy.spin_once(node, timeout_sec=0.05)
    el = time.time() - t0
    node.destroy_subscription(sub)
    return c["n"] / el if el > 0 else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ns", default="/mi1045904")
    ap.add_argument("--clientid", type=int, default=9,
                    help="服务端按它区分调用方; 数字越小优先级越高。用 9 避免和出厂 client 撞车")
    ap.add_argument("--wait", type=float, default=180.0, help="等服务出现的上限(秒)")
    ap.add_argument("--verify-secs", type=float, default=6.0)
    ap.add_argument("--disable", action="store_true", help="撤销本 clientid 的使能")
    args = ap.parse_args()

    rclpy.init()
    node = Node("cyberdog_sensor_enable")
    ns = args.ns.rstrip("/")
    failures = []

    for svc, cmds, topic, msgtype, min_hz in GROUPS:
        full_svc = "%s/%s" % (ns, svc)
        full_topic = "%s/%s" % (ns, topic)
        cli = node.create_client(SensorDetectionNode, full_svc)

        # 栈冷启动时这些节点要几十秒才 active, 必须耐心等
        t0 = time.time()
        ok = False
        while time.time() - t0 < args.wait:
            if cli.wait_for_service(timeout_sec=2.0):
                ok = True
                break
        if not ok:
            print("FAIL %s: service never appeared within %.0fs" % (full_svc, args.wait))
            failures.append(svc)
            continue

        for cmd in cmds:
            if args.disable:
                cmd = DISABLE_MAP.get(cmd, cmd)
            req = SensorDetectionNode.Request()
            req.command = cmd
            req.clientid = args.clientid
            req.priority = 1
            req.timeout = 0 if args.disable else ALWAYSON
            fut = cli.call_async(req)
            rclpy.spin_until_future_complete(node, fut, timeout_sec=25.0)
            res = fut.result() if fut.done() else None
            if res is None:
                print("FAIL %s cmd=%d: no response" % (svc, cmd))
                failures.append(svc)
            else:
                print("OK   %s cmd=%d -> success=%s clientcount=%s"
                      % (svc, cmd, res.success, res.clientcount))

        if args.disable:
            continue

        # ---- 自验收: 光有 success=True 不算数, 要看话题真的开始出数 ----------
        hz = measure(node, full_topic, msgtype, args.verify_secs)
        if hz >= min_hz:
            print("OK   %s -> %.2f Hz" % (full_topic, hz))
        else:
            print("FAIL %s -> %.2f Hz (期望 >= %.1f)" % (full_topic, hz, min_hz))
            failures.append(topic)

    node.destroy_node()
    rclpy.shutdown()

    if failures:
        print("RESULT: FAILED (%s)" % ", ".join(sorted(set(failures))))
        return 1
    print("RESULT: all sensor groups enabled and verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
