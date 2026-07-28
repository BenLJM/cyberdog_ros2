#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
#  AI 头顶相机 v4l2 → ROS2 桥（节点本体）
#  部署路径: /mnt/jp4/opt/ai-camera/ai-camera-node.py   (chroot 内, 0755)
#  调用者:   /home/mi/ai-camera-inner.sh  ←  /usr/local/bin/ai-camera-bridge.sh
#
#  ── 为什么要有这个桥 ────────────────────────────────────────────────────────
#  出厂栈用 argus 取 AI 相机, 而 R32 的闭源 libargus 用不了 R35 的 capture
#  chardev(零帧, 最深一层是 nvmap handle 模型差异)。但 2026-07-29 实测证明:
#  **同一颗传感器走 v4l2 路能出真图** —— 内核/DTB/RCE 固件链是完全通的。
#  于是照搬本项目已验证过的桥模式(D455 的 rs_bridge / /opt/lrs-wrapper):
#  绕开 argus, 直接从 /dev/video1 取, 自己发 ROS2 话题。
#
#  ── 数据格式的坑(必读) ──────────────────────────────────────────────────────
#  传感器只报一个模式: 4208x3120 RG10 @30fps, bytesperline=8416(=W*2)。
#  **RAW10 是左移 6 位装在 16 位容器里的**, 所以:
#      像素16位值 = 信号10位 << 6      黑电平 = 64 << 6 = 4096
#  当初按 `& 0x3FF` 掩码分析, 把高位掩掉只剩噪声位, 直方图看着像乱码、
#  帧间相关 0.004(和随机数一个量级), 差点误判成"未初始化缓冲区"。
#  ⚠️ 动这段代码前先看未掩码的原始字。
#
#  ── 带宽 ────────────────────────────────────────────────────────────────────
#  13MP@30fps = 787 MB/s, 不可能整帧发。策略:
#    · 每帧都 DQBUF/QBUF(必须, 否则驱动缓冲耗尽), 但只处理第 N 帧
#    · 处理时用 Bayer 抽点降采样(BIN), 零插值、纯 strided 视图, 极便宜
#    · 默认 BIN=2 → 1052x780 rgb8 = 2.46MB/帧; FPS=5 → 12 MB/s
#  net.core.rmem_max 已由 /etc/sysctl.d 补回出厂 26214000(见 0725), 够用。
#
#  环境变量:
#    AI_CAM_DEV=/dev/video1   AI_CAM_BIN=2      AI_CAM_FPS=5
#    AI_CAM_NS=/mi1045904     AI_CAM_GAIN=1.0   AI_CAM_AUTOLEVEL=1
#    AI_CAM_FRAME_ID=ai_camera_optical
# =============================================================================
import array
import ctypes
import errno
import fcntl
import mmap
import os
import select
import sys
import time

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSReliabilityPolicy, QoSHistoryPolicy
from sensor_msgs.msg import CameraInfo, Image

# ── V4L2 ioctl 编码 ─────────────────────────────────────────────────────────
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = 8
_IOC_SIZESHIFT = 16
_IOC_DIRSHIFT = 30
_IOC_WRITE = 1
_IOC_READ = 2


def _IOC(d, t, nr, size):
    return ((d << _IOC_DIRSHIFT) | (ord(t) << _IOC_TYPESHIFT) |
            (nr << _IOC_NRSHIFT) | (size << _IOC_SIZESHIFT))


def _IOW(t, nr, size):
    return _IOC(_IOC_WRITE, t, nr, size)


def _IOWR(t, nr, size):
    return _IOC(_IOC_READ | _IOC_WRITE, t, nr, size)


class v4l2_pix_format(ctypes.Structure):
    _fields_ = [('width', ctypes.c_uint32), ('height', ctypes.c_uint32),
                ('pixelformat', ctypes.c_uint32), ('field', ctypes.c_uint32),
                ('bytesperline', ctypes.c_uint32), ('sizeimage', ctypes.c_uint32),
                ('colorspace', ctypes.c_uint32), ('priv', ctypes.c_uint32),
                ('flags', ctypes.c_uint32), ('ycbcr_enc', ctypes.c_uint32),
                ('quantization', ctypes.c_uint32), ('xfer_func', ctypes.c_uint32)]


class _fmt_union(ctypes.Union):
    # ⚠️ `_align` 不是摆设: 内核那个 union 里含 v4l2_window(带指针)所以对齐是 8。
    # 不强制的话 ctypes 会按 4 对齐 → fmt 落在偏移 4、结构体 204 字节,
    # 而内核要的是偏移 8、208 字节 —— ioctl 号和字段偏移会同时错。
    _fields_ = [('pix', v4l2_pix_format), ('raw', ctypes.c_uint8 * 200),
                ('_align', ctypes.c_uint64)]


class v4l2_format(ctypes.Structure):
    _fields_ = [('type', ctypes.c_uint32), ('fmt', _fmt_union)]


class _timeval(ctypes.Structure):
    _fields_ = [('tv_sec', ctypes.c_long), ('tv_usec', ctypes.c_long)]


class v4l2_timecode(ctypes.Structure):
    _fields_ = [('type', ctypes.c_uint32), ('flags', ctypes.c_uint32),
                ('frames', ctypes.c_uint8), ('seconds', ctypes.c_uint8),
                ('minutes', ctypes.c_uint8), ('hours', ctypes.c_uint8),
                ('userbits', ctypes.c_uint8 * 4)]


class _buf_m(ctypes.Union):
    _fields_ = [('offset', ctypes.c_uint32), ('userptr', ctypes.c_ulong),
                ('planes', ctypes.c_void_p), ('fd', ctypes.c_int32)]


class v4l2_buffer(ctypes.Structure):
    _fields_ = [('index', ctypes.c_uint32), ('type', ctypes.c_uint32),
                ('bytesused', ctypes.c_uint32), ('flags', ctypes.c_uint32),
                ('field', ctypes.c_uint32), ('timestamp', _timeval),
                ('timecode', v4l2_timecode), ('sequence', ctypes.c_uint32),
                ('memory', ctypes.c_uint32), ('m', _buf_m),
                ('length', ctypes.c_uint32), ('reserved2', ctypes.c_uint32),
                ('reserved', ctypes.c_uint32)]


class v4l2_requestbuffers(ctypes.Structure):
    _fields_ = [('count', ctypes.c_uint32), ('type', ctypes.c_uint32),
                ('memory', ctypes.c_uint32), ('capabilities', ctypes.c_uint32),
                ('reserved', ctypes.c_uint32 * 1)]


# 结构体大小必须和内核 ABI 一致, 错了 ioctl 号就是错的 —— 启动时直接断言
assert ctypes.sizeof(v4l2_format) == 208, ctypes.sizeof(v4l2_format)
assert ctypes.sizeof(v4l2_buffer) == 88, ctypes.sizeof(v4l2_buffer)
assert ctypes.sizeof(v4l2_requestbuffers) == 20, ctypes.sizeof(v4l2_requestbuffers)

VIDIOC_G_FMT = _IOWR('V', 4, 208)
VIDIOC_REQBUFS = _IOWR('V', 8, 20)
VIDIOC_QUERYBUF = _IOWR('V', 9, 88)
VIDIOC_QBUF = _IOWR('V', 15, 88)
VIDIOC_DQBUF = _IOWR('V', 17, 88)
VIDIOC_STREAMON = _IOW('V', 18, 4)
VIDIOC_STREAMOFF = _IOW('V', 19, 4)

BUF_TYPE_VIDEO_CAPTURE = 1
MEMORY_MMAP = 1
NBUF = 6            # 缓冲多给两个: 处理一帧的百来毫秒里源还在 30fps 灌
BLACK_LEVEL = 4096          # 10 位黑电平 64 << 6


def env(name, default, cast=str):
    v = os.environ.get(name, '')
    if v == '':
        return default
    try:
        return cast(v)
    except (TypeError, ValueError):
        return default


class V4L2Capture(object):
    """最小可用的 V4L2 mmap 取流器。刻意不设格式 —— 传感器只有一个模式,
    读回来用即可, 少一次可能失败的 S_FMT。"""

    def __init__(self, dev):
        self.fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
        f = v4l2_format()
        f.type = BUF_TYPE_VIDEO_CAPTURE
        fcntl.ioctl(self.fd, VIDIOC_G_FMT, f)
        self.width = f.fmt.pix.width
        self.height = f.fmt.pix.height
        self.stride = f.fmt.pix.bytesperline
        self.sizeimage = f.fmt.pix.sizeimage
        self.fourcc = ''.join(chr((f.fmt.pix.pixelformat >> s) & 0xFF)
                              for s in (0, 8, 16, 24))

        req = v4l2_requestbuffers()
        req.count = NBUF
        req.type = BUF_TYPE_VIDEO_CAPTURE
        req.memory = MEMORY_MMAP
        fcntl.ioctl(self.fd, VIDIOC_REQBUFS, req)
        if req.count < 2:
            raise RuntimeError('驱动只给了 %d 个缓冲区' % req.count)

        self.maps = []
        for i in range(req.count):
            b = v4l2_buffer()
            b.index = i
            b.type = BUF_TYPE_VIDEO_CAPTURE
            b.memory = MEMORY_MMAP
            fcntl.ioctl(self.fd, VIDIOC_QUERYBUF, b)
            self.maps.append(mmap.mmap(self.fd, b.length,
                                       mmap.MAP_SHARED,
                                       mmap.PROT_READ | mmap.PROT_WRITE,
                                       offset=b.m.offset))
            fcntl.ioctl(self.fd, VIDIOC_QBUF, b)

        t = ctypes.c_int(BUF_TYPE_VIDEO_CAPTURE)
        fcntl.ioctl(self.fd, VIDIOC_STREAMON, t)
        self.streaming = True

    def dequeue(self, timeout=2.0):
        """返回 (index, sequence, 单调时间戳秒) 或 None(超时)。"""
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return None
        b = v4l2_buffer()
        b.type = BUF_TYPE_VIDEO_CAPTURE
        b.memory = MEMORY_MMAP
        try:
            fcntl.ioctl(self.fd, VIDIOC_DQBUF, b)
        except IOError as e:
            if e.errno in (errno.EAGAIN, errno.EINTR):
                return None
            raise
        return b.index, b.sequence, b.timestamp.tv_sec + b.timestamp.tv_usec * 1e-6

    def requeue(self, index):
        b = v4l2_buffer()
        b.index = index
        b.type = BUF_TYPE_VIDEO_CAPTURE
        b.memory = MEMORY_MMAP
        fcntl.ioctl(self.fd, VIDIOC_QBUF, b)

    def view(self, index):
        """对 mmap 缓冲的**零拷贝** uint16 视图, 形状 (H, stride//2)。"""
        a = np.frombuffer(self.maps[index], dtype='<u2',
                          count=self.stride * self.height // 2)
        return a.reshape(self.height, self.stride // 2)

    def close(self):
        try:
            if getattr(self, 'streaming', False):
                t = ctypes.c_int(BUF_TYPE_VIDEO_CAPTURE)
                fcntl.ioctl(self.fd, VIDIOC_STREAMOFF, t)
                self.streaming = False
        except Exception:
            pass
        for m in getattr(self, 'maps', []):
            try:
                m.close()
            except Exception:
                pass
        try:
            os.close(self.fd)
        except Exception:
            pass


class AiCameraBridge(Node):
    def __init__(self):
        super().__init__('ai_camera_bridge')
        self.dev = env('AI_CAM_DEV', '/dev/video1')
        self.bin = max(1, env('AI_CAM_BIN', 2, int))
        self.fps = max(0.1, env('AI_CAM_FPS', 5.0, float))
        self.gain = env('AI_CAM_GAIN', 1.0, float)
        self.autolevel = env('AI_CAM_AUTOLEVEL', 1, int) != 0
        self.frame_id = env('AI_CAM_FRAME_ID', 'ai_camera_optical')
        ns = env('AI_CAM_NS', '/mi1045904').rstrip('/')

        # 影像用 reliable(SYSTEM_DEFAULT): 与 D455 桥保持一致, 兼容 reliable 订阅者。
        qos = QoSProfile(depth=2,
                         history=QoSHistoryPolicy.KEEP_LAST,
                         reliability=QoSReliabilityPolicy.RELIABLE)
        self.pub_img = self.create_publisher(Image, ns + '/ai_camera/image_raw', qos)
        self.pub_info = self.create_publisher(CameraInfo, ns + '/ai_camera/camera_info', qos)

        self.cap = V4L2Capture(self.dev)
        if self.cap.fourcc != 'RG10':
            self.get_logger().warn('意外的像素格式 %s(预期 RG10), 解码可能不对'
                                   % self.cap.fourcc)
        self.step = 2 * self.bin                       # Bayer 抽点步长
        self.out_w = self.cap.width // self.step
        self.out_h = self.cap.height // self.step
        # ⚠️ 节流按【墙钟】而不是帧计数。按帧计数会被取流速率牵连:
        # 处理一帧要百来毫秒, 期间源仍在 30fps 灌, 于是实际只 DQ 到 ~20fps,
        # "每 6 帧发一次"就变成 3.3fps 而不是要的 5fps。按时间就与取流速率解耦。
        self.period = 1.0 / self.fps
        self.t_last_pub = 0.0

        self.get_logger().info(
            '源 %s %dx%d %s stride=%d → 输出 %dx%d rgb8 @ %.1f fps, '
            'autolevel=%s gain=%.2f'
            % (self.dev, self.cap.width, self.cap.height, self.cap.fourcc,
               self.cap.stride, self.out_w, self.out_h, self.fps,
               self.autolevel, self.gain))

        self.n_dq = 0
        self.n_pub = 0
        self.n_timeout = 0
        self.n_stale = 0
        self.t_report = time.time()
        # 定时器周期取源帧间隔的一半, 保证不会成为节流瓶颈
        self.timer = self.create_timer(1.0 / 120.0, self.pump)

    # ── Bayer 抽点 + 10 位→8 位 ────────────────────────────────────────────
    def to_rgb8(self, raw):
        s = self.step
        h, w = self.out_h * s, self.out_w * s

        # ⚠️ 性能命脉: VI 的 DMA 缓冲是 write-combining 内存。在它上面做大步长
        # 抽点读会有巨大读放大 —— 每次访问拉一整条 cache line 却只用 2 字节。
        # 实测那样写一帧要 ~1.9 秒, 把节点从 30fps 拖到 3fps。
        # 正确做法: 先把需要的【整行】连续拷进普通内存(每行 8416 字节顺序读,
        # WC 内存对顺序读是友好的), 再在普通内存上做列抽点。
        top = np.ascontiguousarray(raw[0:h:s, :w])   # 每组的第 0 行: R / Gr
        bot = np.ascontiguousarray(raw[1:h:s, :w])   # 每组的第 1 行: Gb / B

        # int32 防止减黑电平下溢(uint16 会绕回 65535)
        r = top[:, 0::s].astype(np.int32) - BLACK_LEVEL
        g = ((top[:, 1::s].astype(np.int32) +
              bot[:, 0::s].astype(np.int32)) >> 1) - BLACK_LEVEL
        b = bot[:, 1::s].astype(np.int32) - BLACK_LEVEL
        for ch in (r, g, b):
            np.clip(ch, 0, None, out=ch)

        if self.autolevel:
            # 抽样算 99.5 分位, 全图算太贵。暗场时分位数≈0 → 兜底避免除零。
            hi = float(np.percentile(g[::4, ::4], 99.5)) if g.size else 0.0
            scale = 235.0 / hi if hi > 8.0 else 0.0
        else:
            scale = 255.0 / 61374.0                  # 61374 = (1023-64)<<6
        if scale <= 0.0:
            scale = 1.0 / 256.0        # 近全黑: 等价 >>8, 让噪声可见而非死黑
        scale *= self.gain

        out = np.empty((self.out_h, self.out_w, 3), np.uint8)
        for i, ch in enumerate((r, g, b)):
            v = ch.astype(np.float32)
            v *= scale
            np.clip(v, 0, 255, out=v)
            out[:, :, i] = v.astype(np.uint8)
        return out

    def pump(self):
        # ⚠️ 排空到最新帧再处理。源是 30fps 而我们只处理 ~5fps, 队列长期是满的,
        # 直接取队首拿到的是【最旧】那帧 —— 延迟会稳定在 NBUF/30 ≈ 200ms。
        # 先把队列里已就绪的全部取出、除最后一帧外立刻还回去, 延迟降到一帧内。
        latest = None
        while True:
            got = self.cap.dequeue(timeout=0.0)
            if got is None:
                break
            self.n_dq += 1
            if latest is not None:
                self.cap.requeue(latest[0])     # 旧帧原样归还, 不处理
                self.n_stale += 1
            latest = got
        if latest is None:
            self.n_timeout += 1
            self.maybe_report()
            return
        idx, seq, _ts = latest
        now = time.time()
        try:
            if now - self.t_last_pub >= self.period:
                self.t_last_pub = now
                rgb = self.to_rgb8(self.cap.view(idx))
                self.publish(rgb, seq)
                self.n_pub += 1
        finally:
            # 无论如何都要还回去, 否则缓冲很快耗尽、彻底停流
            self.cap.requeue(idx)
        self.maybe_report()

    def publish(self, rgb, seq):
        now = self.get_clock().now().to_msg()
        m = Image()
        m.header.stamp = now
        m.header.frame_id = self.frame_id
        m.height = rgb.shape[0]
        m.width = rgb.shape[1]
        m.encoding = 'rgb8'
        m.is_bigendian = 0
        m.step = rgb.shape[1] * 3
        # ⚠️ 必须给 array.array('B')。Foxy 生成的 Image.data setter 只对
        # array.array 走快路径, 其它类型(bytes/numpy)会掉进 __debug__ 断言里
        # 【逐元素】校验 `all(isinstance(v,int) and 0<=v<256 for v in value)` ——
        # 246 万个字节就是 ~2 秒/帧, 把 30fps 的源直接压成 3fps。
        # (另一条路是给 python 加 -O 关掉 __debug__, 但那会连自检断言一起关掉。)
        m.data = array.array('B', rgb.tobytes())
        self.pub_img.publish(m)

        ci = CameraInfo()
        ci.header = m.header
        ci.height = m.height
        ci.width = m.width
        ci.distortion_model = 'plumb_bob'
        ci.d = [0.0] * 5
        # 没有标定文件 —— 给个几何合理的占位(f≈对角线), 标定后再替换。
        f = float(m.width)
        ci.k = [f, 0.0, m.width / 2.0, 0.0, f, m.height / 2.0, 0.0, 0.0, 1.0]
        ci.r = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
        ci.p = [f, 0.0, m.width / 2.0, 0.0, 0.0, f, m.height / 2.0, 0.0,
                0.0, 0.0, 1.0, 0.0]
        self.pub_info.publish(ci)

    def maybe_report(self):
        t = time.time()
        if t - self.t_report < 10.0:
            return
        dt = t - self.t_report
        self.get_logger().info('取 %.1f fps / 发 %.1f fps (丢弃过期 %d / 空转 %d)'
                               % (self.n_dq / dt, self.n_pub / dt,
                                  self.n_stale, self.n_timeout))
        self.n_dq = self.n_pub = self.n_timeout = self.n_stale = 0
        self.t_report = t


def main():
    rclpy.init()
    node = None
    try:
        node = AiCameraBridge()
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        if node is not None:
            node.cap.close()
            node.destroy_node()
        try:
            rclpy.shutdown()
        except Exception:
            pass


if __name__ == '__main__':
    sys.exit(main())
