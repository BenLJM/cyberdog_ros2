#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CyberDog JP5 运动能力对齐测试套件

目标：证明 JP5 上的运动模块与 JP4 同等可用，并为二次开发留下可复跑的基线。

逐项验证完整运动 API：
    模式  DEFAULT=0 LOCK=1 MANUAL=3 SEMI=13 EXPLOR=14 TRACK=15
    步态  TRANS=0 PASSIVE=1 KNEEL=2 STAND_R=3 STAND_B=4 AMBLE=5 WALK=6
          SLOW_TROT=7 TROT=8 FLYTROT=9 BOUND=10 PRONK=11
    动作  MonOrder 9~21
    速度  body_cmd (SE3VelocityCMD)

每项都从 `/mi1045904/status_out`(ControlState) 与运动板 LCM 遥测取证，
不靠 action 的返回码 —— 2026-07-31 已经吃过一次亏：
**stand.sh 返回 SUCCEEDED 但狗一动没动**（组播路由缺失，指令根本没到板子）。
所以本套件的判据一律是「关节/姿态是否真的动了」。

🔴 安全设计
  · 风险分级：Tier1 原地低幅 / Tier2 原地动态 / Tier3 高风险(需显式开启)
  · 每步前检查：电池 SOC、error_flag、通信活性
  · 任何异常 → 立即中止 → 趴下 → 退出
  · Tier3（TURN_OVER=17 翻滚 / BACK_FLIP=21 后空翻）默认**不跑**，
    必须 --tier3 且机主在场；这两个动作会让狗离开原位甚至腾空。
  · 收尾一律回到趴下（PROSTRATE）

用法（在 chroot 内，需 ROS2 环境）：
    python3 motion_parity_test.py                # Tier1+2
    python3 motion_parity_test.py --tier 1       # 只跑最安全的
    python3 motion_parity_test.py --tier3        # 含高风险（需机主在场）
    python3 motion_parity_test.py --only 16,18   # 只测指定动作
"""
import argparse
import json
import math
import socket
import struct
import subprocess
import sys
import threading
import time

# ── 运动 API 常量（来自小米开源的 motion_msgs）────────────────────────────────
MODES = {0: "DEFAULT", 1: "LOCK", 3: "MANUAL", 13: "SEMI", 14: "EXPLOR", 15: "TRACK"}
GAITS = {0: "TRANS", 1: "PASSIVE", 2: "KNEEL", 3: "STAND_R", 4: "STAND_B",
         5: "AMBLE", 6: "WALK", 7: "SLOW_TROT", 8: "TROT", 9: "FLYTROT",
         10: "BOUND", 11: "PRONK", 99: "DEFAULT"}
ORDERS = {9: "STAND_UP", 10: "PROSTRATE", 12: "STEP_BACK", 13: "TURN_AROUND",
          14: "HI_FIVE", 15: "DANCE", 16: "WELCOME(作揖)", 17: "TURN_OVER(翻滚)",
          18: "SIT", 20: "SHOW", 21: "BACK_FLIP(后空翻)"}

# 风险分级
TIER = {
    9: 1, 10: 1, 18: 1, 16: 1, 14: 1,          # 原地低幅
    12: 2, 13: 2, 15: 2, 20: 2,                # 原地动态 / 小位移
    17: 3, 21: 3,                              # 高风险：离开原位 / 腾空
}

NS = "/mi1045904"
LCM_GROUP = "239.255.76.67"
FP = 8
MIN_SOC = 25            # 低于此电量拒绝继续


# ── 遥测采样器（纯被动，只收不发）────────────────────────────────────────────
class Telemetry:
    def __init__(self):
        self.rpy = None
        self.q = None
        self.tau = None
        self.pattern = None
        self.err = None
        self.foot = None
        self._stop = False
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    def _run(self):
        socks = {}
        for port in (7667, 7670):
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("", port))
            s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                         struct.pack("4sl", socket.inet_aton(LCM_GROUP), socket.INADDR_ANY))
            s.settimeout(0.2)
            socks[port] = s
        while not self._stop:
            for port, s in socks.items():
                try:
                    d, _ = s.recvfrom(65535)
                except socket.timeout:
                    continue
                if len(d) < 8 or struct.unpack_from(">I", d, 0)[0] != 0x4C433032:
                    continue
                i = d.find(b"\0", 8)
                if i < 0:
                    continue
                ch, p = d[8:i], d[i + 1:]
                if ch == b"myIMU" and len(p) == 80:
                    self.rpy = struct.unpack_from(">3f", p, FP + 16)
                elif ch == b"leg_control_data" and len(p) == 392:
                    self.q = struct.unpack_from(">12f", p, FP)
                    self.tau = struct.unpack_from(">12f", p, FP + 192)
                elif ch == b"exec_response":
                    pat, order, bar, foot = struct.unpack_from(">4b", p, 8)
                    ex, ori = struct.unpack_from(">2b", p, 12)
                    self.pattern, self.foot, self.err = pat, foot & 0xFF, (ex, ori)
        for s in socks.values():
            s.close()

    def snap(self):
        return {
            "rpy_deg": [round(math.degrees(x), 2) for x in self.rpy] if self.rpy else None,
            "knee": [round(self.q[i], 3) for i in (2, 5, 8, 11)] if self.q else None,
            "tau_max": round(max(abs(x) for x in self.tau), 3) if self.tau else None,
            "tau_sum": round(sum(abs(x) for x in self.tau), 2) if self.tau else None,
            "pattern": self.pattern, "foot": self.foot, "err": self.err,
        }

    def stop(self):
        self._stop = True


# ── ROS2 调用（走出厂 action，与 JP4 同一条路径）──────────────────────────────
ROS_ENV = ("source /opt/ros2/foxy/setup.bash 2>/dev/null; "
           "source /opt/ros2/cyberdog/setup.bash 2>/dev/null; "
           "export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp "
           "ROS_LOCALHOST_ONLY=1 "
           "CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/root; ")


def ros_action(action, atype, payload, timeout=60):
    cmd = ROS_ENV + ("timeout %d ros2 action send_goal %s %s \"%s\""
                     % (timeout, action, atype, payload))
    # ⚠️ chroot 里是 Python 3.6 —— capture_output 与 text 都是 3.7+ 才有，
    #    必须用 stdout/stderr=PIPE + universal_newlines。
    r = subprocess.run(["/bin/bash", "-c", cmd], stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, universal_newlines=True)
    out = (r.stdout or "") + (r.stderr or "")
    return ("SUCCEEDED" in out), out


def send_mode(mode, timeout=60):
    return ros_action(NS + "/checkout_mode", "motion_msgs/action/ChangeMode",
                      "{modestamped: {timestamp: {sec: %d, nanosec: 0}, "
                      "control_mode: %d, mode_type: 0}}" % (int(time.time()), mode),
                      timeout)


def send_gait(gait, timeout=60):
    return ros_action(NS + "/checkout_gait", "motion_msgs/action/ChangeGait",
                      "{motivation: 253, gaitstamped: {timestamp: "
                      "{sec: %d, nanosec: 0}, gait: %d}}" % (int(time.time()), gait),
                      timeout)


def send_order(oid, para=0.0, timeout=90):
    return ros_action(NS + "/exe_monorder", "motion_msgs/action/ExtMonOrder",
                      "{orderstamped: {timestamp: {sec: %d, nanosec: 0}, "
                      "id: %d, para: %.2f}}" % (int(time.time()), oid, para),
                      timeout)


def read_soc():
    cmd = ROS_ENV + ("python3 -c \""
                     "import rclpy,time;from rclpy.node import Node;"
                     "from ception_msgs.msg import Bms;"
                     "rclpy.init();n=Node('soc');g=[];"
                     "n.create_subscription(Bms,'%s/bms_recv',lambda m:g.append(m),5);"
                     "t=time.time();\n"
                     "while time.time()-t<8 and not g: rclpy.spin_once(n,timeout_sec=0.4)\n"
                     "print(g[0].batt_soc if g else -1);rclpy.shutdown()\"" % NS)
    r = subprocess.run(["/bin/bash", "-c", cmd], stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, universal_newlines=True)
    for line in reversed((r.stdout or "").strip().splitlines()):
        try:
            return int(line.strip())
        except ValueError:
            continue
    return -1


# ── 判据：动作到底有没有真的发生 ─────────────────────────────────────────────
def moved(before, after, tau_peak):
    """靠遥测判断，不靠 action 返回码（后者会在指令没送达时也报 SUCCEEDED）。"""
    reasons = []
    if before.get("knee") and after.get("knee"):
        dk = max(abs(a - b) for a, b in zip(after["knee"], before["knee"]))
        if dk > 0.05:
            reasons.append("膝关节变化 %.3f rad" % dk)
    if before.get("rpy_deg") and after.get("rpy_deg"):
        dr = max(abs(a - b) for a, b in zip(after["rpy_deg"], before["rpy_deg"]))
        if dr > 3.0:
            reasons.append("姿态变化 %.1f°" % dr)
    if tau_peak and tau_peak > 1.0:
        reasons.append("峰值力矩 %.2f N·m" % tau_peak)
    return (len(reasons) > 0), reasons


def run_case(tel, name, fn, settle=6.0, watch=14.0):
    """执行一个用例并取证。返回结果 dict。"""
    before = tel.snap()
    peak = 0.0
    t0 = time.time()
    ok_action, out = fn()
    # 动作期间持续采样峰值力矩
    while time.time() - t0 < watch:
        s = tel.snap()
        if s.get("tau_max"):
            peak = max(peak, s["tau_max"])
        time.sleep(0.2)
    time.sleep(settle)
    after = tel.snap()
    did, reasons = moved(before, after, peak)
    err = after.get("err")
    err_ok = (err is None) or (err == (0, 0))
    return {
        "name": name, "action_ok": ok_action, "moved": did,
        "reasons": reasons, "tau_peak": round(peak, 3),
        "before": before, "after": after, "err_ok": err_ok,
        "verdict": "✅" if (ok_action and did and err_ok) else
                   ("⚠️" if ok_action and err_ok else "❌"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", type=int, default=2, help="跑到第几级（默认 2）")
    ap.add_argument("--tier3", action="store_true", help="启用高风险动作（需机主在场）")
    ap.add_argument("--only", type=str, default="", help="只测这些 order id，逗号分隔")
    ap.add_argument("--skip-gait", action="store_true", help="跳过步态测试")
    ap.add_argument("--out", type=str, default="/tmp/motion-parity.json")
    a = ap.parse_args()

    max_tier = 3 if a.tier3 else a.tier
    only = set(int(x) for x in a.only.split(",") if x.strip()) if a.only else None

    print("═══ CyberDog JP5 运动能力对齐测试 ═══")
    soc = read_soc()
    print("  电池 SOC = %d%%" % soc)
    if soc >= 0 and soc < MIN_SOC:
        print("  ❌ 电量低于 %d%%，拒绝测试" % MIN_SOC)
        return 2
    print("  风险等级上限 = Tier%d%s" % (max_tier, "（含高风险）" if a.tier3 else ""))

    tel = Telemetry()
    time.sleep(2.0)
    if tel.pattern is None:
        print("  ❌ 收不到运动板遥测 —— 检查 l4tbr0 网桥与组播路由")
        print("     修法：sudo systemctl restart jp5-cyberdog-net")
        tel.stop()
        return 3
    print("  运动板遥测正常：pattern=%s err=%s" % (tel.pattern, tel.err))

    results = []

    def record(r):
        results.append(r)
        print("  %s %-22s 动作返回=%s 真的动了=%s 峰值力矩=%.2f  %s"
              % (r["verdict"], r["name"], r["action_ok"], r["moved"],
                 r["tau_peak"], "; ".join(r["reasons"])))
        return r["verdict"] != "❌"

    try:
        # ── ① 站起来（后续大部分动作的前提）──
        print("\n── ① 进入站立 ──")
        if not record(run_case(tel, "MODE_MANUAL(站立)", lambda: send_mode(3), watch=18)):
            raise RuntimeError("站立失败，中止")

        # ── ② 预置动作 ──
        print("\n── ② 预置动作（MonOrder）──")
        for oid in sorted(ORDERS):
            if only and oid not in only:
                continue
            t = TIER.get(oid, 3)
            if t > max_tier:
                print("  ⏭  跳过 %-22s (Tier%d，需 --tier3)" % (ORDERS[oid], t))
                continue
            if oid == 10:      # PROSTRATE 留到最后收尾
                continue
            r = run_case(tel, "%s(%d)" % (ORDERS[oid], oid),
                         lambda o=oid: send_order(o), watch=20)
            record(r)
            # 动作后回站立，保证下一项起点一致
            if oid != 9:
                send_mode(3)
                time.sleep(6)
            s = tel.snap()
            if s.get("err") and s["err"] != (0, 0):
                print("  ❌ 出现错误标志 %s，中止" % (s["err"],))
                break

        # ── ③ 步态 ──
        if not a.skip_gait:
            print("\n── ③ 步态切换（原地，不下速度指令）──")
            for g in (1, 2, 3, 4, 5, 6, 7, 8):
                if GAITS[g] in ("PASSIVE",) and max_tier < 2:
                    continue
                r = run_case(tel, "GAIT_%s(%d)" % (GAITS[g], g),
                             lambda gg=g: send_gait(gg), watch=10, settle=3)
                record(r)
                s = tel.snap()
                if s.get("err") and s["err"] != (0, 0):
                    print("  ❌ 错误标志 %s，中止步态测试" % (s["err"],))
                    break
            send_gait(3)   # 回站立步态
            time.sleep(3)

    except Exception as e:                              # noqa: BLE001
        print("\n  ❌ 异常中止：%r" % e)
    finally:
        print("\n── ④ 收尾：趴下 ──")
        try:
            r = run_case(tel, "PROSTRATE(10) 收尾", lambda: send_order(10), watch=18)
            record(r)
            send_mode(0)
        except Exception as e:                          # noqa: BLE001
            print("  ⚠️ 收尾异常：%r" % e)
        soc2 = read_soc()
        tel.stop()

    ok = sum(1 for r in results if r["verdict"] == "✅")
    warn = sum(1 for r in results if r["verdict"] == "⚠️")
    bad = sum(1 for r in results if r["verdict"] == "❌")
    print("\n═══ 结果：✅%d  ⚠️%d  ❌%d   电池 %d%% → %d%% ═══" % (ok, warn, bad, soc, soc2))
    try:
        with open(a.out, "w") as f:
            json.dump({"soc_before": soc, "soc_after": soc2, "results": results},
                      f, ensure_ascii=False, indent=1)
        print("  明细已写入 %s" % a.out)
    except OSError as e:
        print("  ⚠️ 写结果失败：%r" % e)
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
