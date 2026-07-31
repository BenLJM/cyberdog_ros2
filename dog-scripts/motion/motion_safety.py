#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CyberDog 运动指令安全闸门（motion safety gate）

════════════════════════════════════════════════════════════════════════════
这是**唯一**被允许往运动板指令口发包的组件。任何要让狗动的代码都必须经过它。
════════════════════════════════════════════════════════════════════════════

为什么需要它（不是形式主义）：
  · 这是一台十几公斤、12 个力控关节的机器，**单关节最大力矩 24 N·m**
    （2026-07-29 从运动板遥测里实读到的 tau 限值），而且**没有硬件急停**。
  · 官方 `cyberdog_locomotion` README 原文：「只在铁蛋2代上进行了充分测试。
    对于铁蛋1代…未经充分测试，请谨慎使用!」
  · 运动板固件是 Dreame 加密的，**刷坏没有任何软件手段能救回来**。

闸门位置（2026-07-30 从小米开源的 `default_param.yaml` 实测确定）：
  · `port_send_to_motion = 7671`  TTL 2   ← 上位机→运动板，**本模块闸住的就是它**
  · `port_recv_from_motion = 7670` TTL 1  ← 只读，不经本模块
  · `timeout_motion_ms = 333`             ← 出厂自带的运动超时（我们的看门狗更严）

设计原则：**失效即安全（fail-safe）**
  1. 默认 `dry_run=True` 且 `armed=False`——**开箱即用是打不出去的**。
  2. dry-run 模式下**根本不创建 socket**（纵深防御：就算逻辑写错也发不出去）。
  3. 任何不确定 → 不发。异常 → 立即 disarm。
  4. 解除保险需要**三个条件同时成立**：非 dry-run、显式 arm() 带正确 token、
     机主在场确认标志。少一个都发不出去。
  5. 看门狗：超过 `watchdog_ms` 没有新指令 → 自动 disarm（防上位机卡死后狗继续跑）。
  6. 急停：`estop()` 或急停文件出现 → 立即 disarm 且**需要人工清除才能再 arm**。

🔴 红线（写死在代码里，不是注释）：
   本模块**不提供**任何"一键上电走路"的便捷入口。arm() 必须显式调用并带 token。
"""

import errno
import os
import socket
import struct
import time

# ── 常量：全部来自实测，改动前请回读 PORT-STATUS.md ───────────────────────────
MOTION_GROUP = "239.255.76.67"      # LCM 默认组播组
PORT_SEND_TO_MOTION = 7671          # 🔴 指令口（default_param.yaml 实测）
TTL_SEND_TO_MOTION = 2
PORT_RECV_FROM_MOTION = 7670        # 只读口，本模块不碰
FACTORY_TIMEOUT_MS = 333            # 出厂自带运动超时（参考值）

# 关节能力上限（2026-07-29 从运动板遥测实读到的限值，作为绝对不可超越的天花板）
HW_MAX_TORQUE_NM = 24.0
HW_MAX_JOINT_VEL = 45.0

ESTOP_FILE = "/run/cyberdog-motion-estop"   # 存在即急停；任何进程都能 touch 它


class SafetyViolation(Exception):
    """指令被闸门拒绝。"""


class MotionSafetyGate:
    """运动指令安全闸门。**唯一**允许写 7671 的地方。

    典型用法::

        gate = MotionSafetyGate()            # 默认 dry-run + disarmed
        gate.send(cmd)                       # → 只记录，不发送，返回 False

        # 要真发，必须三个条件同时成立：
        gate = MotionSafetyGate(dry_run=False, owner_present=True)
        gate.arm(token="I-AM-PRESENT")       # token 必须完全匹配
        gate.send(cmd)                       # → 真发，返回 True
    """

    ARM_TOKEN = "I-AM-PRESENT"          # 刻意做成需要手打的字符串，防手滑

    def __init__(self, dry_run=True, owner_present=False,
                 watchdog_ms=200, max_linear=0.5, max_angular=0.5,
                 max_body_height=0.32, logger=None):
        # ── 状态 ──
        self._dry_run = bool(dry_run)
        self._owner_present = bool(owner_present)
        self._armed = False
        self._estop_latched = False
        self._estop_reason = ""
        self._last_send_ok = 0.0
        self._seq = 0

        # ── 限幅（保守值；不是硬件极限，是"我们允许的"）──
        self._watchdog_s = max(0.05, watchdog_ms / 1000.0)
        self._max_linear = float(max_linear)        # m/s
        self._max_angular = float(max_angular)      # rad/s
        self._max_body_height = float(max_body_height)  # m

        self._log = logger or (lambda lvl, msg: print("[gate:%s] %s" % (lvl, msg)))

        # ── 纵深防御：dry-run 下**根本不建 socket** ──
        self._sock = None
        if not self._dry_run:
            self._open_socket()

        self._log("info",
                  "闸门就绪 dry_run=%s owner_present=%s armed=%s "
                  "限幅 lin=%.2fm/s ang=%.2frad/s h=%.2fm 看门狗=%dms"
                  % (self._dry_run, self._owner_present, self._armed,
                     self._max_linear, self._max_angular,
                     self._max_body_height, watchdog_ms))

    # ── socket ──────────────────────────────────────────────────────────────
    def _open_socket(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL,
                     struct.pack("b", TTL_SEND_TO_MOTION))
        self._sock = s

    # ── 状态查询 ────────────────────────────────────────────────────────────
    @property
    def armed(self):
        return self._armed and not self._estop_latched

    @property
    def dry_run(self):
        return self._dry_run

    def status(self):
        return {
            "armed": self._armed,
            "dry_run": self._dry_run,
            "owner_present": self._owner_present,
            "estop_latched": self._estop_latched,
            "estop_reason": self._estop_reason,
            "socket_open": self._sock is not None,
            "seq": self._seq,
        }

    # ── 保险 ────────────────────────────────────────────────────────────────
    def arm(self, token):
        """解除保险。三个条件缺一不可，且急停必须先被人工清除。"""
        if self._estop_latched:
            self._log("error", "拒绝 arm：急停已锁存（%s），需先 clear_estop()"
                      % self._estop_reason)
            return False
        if self._dry_run:
            self._log("error", "拒绝 arm：处于 dry-run 模式（socket 都没建）")
            return False
        if not self._owner_present:
            self._log("error", "拒绝 arm：owner_present=False。"
                               "🔴 项目红线：任何可能动电机的指令必须机主在场")
            return False
        if token != self.ARM_TOKEN:
            self._log("error", "拒绝 arm：token 不匹配")
            return False
        self._armed = True
        self._last_send_ok = time.monotonic()   # 起点，避免刚 arm 就被看门狗咬
        self._log("warn", "⚠️ 已解除保险 —— 指令现在会真的发到运动板 7671")
        return True

    def disarm(self, reason="手动"):
        if self._armed:
            self._log("warn", "已上保险：%s" % reason)
        self._armed = False

    def estop(self, reason="手动急停"):
        """急停：立即上保险并**锁存**，必须人工 clear 才能再 arm。"""
        self._estop_latched = True
        self._estop_reason = reason
        self._armed = False
        self._log("error", "🛑 急停锁存：%s" % reason)

    def clear_estop(self):
        """人工清除急停锁存。刻意不自动清除。"""
        if os.path.exists(ESTOP_FILE):
            self._log("error", "拒绝清除：急停文件仍存在 %s" % ESTOP_FILE)
            return False
        self._estop_latched = False
        self._estop_reason = ""
        self._log("info", "急停锁存已清除（仍需重新 arm）")
        return True

    # ── 检查链 ──────────────────────────────────────────────────────────────
    def _check_estop_file(self):
        try:
            if os.path.exists(ESTOP_FILE) and not self._estop_latched:
                self.estop("检测到急停文件 %s" % ESTOP_FILE)
        except OSError:
            # 连文件系统都读不了 → 保守处理
            self.estop("急停文件检查失败")

    def _check_watchdog(self):
        if not self._armed:
            return
        idle = time.monotonic() - self._last_send_ok
        if idle > self._watchdog_s:
            self.disarm("看门狗：%.0fms 没有新指令（阈值 %.0fms）"
                        % (idle * 1000, self._watchdog_s * 1000))

    def clamp(self, cmd):
        """限幅。返回 (限幅后的 cmd, 是否被改过)。**不抛异常** —— 限幅是常规操作。"""
        out = dict(cmd)
        changed = False

        def _cl(key, lo, hi):
            nonlocal changed
            if key in out:
                v = out[key]
                c = max(lo, min(hi, v))
                if c != v:
                    changed = True
                out[key] = c

        _cl("x_vel", -self._max_linear, self._max_linear)
        _cl("y_vel", -self._max_linear, self._max_linear)
        _cl("yaw_vel", -self._max_angular, self._max_angular)
        _cl("body_height", 0.0, self._max_body_height)
        return out, changed

    def validate(self, cmd):
        """结构与数值合法性。不合法直接拒（不试图"修好"）。"""
        for k in ("x_vel", "y_vel", "yaw_vel"):
            if k not in cmd:
                raise SafetyViolation("指令缺字段 %s" % k)
        for k, v in cmd.items():
            if isinstance(v, float):
                if v != v or v in (float("inf"), float("-inf")):
                    raise SafetyViolation("字段 %s 是 NaN/Inf" % k)
        return True

    # ── 发送 ────────────────────────────────────────────────────────────────
    def send(self, cmd):
        """经过全部检查后发送。返回 True 表示**真的发出去了**。

        任何一个检查不过 → 返回 False（dry-run 下永远返回 False）。
        """
        self._check_estop_file()
        self._check_watchdog()

        try:
            self.validate(cmd)
        except SafetyViolation as e:
            self._log("error", "指令被拒：%s" % e)
            self.disarm("收到非法指令")
            return False

        safe, changed = self.clamp(cmd)
        if changed:
            self._log("warn", "指令已限幅：%s → %s" % (cmd, safe))

        if self._estop_latched:
            self._log("error", "未发送：急停锁存中")
            return False
        if self._dry_run:
            self._log("info", "[DRY-RUN] 本应发送 → %s" % safe)
            return False
        if not self._armed:
            self._log("info", "未发送：未解除保险（disarmed）")
            return False
        if self._sock is None:
            self._log("error", "未发送：socket 未建（不应发生）")
            self.estop("内部状态不一致：armed 但无 socket")
            return False

        try:
            pkt = self.encode(safe)
            self._sock.sendto(pkt, (MOTION_GROUP, PORT_SEND_TO_MOTION))
            self._last_send_ok = time.monotonic()
            self._seq += 1
            return True
        except OSError as e:
            self._log("error", "发送失败 errno=%s：%s" % (errno.errorcode.get(e.errno), e))
            self.estop("发送失败")
            return False

    # ── 编码 ────────────────────────────────────────────────────────────────
    # motion_control_request_lcmt（小米开源的 lcm_type/motion_control_lcmt.lcm）：
    #   int8 pattern; double linear[3]; double angular[3]; double point[3];
    #   double quaternion[4]; double body_height; double gait_height; int8 order;
    # = 1+24+24+24+32+8+8+1 = 122 字节，+8 字节 fingerprint = 130
    # fingerprint（2026-07-31 实测确定，双向印证）：
    #   · 从出厂 exec_request 活流量抓到 0x9724331e99b7d072（181 个样本完全一致）
    #   · 出厂头文件 motion_control_request_lcmt.hpp 里的 base hash 是
    #     0x4b92198f4cdbe839，而 LCM 的 _computeHash 规则是「左移 1 位」：
    #       0x4b92198f4cdbe839 << 1 == 0x9724331e99b7d072  ✅ 逐位吻合
    #   两条独立来源互证，可以放心使用。
    LCM_FINGERPRINT = bytes.fromhex("9724331e99b7d072")

    def encode(self, cmd):
        """编成 motion_control_request_lcmt 的 LCM 载荷（大端）。"""
        body = struct.pack(
            ">b" "3d" "3d" "3d" "4d" "d" "d" "b",
            int(cmd.get("pattern", 0)),
            float(cmd.get("x_vel", 0.0)), float(cmd.get("y_vel", 0.0)), 0.0,
            0.0, 0.0, float(cmd.get("yaw_vel", 0.0)),
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0,
            float(cmd.get("body_height", 0.0)),
            float(cmd.get("gait_height", 0.0)),
            int(cmd.get("order", 0)),
        )
        assert len(body) == 122, "载荷应为 122 字节，实为 %d" % len(body)
        return self.LCM_FINGERPRINT + body

    def close(self):
        self.disarm("闸门关闭")
        if self._sock is not None:
            self._sock.close()
            self._sock = None
