#!/usr/bin/env python3
# =============================================================================
#  GPS 串口活性探针（JP5 宿主侧，纯 stdlib，不需要 ROS）
#  部署路径: /usr/local/bin/gps-serial-probe.py
#
#  ⚠️ 重要前提: 出厂的 service_scene_detection **持有并正在读** /dev/ttyTHS0。
#  本探针会和它抢字节 —— 所以看到的是"采样",不是完整流。
#  因此判据只用**统计特征**(有没有 Bream 帧同步头 / 有没有 NMEA 片段),
#  绝不去尝试解析完整帧。抢走的那点字节对 Bream 无害(它靠 0xB5 0x62 重同步)。
#
#  Bream(博通) 协议是 UBX 派生的: 每帧以 0xB5 0x62 开头, 随后 class/id/len。
#    class 0x04 = INF(日志文本)   class 0xF0 = NMEA 类
# =============================================================================
import collections
import os
import sys
import termios
import time

DEV = "/dev/ttyTHS0"
SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0


def open_ro(dev):
    fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    # 只改本地/输入语义, **不动波特率** —— 出厂设的 3000000 是对的, 别去"修"它
    a[0] = 0                      # iflag: 不做任何转换
    a[3] = 0                      # lflag: 非规范模式
    a[6] = list(a[6])
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def main():
    if not os.path.exists(DEV):
        print("FAIL %s does not exist" % DEV)
        return 1

    try:
        fd = open_ro(DEV)
    except OSError as e:
        print("FAIL cannot open %s: %s" % (DEV, e))
        return 1

    buf = bytearray()
    total = 0
    t0 = time.time()
    while time.time() - t0 < SECS:
        try:
            c = os.read(fd, 4096)
        except OSError:
            time.sleep(0.02)
            continue
        if c:
            total += len(c)
            if len(buf) < 400000:
                buf.extend(c)
        else:
            time.sleep(0.01)
    el = time.time() - t0
    os.close(fd)

    print("采样时长      : %.1f s" % el)
    print("抓到字节      : %d  (%.0f B/s, 与出厂节点分食)" % (total, total / el))
    if total == 0:
        print()
        print("判据: 串口上一个字节都没有 -> GPS 芯片没在发。")
        print("      检查 nstandby / bream 固件是否灌过。")
        return 1

    # --- Bream/UBX 帧同步头统计 ---
    sync = buf.count(b"\xb5\x62")
    classes = collections.Counter()
    i = 0
    while True:
        i = buf.find(b"\xb5\x62", i)
        if i < 0 or i + 3 >= len(buf):
            break
        classes[buf[i + 2]] += 1
        i += 2

    print("Bream 帧同步头: %d 个 (0xB5 0x62)" % sync)
    if classes:
        top = ", ".join("class 0x%02X x%d" % (k, v) for k, v in classes.most_common(6))
        print("  帧类别分布  : %s" % top)

    # --- NMEA 片段(可能被抢字节切碎, 所以只找片段不找完整句) ---
    nmea_hits = 0
    for tag in (b"GGA", b"RMC", b"GSV", b"GSA", b"$GP", b"$GN", b"$GL"):
        n = buf.count(tag)
        if n:
            nmea_hits += n
            print("  NMEA 片段   : %-4s x%d" % (tag.decode(), n))
    if nmea_hits == 0:
        print("  NMEA 片段   : 无")

    print()
    print("=== 判据 ===")
    if sync > 0:
        print("✅ 芯片在发合法的 Bream/UBX 帧 -> 硬件 + 固件 + 串口链路是通的")
    else:
        print("⚠️ 没找到 Bream 帧同步头 -> 可能波特率不对或固件没灌")
    if nmea_hits > 0:
        print("✅ 流里有 NMEA -> 定位报文已开启")
    else:
        print("ℹ️ 流里没看到 NMEA。可能是: 没定星(室内)、或被出厂节点抢走了那些字节。")
        print("   这一条**不能**单独用来判定数据链坏了。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
