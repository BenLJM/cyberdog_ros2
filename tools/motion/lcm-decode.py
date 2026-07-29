#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CyberDog 运动板 LCM 遥测解码器 —— **纯被动，只收不发**。

2026-07-29 实测：运动板（192.168.55.233）即使在**没有电池**的情况下，
仍以 500Hz 控制周期 / 1kHz IMU 全速播送完整遥测。这意味着运动控制的
「读」侧完全可以在电池到货前做完并用真实数据验证。

实测频道（10 秒被动监听）：
    myIMU                       1009.9 Hz   80 B
    leg_control_data             499.9 Hz  392 B   ← 12 关节位置/速度/力矩
    leg_control_command          499.9 Hz  488 B   ← 下发给腿的指令
    spi_data / spi_command       499.9 Hz  204/264 B
    motion_control_cmd           499.9 Hz   52 B
    global_to_robot              499.9 Hz   56 B
    main_cheetah_visualization    59.9 Hz  100 B

类型定义来自小米自己开源的 cyberdog_ros2：
    cyberdog_interfaces/lcm_translate_msgs/lcm_type/*.lcm
字节数交叉验证全部精确吻合（载荷 = 8 字节 fingerprint + 大端字段）：
    microstrain 72+8=80 ✅ / leg_control_data 384+8=392 ✅ / spi_data 196+8=204 ✅

🔴 安全：本工具**只 recvfrom，从不 sendto**。它加入组播组是只读行为，
   不会对运动板产生任何影响，也不会触发任何电机动作。

用法：
    sudo python3 lcm-decode.py [秒数]        # 默认 5 秒
    sudo python3 lcm-decode.py 5 --raw       # 附带原始字节（调试用）
"""
import collections
import math
import socket
import struct
import sys
import time

GROUP = "239.255.76.67"
PORT = 7667
MAGIC_SHORT = 0x4C433032          # "LC02"
MAGIC_FRAG = 0x4C433033           # "LC03"
FP = 8                            # LCM fingerprint 长度

# CyberDog 腿序与关节序（MIT Cheetah 约定）
LEGS = ["右前 FR", "左前 FL", "右后 RR", "左后 RL"]
JOINTS = ["abad(侧摆)", "hip(髋)", "knee(膝)"]


def f32(buf, off, n):
    """大端 float 数组"""
    return list(struct.unpack_from(">%df" % n, buf, off)), off + 4 * n


def i32(buf, off, n):
    return list(struct.unpack_from(">%di" % n, buf, off)), off + 4 * n


def dec_microstrain(p):
    """microstrain_lcmt: quat[4] rpy[3] omega[3] acc[3] temp good bad"""
    o = FP
    quat, o = f32(p, o, 4)
    rpy, o = f32(p, o, 3)
    omega, o = f32(p, o, 3)
    acc, o = f32(p, o, 3)
    temp, o = f32(p, o, 1)
    good, bad = struct.unpack_from(">qq", p, o)
    return dict(quat=quat, rpy=rpy, omega=omega, acc=acc,
                temp=temp[0], good=good, bad=bad)


def dec_leg_control_data(p):
    """leg_control_data_lcmt: q qd p v tau_est force_est force_desired [12 each]
       + q_abad_limit[4] q_hip_limit[4] q_knee_limit[4] (int32)"""
    o = FP
    out = {}
    for k in ("q", "qd", "p", "v", "tau_est", "force_est", "force_desired"):
        out[k], o = f32(p, o, 12)
    for k in ("q_abad_limit", "q_hip_limit", "q_knee_limit"):
        out[k], o = i32(p, o, 4)
    return out


def dec_spi_data(p):
    """spi_data_t: q_abad[4] q_hip[4] q_knee[4] qd_*[4]x3 flags[12]
       spi_driver_status tau_*[4]x3"""
    o = FP
    out = {}
    for k in ("q_abad", "q_hip", "q_knee", "qd_abad", "qd_hip", "qd_knee"):
        out[k], o = f32(p, o, 4)
    out["flags"], o = i32(p, o, 12)
    out["spi_driver_status"], o = i32(p, o, 1)
    out["spi_driver_status"] = out["spi_driver_status"][0]
    for k in ("tau_abad", "tau_hip", "tau_knee"):
        out[k], o = f32(p, o, 4)
    return out


DECODERS = {
    "myIMU": ("microstrain_lcmt", 80, dec_microstrain),
    "leg_control_data": ("leg_control_data_lcmt", 392, dec_leg_control_data),
    "spi_data": ("spi_data_t", 204, dec_spi_data),
}


def main():
    dur = 5.0
    show_raw = "--raw" in sys.argv
    for a in sys.argv[1:]:
        if not a.startswith("-"):
            try:
                dur = float(a)
            except ValueError:
                pass

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", PORT))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                 struct.pack("4sl", socket.inet_aton(GROUP), socket.INADDR_ANY))
    s.settimeout(1.0)
    # 显式关掉组播回环并**不设置任何发送路径** —— 本进程永不 sendto
    try:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    except OSError:
        pass

    counts = collections.Counter()
    latest = {}
    sizes = {}
    bad_size = collections.Counter()
    t0 = time.time()
    while time.time() - t0 < dur:
        try:
            data, _ = s.recvfrom(65535)
        except socket.timeout:
            continue
        if len(data) < 8 or struct.unpack_from(">I", data, 0)[0] != MAGIC_SHORT:
            continue
        i = data.find(b"\0", 8)
        if i < 0:
            continue
        ch = data[8:i].decode("utf-8", "replace")
        payload = data[i + 1:]
        counts[ch] += 1
        sizes[ch] = len(payload)
        if ch in DECODERS:
            _, want, fn = DECODERS[ch]
            if len(payload) != want:
                bad_size[ch] += 1
                continue
            try:
                latest[ch] = fn(payload)
                if show_raw:
                    latest[ch]["_raw16"] = payload[:16].hex()
            except Exception as e:                       # noqa: BLE001
                bad_size[ch] += 1
                latest[ch] = {"错误": repr(e)}
    el = time.time() - t0

    print("═══ 被动监听 %.1f 秒（全程只收不发）═══" % el)
    print("── 频道 ──")
    for ch, n in counts.most_common():
        tag = ""
        if ch in DECODERS:
            tag = "  [%s%s]" % (DECODERS[ch][0],
                                " ⚠️长度不符×%d" % bad_size[ch] if bad_size[ch] else " ✅")
        print("   %-30s %7.1f Hz  %4d B%s" % (ch, n / el, sizes.get(ch, 0), tag))

    imu = latest.get("myIMU")
    if imu and "错误" not in imu:
        r, p_, y = [math.degrees(v) for v in imu["rpy"]]
        ax, ay, az = imu["acc"]
        print("\n── IMU（microstrain_lcmt）──")
        print("   姿态 roll=%+7.2f° pitch=%+7.2f° yaw=%+7.2f°" % (r, p_, y))
        print("   角速度 %+.3f %+.3f %+.3f rad/s" % tuple(imu["omega"]))
        print("   加速度 %+.3f %+.3f %+.3f  (合模 %.3f，静止应≈9.8 m/s²)"
              % (ax, ay, az, math.sqrt(ax * ax + ay * ay + az * az)))
        print("   温度 %.1f°C   好包 %d / 坏包 %d" % (imu["temp"], imu["good"], imu["bad"]))

    leg = latest.get("leg_control_data")
    if leg and "错误" not in leg:
        print("\n── 12 关节实时状态（leg_control_data_lcmt）──")
        print("   %-10s %-12s %9s %9s %9s" % ("腿", "关节", "位置 rad", "速度 rad/s", "力矩 Nm"))
        for li, lname in enumerate(LEGS):
            for ji, jname in enumerate(JOINTS):
                k = li * 3 + ji
                print("   %-10s %-12s %+9.4f %+9.4f %+9.4f"
                      % (lname if ji == 0 else "", jname,
                         leg["q"][k], leg["qd"][k], leg["tau_est"][k]))
        print("   关节限位标志 abad=%s hip=%s knee=%s"
              % (leg["q_abad_limit"], leg["q_hip_limit"], leg["q_knee_limit"]))

    spi = latest.get("spi_data")
    if spi and "错误" not in spi:
        print("\n── SPI 驱动层（spi_data_t）──")
        print("   spi_driver_status=%d  flags=%s" % (spi["spi_driver_status"], spi["flags"]))
        print("   abad 位置 %s" % ["%+.3f" % v for v in spi["q_abad"]])
        print("   hip  位置 %s" % ["%+.3f" % v for v in spi["q_hip"]])
        print("   knee 位置 %s" % ["%+.3f" % v for v in spi["q_knee"]])

    print("\n（本工具从未调用过 sendto —— 对运动板零影响）")


if __name__ == "__main__":
    main()
