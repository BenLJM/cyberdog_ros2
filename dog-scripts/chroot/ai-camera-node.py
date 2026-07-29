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

        # 影像 QoS: 默认 reliable(与 D455 桥一致, 兼容 reliable 订阅者)。
        # 想省 publish 开销可设 AI_CAM_QOS=best_effort —— 但 reliable 的订阅者
        # 就连不上了(QoS 不兼容, 而且不报错, 表现为"订阅了收不到")。
        rel = (QoSReliabilityPolicy.BEST_EFFORT
               if env('AI_CAM_QOS', 'reliable').lower().startswith('best')
               else QoSReliabilityPolicy.RELIABLE)
        qos = QoSProfile(depth=2, history=QoSHistoryPolicy.KEEP_LAST,
                         reliability=rel)
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
        # ⚠️ 阈值要留容差, 不能正好等于 1/fps。当目标帧率≈源帧率时:
        # 处理完一帧后阻塞等下一帧, 醒来时 now - t_last_pub 常常差几十微秒
        # 不到一个周期 → 这一帧被跳过 → 下一次要等两个周期 → **帧率正好砍半**
        # (实测 BIN=4 卡在 17.7fps ≈ 30/2, 而处理只用 29ms 本该跑满 30fps)。
        # 取 0.8 个周期做阈值: 0.9 实测仍会偶尔误跳(28.8 而非 30.3fps)。
        # 上限本来就由源帧率(30fps)兜着, 阈值松一点不会超发。
        self.period = 0.8 / self.fps
        self.t_last_pub = 0.0
        self.lut = None
        self.lut_scale = 0.0

        self.out_buf = np.empty((self.out_h, self.out_w, 3), np.uint8)
        self.build_lut(255.0 / 61374.0 * self.gain)

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
        self.t_drain = self.t_conv = self.t_pub = 0.0
        self.t_report = time.time()
        # ⚠️ 不用 rclpy 的定时器 + spin。本节点没有任何订阅, 走执行器等于白白
        # 承担每轮的调度开销 —— 实测那部分把 23fps 卡死在与分辨率无关的位置
        # (BIN=4 的 526x390 和 BIN=3 的 701x520 帧率几乎一样, 说明瓶颈是固定
        # 开销而不是像素量)。改成自己 select 阻塞的裸循环。
        self.msg_img = Image()
        self.msg_img.header.frame_id = self.frame_id
        self.msg_img.encoding = 'rgb8'
        self.msg_img.is_bigendian = 0
        self.msg_info = CameraInfo()
        self.msg_info.header.frame_id = self.frame_id
        self.ci_last_sec = -1

    def run(self):
        while rclpy.ok():
            self.pump()

    # ── Bayer 抽点 + 10 位→8 位（LUT 查表）──────────────────────────────
    def build_lut(self, scale):
        """65536 项查表: 减黑电平 + 缩放 + 截断, 一次 fancy-index 全干完。

        原来那条 float 路(astype(int32) → 减 → clip → astype(float32) → 乘 →
        clip → astype(uint8), 每通道 5 趟大数组)在 1052x780 上要 ~28ms/通道;
        换成 lut[strided_view] 一趟出结果, 同分辨率 3 通道合计 ~28ms。
        表本身只有 65536 项, 重建约 0.3ms, 只在 scale 变化超过 10% 时重建。
        """
        x = np.arange(65536, dtype=np.int32) - BLACK_LEVEL
        np.clip(x, 0, None, out=x)
        v = x.astype(np.float32) * scale
        np.clip(v, 0, 255, out=v)
        self.lut = v.astype(np.uint8)
        self.lut_scale = scale

    def to_rgb8(self, raw):
        s = self.step
        h, w = self.out_h * s, self.out_w * s

        if self.autolevel:
            # 粗抽样求 99.5 分位。在 strided 视图上再抽 8 倍, 只有几千个点。
            samp = raw[0:h:s * 8, 0:w:s * 8]
            hi = float(np.percentile(samp, 99.5)) - BLACK_LEVEL if samp.size else 0.0
            scale = 235.0 / hi if hi > 512.0 else 1.0 / 256.0
        else:
            scale = 255.0 / 61374.0          # 61374 = (1023-64)<<6
        scale *= self.gain
        # 抖动会让查表天天重建, 只在变化超过 10% 时才重建
        if abs(scale - self.lut_scale) > 0.1 * max(scale, self.lut_scale):
            self.build_lut(scale)

        out = self.out_buf
        # ⚠️ 绿色只取 Gr 一路, 不和 Gb 求平均 —— 求平均要多两趟大数组运算,
        # 在 30fps 预算(33ms)里占不起。代价是绿通道噪声高 √2 倍, 肉眼看不出。
        out[:, :, 0] = self.lut[raw[0:h:s, 0:w:s]]        # R
        out[:, :, 1] = self.lut[raw[0:h:s, 1:w:s]]        # Gr
        out[:, :, 2] = self.lut[raw[1:h:s, 1:w:s]]        # B
        return out

    def pump(self):
        # ⚠️ 排空到最新帧再处理。源是 30fps 而我们只处理 ~5fps, 队列长期是满的,
        # 直接取队首拿到的是【最旧】那帧 —— 延迟会稳定在 NBUF/30 ≈ 200ms。
        # 先把队列里已就绪的全部取出、除最后一帧外立刻还回去, 延迟降到一帧内。
        t_enter = time.time()
        latest = None
        first = True
        while True:
            # 第一次阻塞等(最多 0.5s), 之后非阻塞排空 —— 裸循环里不能忙等,
            # 否则一个核被 100% 占死, 而这条红线是"相机永远让路给运动栈"。
            got = self.cap.dequeue(timeout=0.5 if first else 0.0)
            first = False
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
        self.t_drain += now - t_enter
        try:
            if now - self.t_last_pub >= self.period:
                self.t_last_pub = now
                rgb = self.to_rgb8(self.cap.view(idx))
                t1 = time.time(); self.t_conv += t1 - now
                self.publish(rgb, seq)
                self.t_pub += time.time() - t1
                self.n_pub += 1
        finally:
            # 无论如何都要还回去, 否则缓冲很快耗尽、彻底停流
            self.cap.requeue(idx)
        self.maybe_report()

    def publish(self, rgb, seq):
        # ⚠️ 复用同一个 Image 对象。rosidl 生成的消息类构造一次要初始化 header/
        # data 等一堆字段, 每帧新建在 30fps 预算里是实打实的开销;
        # publish() 是同步序列化的, 发完就可以改, 复用安全。
        now = self.get_clock().now().to_msg()
        m = self.msg_img
        m.header.stamp = now
        m.height = rgb.shape[0]
        m.width = rgb.shape[1]
        m.step = rgb.shape[1] * 3
        # ⚠️ 必须给 array.array('B')。Foxy 生成的 Image.data setter 只对
        # array.array 走快路径, 其它类型(bytes/numpy)会掉进 __debug__ 断言里
        # 【逐元素】校验 `all(isinstance(v,int) and 0<=v<256 for v in value)` ——
        # 246 万个字节就是 ~2 秒/帧, 把 30fps 的源直接压成 3fps。
        # (另一条路是给 python 加 -O 关掉 __debug__, 但那会连自检断言一起关掉。)
        m.data = array.array('B', rgb.tobytes())
        self.pub_img.publish(m)

        # camera_info 是静态的(内参不随帧变), 每帧都发纯属浪费一次 DDS 写。
        # 1Hz 足够任何订阅者拿到, 且 latched 语义由 KEEP_LAST 保证。
        if now.sec == self.ci_last_sec:
            return
        self.ci_last_sec = now.sec
        ci = self.msg_info
        ci.header.stamp = now
        ci.height = m.height
        ci.width = m.width
        # ⚠️ 出厂标定在 /opt/ros2/cyberdog/share/athena_tracking/config/camera_AI.yaml,
        # 是 **MEI(全向)模型** @1280x960: gamma1=674.669 gamma2=682.214
        # u0=646.499 v0=497.005, xi=0.176364, k1/k2/p1/p2 见文件。
        # ROS 的 CameraInfo 没有 MEI, 这里放的是把出厂焦距/主点按分辨率线性缩放
        # 得到的 **针孔近似**, 畸变留 0 —— 够 rviz/预览用, **不够做精确几何**。
        # 要精确的话请直接读那份 yaml 走 camodocal/MEI。
        sx = m.width / 1280.0
        sy = m.height / 960.0
        fx, fy = 674.669 * sx, 682.214 * sy
        cx, cy = 646.499 * sx, 497.005 * sy
        ci.distortion_model = 'plumb_bob'
        ci.d = [0.0] * 5
        ci.k = [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0]
        ci.r = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
        ci.p = [fx, 0.0, cx, 0.0, 0.0, fy, cy, 0.0, 0.0, 0.0, 1.0, 0.0]
        self.pub_info.publish(ci)

    def maybe_report(self):
        t = time.time()
        if t - self.t_report < 10.0:
            return
        dt = t - self.t_report
        k = max(1, self.n_pub)
        self.get_logger().info(
            '取 %.1f fps / 发 %.1f fps (丢弃过期 %d / 空转 %d) '
            '| 每帧: 排空 %.1fms 转换 %.1fms 发布 %.1fms'
            % (self.n_dq / dt, self.n_pub / dt, self.n_stale, self.n_timeout,
               self.t_drain * 1000 / k, self.t_conv * 1000 / k,
               self.t_pub * 1000 / k))
        self.n_dq = self.n_pub = self.n_timeout = self.n_stale = 0
        self.t_drain = self.t_conv = self.t_pub = 0.0
        self.t_report = t


def main():
    rclpy.init()
    node = None
    try:
        node = AiCameraBridge()
        node.run()
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
