#!/usr/bin/env python3
"""
CyberDog 串口控制台常驻记录器（救援笔记本侧）

补 ramoops 黑匣子的最后一个缺口：ramoops 活在 DRAM 里，**真挂死需要拔电的场景**
（thermtrip、probe 阶段挂死、看门狗够不着的死循环）掉电即失。串口是唯一能在
狗自己已经写不动日志时还留下现场的通道。

设计红线
--------
1. **只读打开** (O_RDONLY|O_NONBLOCK|O_NOCTTY)。
   狗的 extlinux 引导菜单在等按键 —— 往这个口写任何一个字节都可能改掉启动项
   或者把引导卡在菜单里。用只读 fd 从操作系统层面保证我们做不到这件事。
2. **CLOCAL + -HUPCL**。忽略 modem 状态线，关闭时不拉 DTR，避免任何形式的
   意外复位或挂断。
3. 设备消失（狗重启 / USB 重枚举）不是错误，是常态 —— 退回等待循环，别退出。

用法: cyberdog-serial-log.py <device> <logfile>
SIGHUP 重开日志文件（配合 logrotate）。
"""

import errno
import os
import signal
import sys
import termios
import time
from datetime import datetime, timezone

# 狗的 ttyTCU0 控制台速率，与 extlinux APPEND 里的 console=ttyTCU0,115200 一致
BAUD = termios.B115200

# 一行超过这个长度就强制断行，防止串口上出现无换行的二进制垃圾时把内存吃光
MAX_LINE = 8192

# 设备不在时的重试间隔（秒）。狗从断电到 USB 重新枚举通常 10~20 秒。
RETRY_SEC = 2.0


class LogFile:
    """支持 SIGHUP 重开的日志文件（logrotate 用）。"""

    def __init__(self, path):
        self.path = path
        self.fh = None
        self._open()

    def _open(self):
        if self.fh:
            try:
                self.fh.close()
            except Exception:
                pass
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        # 行缓冲：崩溃现场必须已经落盘，不能留在用户态缓冲里
        self.fh = open(self.path, "a", buffering=1, encoding="utf-8", errors="replace")

    def reopen(self):
        self._open()

    def write(self, line):
        try:
            self.fh.write(line)
        except Exception:
            # 磁盘满 / fd 失效时不能把记录器本身弄死，尝试重开一次
            try:
                self._open()
                self.fh.write(line)
            except Exception:
                pass


def stamp():
    # UTC，与狗自己的系统时钟同基准，便于和 dmesg / ramoops 归档对时
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def configure_tty(fd):
    """把串口设成 115200 8N1 raw，且明确不碰 modem 控制线。"""
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs

    # 输入：不做任何转换，不开软件流控 —— 内核日志里的任意字节都要原样拿到
    iflag = 0
    # 输出：无关（我们从不写），清掉以防万一
    oflag = 0
    # 控制：8 位 / 无校验 / 1 停止位 / 收使能 / 忽略 modem 线 / 关闭时不拉 DTR
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    # 显式确保这几位是关的
    cflag &= ~termios.PARENB   # 无校验
    cflag &= ~termios.CSTOPB   # 1 停止位
    cflag &= ~termios.CRTSCTS  # 无硬件流控
    cflag &= ~termios.HUPCL    # 关闭 fd 时不拉低 DTR（防止任何形式的复位）
    # 本地：非规范模式，不回显（回显在只读 fd 上本就无效，但保持语义干净）
    lflag = 0

    cc = list(cc)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0

    termios.tcsetattr(
        fd, termios.TCSANOW,
        [iflag, oflag, cflag, lflag, BAUD, BAUD, cc],
    )
    # 丢掉打开之前积压在内核缓冲里的陈旧字节
    termios.tcflush(fd, termios.TCIFLUSH)


def open_port(dev):
    """只读打开并配置。返回 (fd, rdev)。"""
    fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_tty(fd)
        rdev = os.fstat(fd).st_rdev
    except Exception:
        os.close(fd)
        raise
    return fd, rdev


def device_changed(dev, rdev):
    """设备是不是已经不是我们打开的那个了？

    🔴 2026-07-27 实测踩到的坑：狗重启后 USB 重新枚举，by-id 符号链接从
    ttyACM0 指到了 **ttyACM1**，而我们手上那个旧 fd 指向已经消失的 ttyACM0。
    这种情况下 read() 只是一直返回 EAGAIN（不报错），于是记录器**看似在跑、
    实际上永远收不到一个字节** —— 整个重启窗口一行都没记到。
    所以不能只依赖 read 报错，必须主动比对设备号。
    """
    try:
        return os.stat(dev).st_rdev != rdev
    except OSError:
        return True   # 路径没了 = 肯定变了


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: cyberdog-serial-log.py <device> <logfile>\n")
        return 2
    dev, logpath = sys.argv[1], sys.argv[2]

    log = LogFile(logpath)
    signal.signal(signal.SIGHUP, lambda *_: log.reopen())

    stop = {"flag": False}

    def _term(*_):
        stop["flag"] = True

    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)

    log.write("%s === serial logger start (dev=%s) ===\n" % (stamp(), dev))

    buf = bytearray()
    waiting_logged = False

    while not stop["flag"]:
        # --- 等设备出现 ---
        if not os.path.exists(dev):
            if not waiting_logged:
                log.write("%s === waiting for %s (dog powered off / re-enumerating) ===\n"
                          % (stamp(), dev))
                waiting_logged = True
            time.sleep(RETRY_SEC)
            continue

        try:
            fd, rdev = open_port(dev)
        except OSError as e:
            if not waiting_logged:
                log.write("%s === cannot open %s: %s ===\n" % (stamp(), dev, e))
                waiting_logged = True
            time.sleep(RETRY_SEC)
            continue

        waiting_logged = False
        log.write("%s === port opened, listening (rdev=%d,%d) ===\n"
                  % (stamp(), os.major(rdev), os.minor(rdev)))

        # --- 读循环 ---
        next_check = time.time() + 1.0
        try:
            while not stop["flag"]:
                # 每秒确认一次手上这个 fd 还对应着当前的设备（见 device_changed）
                now = time.time()
                if now >= next_check:
                    next_check = now + 1.0
                    if device_changed(dev, rdev):
                        log.write("%s === device re-enumerated, reopening ===\n" % stamp())
                        break

                try:
                    chunk = os.read(fd, 4096)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                        # 非阻塞下暂时没数据 —— 串口空闲是常态，不是错误
                        time.sleep(0.05)
                        continue
                    # ENODEV / EIO = 狗断电或 USB 拔了
                    raise

                if not chunk:
                    time.sleep(0.05)
                    continue

                buf.extend(chunk)

                # 按行切分并打时间戳。CR 单独当作行尾（引导器有时只发 \r）
                while True:
                    idx = -1
                    for i, b in enumerate(buf):
                        if b in (0x0A, 0x0D):
                            idx = i
                            break
                    if idx < 0:
                        break
                    line = bytes(buf[:idx])
                    del buf[:idx + 1]
                    text = line.decode("utf-8", errors="replace").rstrip("\r\n")
                    if text:
                        log.write("%s %s\n" % (stamp(), text))

                # 无换行的超长垃圾：强制冲出去，别把内存吃光
                if len(buf) > MAX_LINE:
                    text = bytes(buf).decode("utf-8", errors="replace")
                    del buf[:]
                    log.write("%s [no-newline] %s\n" % (stamp(), text))

        except OSError as e:
            log.write("%s === port lost (%s) ===\n" % (stamp(), e))
        finally:
            try:
                os.close(fd)
            except Exception:
                pass
            if buf:
                text = bytes(buf).decode("utf-8", errors="replace")
                del buf[:]
                if text.strip():
                    log.write("%s %s\n" % (stamp(), text.strip()))

        time.sleep(RETRY_SEC)

    log.write("%s === serial logger stop ===\n" % stamp())
    return 0


if __name__ == "__main__":
    sys.exit(main())
