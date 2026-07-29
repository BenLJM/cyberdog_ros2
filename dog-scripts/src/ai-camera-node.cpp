// =============================================================================
//  AI 头顶相机 v4l2 → ROS2 桥（C++ 版）
//  部署路径: /mnt/jp4/opt/ai-camera/ai-camera-node   (chroot 内可执行)
//  构建:     dog-scripts/bin/ai-camera-build.sh（在 chroot 里用 g++ 直接编）
//
//  ── 为什么要有 C++ 版 ──────────────────────────────────────────────────────
//  Python 版（ai-camera-node.py）已经把帧率做到 30.1fps，但只能到 526×390。
//  硬墙是 **rclpy publish ≈ 30 MB/s**：1.09MB 的消息要 33ms，1052×780 只有 9.3fps。
//  查过出厂 cyclonedds.xml —— 里面没有任何流控/MaxMessageSize 限制，
//  所以那 30MB/s 是 Python 侧的序列化开销，不是 DDS 的问题。
//  出厂标定 athena_tracking/config/camera_AI.yaml 的分辨率是 **1280×960**，
//  这一版的目标就是直出 1280×960 rgb8 @ 30fps。
//
//  ── 数据格式（和 Python 版同一套，坑也一样）────────────────────────────────
//  传感器只报一个模式：4208×3120 RG10 @30fps，bytesperline = 8416 (= W*2)。
//  **RAW10 是左移 6 位装在 16 位容器里的**：像素16位值 = 信号10位 << 6，
//  黑电平 = 64 << 6 = 4096。别按 0x3FF 掩码（那样只剩噪声位）。
//
//  ── 降采样 ────────────────────────────────────────────────────────────────
//  源的 Bayer 四元组阵列是 2104×1560，要出 1280×960 —— **不是整数倍**
//  (2104/1280 = 1.64375, 1560/960 = 1.625)，所以用行列索引表做最近邻抽点。
//  表在启动时算好，热路径里只有两次查表 + 三次 LUT。
//
//  环境变量:
//    AI_CAM_DEV=/dev/video1  AI_CAM_W=1280  AI_CAM_H=960  AI_CAM_FPS=30
//    AI_CAM_NS=/mi1045904    AI_CAM_GAIN=1.0  AI_CAM_AUTOLEVEL=1
//    AI_CAM_FRAME_ID=ai_camera_optical       AI_CAM_QOS=reliable|best_effort
// =============================================================================
#include <algorithm>
#include <cerrno>
#include <cmath>      // ⚠️ std::abs(double) 需要它; 只有 <cstdlib> 的话会解析到 int 重载
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>
#include <linux/videodev2.h>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/camera_info.hpp>
#include <sensor_msgs/msg/image.hpp>

namespace {

constexpr int kBlackLevel = 4096;   // 10 位黑电平 64 << 6
constexpr int kNumBuf = 6;          // 处理一帧的十几毫秒里源还在 30fps 灌

std::string EnvStr(const char *k, const std::string &d) {
  const char *v = std::getenv(k);
  return (v && *v) ? std::string(v) : d;
}
int EnvInt(const char *k, int d) {
  const char *v = std::getenv(k);
  if (!v || !*v) return d;
  char *end = nullptr;
  long r = std::strtol(v, &end, 10);
  return (end && *end == '\0') ? static_cast<int>(r) : d;
}
double EnvDbl(const char *k, double d) {
  const char *v = std::getenv(k);
  if (!v || !*v) return d;
  char *end = nullptr;
  double r = std::strtod(v, &end);
  return (end && *end == '\0') ? r : d;
}

// ── 最小 V4L2 mmap 取流器 ───────────────────────────────────────────────────
// 刻意不设格式：传感器只有一个模式，G_FMT 读回来用即可，少一次可能失败的 S_FMT。
class V4L2Capture {
public:
  bool Open(const std::string &dev, std::string *err) {
    fd_ = ::open(dev.c_str(), O_RDWR | O_NONBLOCK);
    if (fd_ < 0) { *err = "open " + dev + ": " + std::strerror(errno); return false; }

    v4l2_format f{};
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (Ioctl(VIDIOC_G_FMT, &f) < 0) { *err = "VIDIOC_G_FMT"; return false; }
    width_ = f.fmt.pix.width;
    height_ = f.fmt.pix.height;
    stride_ = f.fmt.pix.bytesperline;
    fourcc_ = f.fmt.pix.pixelformat;

    v4l2_requestbuffers req{};
    req.count = kNumBuf;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (Ioctl(VIDIOC_REQBUFS, &req) < 0) { *err = "VIDIOC_REQBUFS"; return false; }
    if (req.count < 2) { *err = "驱动只给了 " + std::to_string(req.count) + " 个缓冲区"; return false; }

    bufs_.resize(req.count);
    for (unsigned i = 0; i < req.count; ++i) {
      v4l2_buffer b{};
      b.index = i;
      b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
      b.memory = V4L2_MEMORY_MMAP;
      if (Ioctl(VIDIOC_QUERYBUF, &b) < 0) { *err = "VIDIOC_QUERYBUF"; return false; }
      bufs_[i].len = b.length;
      bufs_[i].ptr = ::mmap(nullptr, b.length, PROT_READ | PROT_WRITE, MAP_SHARED,
                            fd_, b.m.offset);
      if (bufs_[i].ptr == MAP_FAILED) { *err = "mmap"; return false; }
      if (Ioctl(VIDIOC_QBUF, &b) < 0) { *err = "VIDIOC_QBUF(初始)"; return false; }
    }

    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (Ioctl(VIDIOC_STREAMON, &type) < 0) { *err = "VIDIOC_STREAMON"; return false; }
    streaming_ = true;
    return true;
  }

  // 返回缓冲索引；-1 = 超时/无数据
  int Dequeue(double timeout_s, uint32_t *seq) {
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fd_, &rfds);
    timeval tv{};
    tv.tv_sec = static_cast<time_t>(timeout_s);
    tv.tv_usec = static_cast<suseconds_t>((timeout_s - tv.tv_sec) * 1e6);
    int r = ::select(fd_ + 1, &rfds, nullptr, nullptr, &tv);
    if (r <= 0) return -1;

    v4l2_buffer b{};
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    if (Ioctl(VIDIOC_DQBUF, &b) < 0) return -1;
    if (seq) *seq = b.sequence;
    return static_cast<int>(b.index);
  }

  void Requeue(int idx) {
    v4l2_buffer b{};
    b.index = static_cast<uint32_t>(idx);
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    Ioctl(VIDIOC_QBUF, &b);
  }

  const uint16_t *Data(int idx) const {
    return static_cast<const uint16_t *>(bufs_[idx].ptr);
  }

  void Close() {
    if (fd_ < 0) return;
    if (streaming_) {
      int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
      Ioctl(VIDIOC_STREAMOFF, &type);
      streaming_ = false;
    }
    for (auto &b : bufs_) if (b.ptr && b.ptr != MAP_FAILED) ::munmap(b.ptr, b.len);
    bufs_.clear();
    ::close(fd_);
    fd_ = -1;
  }
  ~V4L2Capture() { Close(); }

  unsigned width() const { return width_; }
  unsigned height() const { return height_; }
  unsigned stride() const { return stride_; }
  uint32_t fourcc() const { return fourcc_; }

private:
  // EINTR 重试 —— 不重试的话调试器/信号会让 ioctl 假失败
  int Ioctl(unsigned long req, void *arg) {
    int r;
    do { r = ::ioctl(fd_, req, arg); } while (r < 0 && errno == EINTR);
    return r;
  }
  struct Buf { void *ptr = nullptr; size_t len = 0; };
  int fd_ = -1;
  bool streaming_ = false;
  unsigned width_ = 0, height_ = 0, stride_ = 0;
  uint32_t fourcc_ = 0;
  std::vector<Buf> bufs_;
};

class AiCameraNode : public rclcpp::Node {
public:
  AiCameraNode() : Node(EnvStr("AI_CAM_NODE_NAME", "ai_camera_bridge")) {}

  bool Init() {
    dev_ = EnvStr("AI_CAM_DEV", "/dev/video1");
    // mono8: 鱼眼 OV7251 是单色传感器(驱动报的 BG10 Bayer 标签是形式上的,
    // 所有像素同为灰度) —— 逐像素 LUT 直出灰度, 不做 Bayer 抽点。
    mono_ = (EnvStr("AI_CAM_ENCODING", "rgb8") == "mono8");
    out_w_ = EnvInt("AI_CAM_W", mono_ ? 640 : 1280);
    out_h_ = EnvInt("AI_CAM_H", mono_ ? 480 : 960);
    fps_ = EnvDbl("AI_CAM_FPS", 30.0);
    gain_ = EnvDbl("AI_CAM_GAIN", 1.0);
    autolevel_ = EnvInt("AI_CAM_AUTOLEVEL", 1) != 0;
    frame_id_ = EnvStr("AI_CAM_FRAME_ID", "ai_camera_optical");
    std::string ns = EnvStr("AI_CAM_NS", "/mi1045904");
    while (!ns.empty() && ns.back() == '/') ns.pop_back();

    std::string err;
    if (!cap_.Open(dev_, &err)) {
      RCLCPP_ERROR(get_logger(), "打开 %s 失败: %s", dev_.c_str(), err.c_str());
      return false;
    }
    const uint32_t want = mono_ ? v4l2_fourcc('B', 'G', '1', '0')
                                : v4l2_fourcc('R', 'G', '1', '0');
    if (cap_.fourcc() != want) {
      RCLCPP_WARN(get_logger(), "意外的像素格式 0x%08x（预期 %s），解码可能不对",
                  cap_.fourcc(), mono_ ? "BG10" : "RG10");
    }
    const int max_w = static_cast<int>(cap_.width()) / (mono_ ? 1 : 2);
    const int max_h = static_cast<int>(cap_.height()) / (mono_ ? 1 : 2);
    if (out_w_ < 2 || out_h_ < 2 || out_w_ > max_w || out_h_ > max_h) {
      RCLCPP_ERROR(get_logger(), "输出 %dx%d 越界（上限 %dx%d）",
                   out_w_, out_h_, max_w, max_h);
      return false;
    }

    // 行列索引表：mono 按像素做最近邻；rgb 则输出 (x,y) → 源里那个 Bayer
    // 四元组左上角的 (row, col)，源四元组阵列 = (W/2)x(H/2)。
    const int qw = max_w;
    const int qh = max_h;
    const int step = mono_ ? 1 : 2;
    row_.resize(out_h_);
    col_.resize(out_w_);
    for (int y = 0; y < out_h_; ++y)
      row_[y] = step * static_cast<int>(static_cast<int64_t>(y) * qh / out_h_);
    for (int x = 0; x < out_w_; ++x)
      col_[x] = step * static_cast<int>(static_cast<int64_t>(x) * qw / out_w_);

    // 两条源行的暂存区（拷进 CPU 缓存用）
    stage_.resize(cap_.stride());   // 单位是 uint16 → 字节数 = stride*2 = 两行
    lut_.resize(65536);
    BuildLut(255.0 / 61374.0 * gain_);      // 61374 = (1023-64)<<6

    auto qos = rclcpp::QoS(rclcpp::KeepLast(2));
    if (EnvStr("AI_CAM_QOS", "reliable").rfind("best", 0) == 0) {
      qos.best_effort();
      // ⚠️ best_effort 的话 reliable 的订阅者就连不上了（QoS 不兼容，
      // 而且不报错，表现为"订阅了收不到"）。
    } else {
      qos.reliable();
    }
    const std::string prefix = ns + EnvStr("AI_CAM_TOPIC_PREFIX", "/ai_camera");
    pub_img_ = create_publisher<sensor_msgs::msg::Image>(prefix + "/image_raw", qos);
    pub_info_ = create_publisher<sensor_msgs::msg::CameraInfo>(prefix + "/camera_info", qos);

    msg_.header.frame_id = frame_id_;
    msg_.height = static_cast<uint32_t>(out_h_);
    msg_.width = static_cast<uint32_t>(out_w_);
    msg_.encoding = mono_ ? "mono8" : "rgb8";
    msg_.is_bigendian = 0;
    msg_.step = static_cast<uint32_t>(out_w_ * (mono_ ? 1 : 3));
    msg_.data.resize(static_cast<size_t>(out_w_) * out_h_ * (mono_ ? 1 : 3));

    BuildCameraInfo();

    // ⚠️ 阈值要留容差，不能正好等于 1/fps。目标帧率≈源帧率时：处理完一帧后
    // 阻塞等下一帧，醒来时距上次发布常常差几十微秒不到一个周期 → 这帧被跳过
    // → 下次要等两个周期 → **帧率正好砍半**（Python 版实测卡在 17.7 ≈ 30/2）。
    period_ = 0.8 / fps_;

    RCLCPP_INFO(get_logger(),
                "源 %s %ux%u stride=%u → 输出 %dx%d %s @ %.1f fps (%.2f MB/帧), "
                "autolevel=%d gain=%.2f",
                dev_.c_str(), cap_.width(), cap_.height(), cap_.stride(),
                out_w_, out_h_, mono_ ? "mono8" : "rgb8", fps_,
                msg_.data.size() / 1e6,
                static_cast<int>(autolevel_), gain_);
    return true;
  }

  void Run() {
    double t_report = Now();
    while (rclcpp::ok()) {
      // ── 排空到最新帧 ────────────────────────────────────────────────────
      // 源 30fps 而我们只处理 ~30fps 上限，队列一旦积压，取队首拿到的是最旧那帧。
      // 先把已就绪的全取出、除最后一帧外立刻归还，延迟压在一帧以内。
      // 第一次阻塞等（最多 0.5s），之后非阻塞 —— 裸循环不能忙等，
      // 红线是「相机永远让路给运动栈」。
      const double t_iter = Now();
      int idx = -1;
      uint32_t seq = 0;
      bool first = true;
      while (true) {
        uint32_t s2 = 0;
        int got = cap_.Dequeue(first ? 0.5 : 0.0, &s2);
        first = false;
        if (got < 0) break;
        ++n_dq_;
        if (idx >= 0) { cap_.Requeue(idx); ++n_stale_; }
        idx = got;
        seq = s2;
      }
      if (idx < 0) { ++n_idle_; MaybeReport(&t_report); continue; }

      const double now = Now();
      t_drain_ += now - t_iter;
      if (now - t_last_pub_ >= period_) {
        t_last_pub_ = now;
        Convert(cap_.Data(idx));
        const double t1 = Now();
        t_conv_ += t1 - now;
        Publish();
        t_pub_ += Now() - t1;
        ++n_pub_;
      }
      cap_.Requeue(idx);
      (void)seq;
      MaybeReport(&t_report);
    }
  }

  void Shutdown() { cap_.Close(); }

private:
  static double Now() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
  }

  void BuildLut(double scale) {
    for (int i = 0; i < 65536; ++i) {
      int v = i - kBlackLevel;
      if (v < 0) v = 0;
      double s = v * scale;
      lut_[i] = static_cast<uint8_t>(s > 255.0 ? 255 : s);
    }
    lut_scale_ = scale;
  }

  void Convert(const uint16_t *base) {
    const size_t stride16 = cap_.stride() / 2;

    if (autolevel_) {
      // 粗抽样估 99.5 分位：每 8 行/8 列取一个点，用 1024 桶直方图。
      // 全图排序太贵，桶直方图 O(n) 且这里的 n 只有几千。
      unsigned hist[1024] = {0};
      unsigned total = 0;
      for (int y = 0; y < out_h_; y += 8) {
        // 同样不能直接在非缓存映射上散读，先把这一行拷进来
        std::memcpy(stage_.data(),
                    reinterpret_cast<const uint8_t *>(base) +
                        static_cast<size_t>(row_[y]) * cap_.stride(),
                    cap_.stride());
        const uint16_t *r0 = stage_.data();
        for (int x = 0; x < out_w_; x += 8) {
          int v = static_cast<int>(r0[col_[x] + (mono_ ? 0 : 1)]) - kBlackLevel;
          if (v < 0) v = 0;
          hist[v >> 6]++;                 // 桶宽 64 → 覆盖 0..65535
          ++total;
        }
      }
      const unsigned cut = static_cast<unsigned>(total * 0.995);
      unsigned acc = 0;
      int bucket = 1023;
      for (int i = 0; i < 1024; ++i) {
        acc += hist[i];
        if (acc >= cut) { bucket = i; break; }
      }
      const double hi = (bucket + 1) * 64.0;
      double scale = (hi > 512.0) ? 235.0 / hi : 1.0 / 256.0;
      scale *= gain_;
      // 抖动会让查表天天重建，只在变化超过 10% 时才重建（重建 65536 项 ~0.2ms）
      if (std::abs(scale - lut_scale_) > 0.1 * std::max(scale, lut_scale_))
        BuildLut(scale);
    }

    // ⚠️⚠️ 性能命脉：**先把源行 memcpy 进缓存，再在缓存上取样**。
    //
    // V4L2 的 mmap 缓冲是给 DMA 用的非缓存映射。在它上面【逐元素标量读】
    // 慢得离谱 —— 实测 3.7M 次读要 753ms，合 203ns/次，因为每次读都是一次
    // 独立的内存事务（不进 cache line、也不合并）。顺序 memcpy 则能合成突发，
    // 实测整帧 26MB 只要 ~26ms(≈1GB/s)。差着两个数量级。
    //
    // 所以每个输出行先把用到的两条源行拷进 stage_（32KB，稳稳待在 L1/L2），
    // 再从 stage_ 上按 col_ 取样。总 memcpy 量 = out_h*2*stride ≈ 16MB。
    uint8_t *dst = msg_.data.data();
    const size_t row_bytes = cap_.stride();
    const int *col = col_.data();
    for (int y = 0; y < out_h_; ++y) {
      const uint8_t *src = reinterpret_cast<const uint8_t *>(base) +
                           static_cast<size_t>(row_[y]) * row_bytes;
      // mono 只用一条源行; rgb 用两条(Bayer 上下行)。mono 拷两行会在最后一行越界。
      std::memcpy(stage_.data(), src, row_bytes * (mono_ ? 1 : 2));
      const uint16_t *r0 = stage_.data();
      const uint16_t *r1 = r0 + stride16;
      if (mono_) {
        // 单色传感器: 逐像素 LUT 直出灰度(Bayer 标签是形式上的)
        uint8_t *o = dst + static_cast<size_t>(y) * out_w_;
        for (int x = 0; x < out_w_; ++x)
          *o++ = lut_[r0[col[x]]];
        continue;
      }
      uint8_t *o = dst + static_cast<size_t>(y) * out_w_ * 3;
      for (int x = 0; x < out_w_; ++x) {
        const int c = col[x];
        // RGGB：R=(0,0) Gr=(0,1) Gb=(1,0) B=(1,1)。
        // 绿色只取 Gr 一路、不与 Gb 求平均 —— 省一次访存，噪声高 √2 倍肉眼看不出。
        *o++ = lut_[r0[c]];
        *o++ = lut_[r0[c + 1]];
        *o++ = lut_[r1[c + 1]];
      }
    }
  }

  void BuildCameraInfo() {
    // ⚠️ 出厂标定在 /opt/ros2/cyberdog/share/athena_tracking/config/camera_AI.yaml，
    // 是 **MEI(全向)模型** @1280x960: gamma1=674.669 gamma2=682.214
    // u0=646.499 v0=497.005, xi=0.176364, k1/k2/p1/p2 见文件。
    // ROS 的 CameraInfo 没有 MEI，这里放的是把出厂焦距/主点按分辨率线性缩放
    // 得到的 **针孔近似**，畸变留 0 —— 够 rviz/预览，**不够做精确几何**。
    // ⚠️ 首选【这台狗的产线个体标定】：/params/camera/*.yaml(2021-08-27 产线
    // MEI 标定, 检验 flag 全 1), 由宿主启动器解析并按 f=gamma/(1+xi) 换算成
    // 针孔近似后经 AI_CAM_FX/FY/CX/CY 传入(标定分辨率坐标系, 这里按输出缩放)。
    // 个体值与 share 里那份通用参考差别很大(主摄 xi 连符号都不同), 别用通用值。
    double fx = EnvDbl("AI_CAM_FX", 0.0), fy = EnvDbl("AI_CAM_FY", 0.0);
    double cx = EnvDbl("AI_CAM_CX", 0.0), cy = EnvDbl("AI_CAM_CY", 0.0);
    const double calw = EnvDbl("AI_CAM_CAL_W", mono_ ? 640.0 : 1280.0);
    const double calh = EnvDbl("AI_CAM_CAL_H", mono_ ? 480.0 : 960.0);
    if (fx > 0.0 && fy > 0.0) {
      const double sx = out_w_ / calw, sy = out_h_ / calh;
      fx *= sx; fy *= sy; cx *= sx; cy *= sy;
    } else if (mono_) {
      // 兜底占位(没拿到个体标定时): 只够预览
      fx = fy = out_w_ * 0.6;
      cx = out_w_ / 2.0;
      cy = out_h_ / 2.0;
    } else {
      // 兜底: share 里的通用参考值(样机标定), 按分辨率缩放
      const double sx = out_w_ / 1280.0, sy = out_h_ / 960.0;
      fx = 674.669 * sx; fy = 682.214 * sy;
      cx = 646.499 * sx; cy = 497.005 * sy;
    }
    info_.header.frame_id = frame_id_;
    info_.height = static_cast<uint32_t>(out_h_);
    info_.width = static_cast<uint32_t>(out_w_);
    info_.distortion_model = "plumb_bob";
    info_.d.assign(5, 0.0);
    info_.k = {fx, 0, cx, 0, fy, cy, 0, 0, 1};
    info_.r = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    info_.p = {fx, 0, cx, 0, 0, fy, cy, 0, 0, 0, 1, 0};
  }

  void Publish() {
    const auto stamp = now();
    msg_.header.stamp = stamp;
    pub_img_->publish(msg_);
    // camera_info 是静态的，每帧都发纯属浪费一次 DDS 写；1Hz 足够。
    if (stamp.seconds() - ci_last_ >= 1.0) {
      ci_last_ = stamp.seconds();
      info_.header.stamp = stamp;
      pub_info_->publish(info_);
    }
  }

  void MaybeReport(double *t_report) {
    const double t = Now();
    if (t - *t_report < 10.0) return;
    const double dt = t - *t_report;
    const double k = n_pub_ > 0 ? n_pub_ : 1;
    RCLCPP_INFO(get_logger(),
                "取 %.1f fps / 发 %.1f fps (丢弃过期 %ld / 空转 %ld) "
                "| 每帧: 排空 %.1fms 转换 %.1fms 发布 %.1fms",
                n_dq_ / dt, n_pub_ / dt, n_stale_, n_idle_,
                t_drain_ * 1000 / k, t_conv_ * 1000 / k, t_pub_ * 1000 / k);
    n_dq_ = n_pub_ = n_stale_ = n_idle_ = 0;
    t_drain_ = t_conv_ = t_pub_ = 0.0;
    *t_report = t;
  }

  V4L2Capture cap_;
  std::string dev_, frame_id_;
  int out_w_ = 1280, out_h_ = 960;
  double fps_ = 30.0, gain_ = 1.0, period_ = 0.0;
  bool autolevel_ = true;
  bool mono_ = false;
  std::vector<int> row_, col_;
  std::vector<uint8_t> lut_;
  std::vector<uint16_t> stage_;   // 两条源行的暂存区
  double lut_scale_ = 0.0;
  double t_last_pub_ = 0.0, ci_last_ = 0.0;
  long n_dq_ = 0, n_pub_ = 0, n_stale_ = 0, n_idle_ = 0;
  double t_drain_ = 0.0, t_conv_ = 0.0, t_pub_ = 0.0;
  sensor_msgs::msg::Image msg_;
  sensor_msgs::msg::CameraInfo info_;
  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr pub_img_;
  rclcpp::Publisher<sensor_msgs::msg::CameraInfo>::SharedPtr pub_info_;
};

}  // namespace

int main(int argc, char **argv) {
  rclcpp::init(argc, argv);
  auto node = std::make_shared<AiCameraNode>();
  int rc = 0;
  if (node->Init()) {
    node->Run();
  } else {
    rc = 1;
  }
  node->Shutdown();
  rclcpp::shutdown();
  return rc;
}
