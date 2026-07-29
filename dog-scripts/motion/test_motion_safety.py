#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""安全闸门测试套件 —— 不需要狗、不需要网络、不需要电池，纯本地跑。

安全层的价值全在「真的拦得住」。每条防线都必须有一个会失败的测试证明它在工作。
运行：python3 test_motion_safety.py
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import motion_safety as ms  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print("  %s %s%s" % ("✅" if cond else "❌", name, ("  ← " + detail) if detail and not cond else ""))


def quiet(lvl, msg):
    pass


CMD = {"x_vel": 0.1, "y_vel": 0.0, "yaw_vel": 0.0}


def t_default_is_safe():
    print("\n── ① 默认状态必须是安全的 ──")
    g = ms.MotionSafetyGate(logger=quiet)
    check("默认 dry_run", g.dry_run)
    check("默认 disarmed", not g.armed)
    check("dry-run 下根本不建 socket（纵深防御）", g.status()["socket_open"] is False)
    check("默认状态下 send() 发不出去", g.send(CMD) is False)
    g.close()


def t_arm_requires_all_three():
    print("\n── ② 解除保险需要三个条件同时成立 ──")
    # dry_run=True → 拒绝
    g = ms.MotionSafetyGate(dry_run=True, owner_present=True, logger=quiet)
    check("dry-run 下拒绝 arm", g.arm(ms.MotionSafetyGate.ARM_TOKEN) is False)
    g.close()
    # owner_present=False → 拒绝（🔴 项目红线）
    g = ms.MotionSafetyGate(dry_run=False, owner_present=False, logger=quiet)
    check("机主不在场时拒绝 arm（红线）", g.arm(ms.MotionSafetyGate.ARM_TOKEN) is False)
    check("被拒后仍是 disarmed", not g.armed)
    g.close()
    # token 错 → 拒绝
    g = ms.MotionSafetyGate(dry_run=False, owner_present=True, logger=quiet)
    check("token 错误时拒绝 arm", g.arm("whatever") is False)
    check("token 正确时才 arm 成功", g.arm(ms.MotionSafetyGate.ARM_TOKEN) is True)
    check("arm 后 armed=True", g.armed)
    g.close()


def t_estop_latches():
    print("\n── ③ 急停必须锁存（不能自愈）──")
    g = ms.MotionSafetyGate(dry_run=False, owner_present=True, logger=quiet)
    g.arm(ms.MotionSafetyGate.ARM_TOKEN)
    g.estop("测试")
    check("急停后立即 disarmed", not g.armed)
    check("急停锁存中 send() 发不出去", g.send(CMD) is False)
    check("急停未清除前不能重新 arm", g.arm(ms.MotionSafetyGate.ARM_TOKEN) is False)
    check("clear_estop 后可以重新 arm",
          g.clear_estop() and g.arm(ms.MotionSafetyGate.ARM_TOKEN))
    g.close()


def t_estop_file():
    print("\n── ④ 急停文件（任何进程都能触发）──")
    fd, path = tempfile.mkstemp(prefix="estop-test-")
    os.close(fd)
    old = ms.ESTOP_FILE
    ms.ESTOP_FILE = path
    try:
        g = ms.MotionSafetyGate(dry_run=False, owner_present=True, logger=quiet)
        g.arm(ms.MotionSafetyGate.ARM_TOKEN)
        check("arm 成功（文件存在但尚未 send）", g.armed)
        sent = g.send(CMD)
        check("send() 检测到急停文件并拒发", sent is False)
        check("并且锁存了急停", g.status()["estop_latched"])
        os.unlink(path)
        check("文件删除后才能清除锁存", g.clear_estop() is True)
        g.close()
    finally:
        ms.ESTOP_FILE = old
        if os.path.exists(path):
            os.unlink(path)


def t_watchdog():
    print("\n── ⑤ 看门狗：上位机卡住必须自动上保险 ──")
    g = ms.MotionSafetyGate(dry_run=False, owner_present=True,
                            watchdog_ms=50, logger=quiet)
    g.arm(ms.MotionSafetyGate.ARM_TOKEN)
    check("刚 arm 时不会被立刻咬", g.armed)
    # 伪造"很久没发过指令"
    g._last_send_ok -= 10.0
    g.send(CMD)
    check("超时后自动 disarm", not g.armed)


def t_clamp():
    print("\n── ⑥ 限幅 ──")
    g = ms.MotionSafetyGate(max_linear=0.5, max_angular=0.5,
                            max_body_height=0.32, logger=quiet)
    safe, changed = g.clamp({"x_vel": 99.0, "y_vel": -99.0,
                             "yaw_vel": 99.0, "body_height": 99.0})
    check("线速度被限到 max_linear", safe["x_vel"] == 0.5 and safe["y_vel"] == -0.5)
    check("角速度被限到 max_angular", safe["yaw_vel"] == 0.5)
    check("机身高度被限", safe["body_height"] == 0.32)
    check("限幅会被标记", changed is True)
    safe2, changed2 = g.clamp({"x_vel": 0.1, "y_vel": 0.0, "yaw_vel": 0.0})
    check("正常值不被改动", changed2 is False and safe2["x_vel"] == 0.1)
    g.close()


def t_validate():
    print("\n── ⑦ 非法指令必须被拒且触发上保险 ──")
    g = ms.MotionSafetyGate(dry_run=False, owner_present=True, logger=quiet)
    g.arm(ms.MotionSafetyGate.ARM_TOKEN)
    check("缺字段被拒", g.send({"x_vel": 0.1}) is False)
    check("非法指令导致 disarm", not g.armed)
    g.arm(ms.MotionSafetyGate.ARM_TOKEN)
    check("NaN 被拒", g.send({"x_vel": float("nan"), "y_vel": 0.0, "yaw_vel": 0.0}) is False)
    g.arm(ms.MotionSafetyGate.ARM_TOKEN)
    check("Inf 被拒", g.send({"x_vel": float("inf"), "y_vel": 0.0, "yaw_vel": 0.0}) is False)
    g.close()


def t_encode():
    print("\n── ⑧ 编码长度必须匹配 LCM 定义 ──")
    g = ms.MotionSafetyGate(logger=quiet)
    pkt = g.encode({"x_vel": 0.1, "y_vel": 0.0, "yaw_vel": 0.2})
    check("载荷 = 8 fingerprint + 122 body = 130 字节",
          len(pkt) == 130, "实为 %d" % len(pkt))
    g.close()


def t_constants():
    print("\n── ⑨ 常量必须与实测一致 ──")
    check("指令口 = 7671", ms.PORT_SEND_TO_MOTION == 7671)
    check("TTL = 2", ms.TTL_SEND_TO_MOTION == 2)
    check("硬件力矩上限 24 N·m（实读）", ms.HW_MAX_TORQUE_NM == 24.0)
    check("默认限幅严于硬件上限",
          ms.MotionSafetyGate(logger=quiet)._max_linear < 1.0)


def main():
    print("═══ 运动安全闸门测试套件（无需狗/网络/电池）═══")
    for fn in (t_default_is_safe, t_arm_requires_all_three, t_estop_latches,
               t_estop_file, t_watchdog, t_clamp, t_validate, t_encode, t_constants):
        try:
            fn()
        except Exception as e:                       # noqa: BLE001
            FAIL.append("%s 抛异常 %r" % (fn.__name__, e))
            print("  ❌ %s 抛异常：%r" % (fn.__name__, e))
    print("\n═══ 结果：通过 %d / 失败 %d ═══" % (len(PASS), len(FAIL)))
    for f in FAIL:
        print("  ❌ %s" % f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
