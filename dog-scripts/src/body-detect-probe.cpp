// =============================================================================
//  出厂人体检测 SDK 在 JP5 上的可调用性验证
//  部署: /mnt/jp4/opt/ai-camera/body-detect-probe   (chroot 内)
//  构建: dog-scripts/bin/body-detect-build.sh
//
//  ── 为什么写这个 ──────────────────────────────────────────────────────────
//  2026-07-29 实测 trtexec 在 JP5 上加载出厂 .engine 全部 PASSED
//  (人体检测 16.0ms/50qps、分类 3.16ms、ReID 3.94ms，且三路相机同时满速)。
//  ⇒ 不需要拿 YOLO 重写视觉链，直接调出厂 SDK 就行。
//  这个程序验证的是**下一层**：TensorRT 能跑 ≠ 出厂 SDK 的封装能在 JP5 上初始化。
//  SDK 内部除了 TRT 还可能碰 EGL/NvBuf/argus —— 那些正是 JP5 上的雷区。
//
//  API 契约来自狗上自带的 Apache-2.0 头文件:
//    /opt/ros2/cyberdog/include/athena_vision/{algorithm,body_detect_api}.h
//      AlgoHandle body_detect_init();
//      bool body_detect(AlgoHandle, BufferInfo*, std::vector<SingleBodyInfo>&);
//      void body_detect_destroy(AlgoHandle);
//    BufferInfo{ void* data; uint32_t width, height; Format format; }
//    SingleBodyInfo{ std::string id; Rect rect; std::vector<float> feats; float score; }
//  ⇒ 我们的相机桥直出的 rgb8 可以**原样**当 BufferInfo.data 喂进去。
//
//  用法:
//    body-detect-probe                 # 用合成图(仅验证 init/调用不崩)
//    body-detect-probe <file.ppm>      # 用真实图(P6 二进制 PPM, 即相机抓的帧)
// =============================================================================
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "athena_vision/algorithm.h"
#include "athena_vision/body_detect_api.h"

namespace {

double NowMs() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

// 读 P6 二进制 PPM（相机抓帧存的就是这个格式）。成功返回 true。
bool LoadPPM(const std::string &path, std::vector<uint8_t> *rgb,
             uint32_t *w, uint32_t *h) {
  std::ifstream f(path, std::ios::binary);
  if (!f) { printf("  打不开 %s\n", path.c_str()); return false; }
  std::string magic;
  int maxval = 0;
  f >> magic;
  if (magic != "P6") { printf("  不是 P6 PPM (是 %s)\n", magic.c_str()); return false; }
  int iw = 0, ih = 0;
  f >> iw >> ih >> maxval;
  f.get();                       // 吃掉头部后的单个空白字符
  if (iw <= 0 || ih <= 0 || maxval != 255) {
    printf("  头部异常 %dx%d maxval=%d\n", iw, ih, maxval);
    return false;
  }
  rgb->resize(static_cast<size_t>(iw) * ih * 3);
  f.read(reinterpret_cast<char *>(rgb->data()), rgb->size());
  if (static_cast<size_t>(f.gcount()) != rgb->size()) {
    printf("  数据不足: 期望 %zu 实得 %zd\n", rgb->size(), f.gcount());
    return false;
  }
  *w = static_cast<uint32_t>(iw);
  *h = static_cast<uint32_t>(ih);
  return true;
}

}  // namespace

int main(int argc, char **argv) {
  printf("════ 出厂人体检测 SDK @ JP5 验证 ════\n");

  std::vector<uint8_t> rgb;
  uint32_t w = 0, h = 0;
  if (argc > 1) {
    if (!LoadPPM(argv[1], &rgb, &w, &h)) return 2;
    printf("① 输入: %s  %ux%u rgb8 (%zu 字节)\n", argv[1], w, h, rgb.size());
  } else {
    // 合成图：不指望检出人，只验证调用链不崩
    w = 1280; h = 960;
    rgb.assign(static_cast<size_t>(w) * h * 3, 96);
    printf("① 输入: 合成灰图 %ux%u rgb8\n", w, h);
  }

  printf("② body_detect_init() ... ");
  fflush(stdout);
  const double t0 = NowMs();
  AlgoHandle handle = body_detect_init();
  const double t1 = NowMs();
  if (handle == nullptr) {
    printf("❌ 返回 NULL（SDK 初始化失败）\n");
    return 3;
  }
  printf("✅ handle=%p  耗时 %.0f ms\n", handle, t1 - t0);

  BufferInfo buf{};
  buf.data = rgb.data();
  buf.width = w;
  buf.height = h;
  buf.format = FORMAT_RGB;      // 相机桥直出 rgb8，正好对上

  // 跑 5 次：第 1 次含 lazy 初始化，后 4 次才是稳态延迟
  int ok_count = 0;
  double warm = 0.0, steady = 0.0;
  std::vector<SingleBodyInfo> bodies;
  for (int i = 0; i < 5; ++i) {
    bodies.clear();
    const double a = NowMs();
    const bool ok = body_detect(handle, &buf, bodies);
    const double dt = NowMs() - a;
    if (i == 0) warm = dt; else steady += dt / 4.0;
    if (ok) ++ok_count;
    printf("③ 第 %d 次 body_detect() → %s, %zu 个目标, %.1f ms\n",
           i + 1, ok ? "true" : "false", bodies.size(), dt);
  }

  printf("④ 稳态延迟 %.1f ms (首次 %.1f ms 含初始化) → 上限 %.1f fps\n",
         steady, warm, steady > 0 ? 1000.0 / steady : 0.0);

  for (size_t i = 0; i < bodies.size(); ++i) {
    const SingleBodyInfo &b = bodies[i];
    printf("   目标%zu id=\"%s\" rect=(%u,%u,%ux%u) score=%.3f feats=%zu 维\n",
           i, b.id.c_str(), b.rect.left, b.rect.top, b.rect.width, b.rect.height,
           b.score, b.feats.size());
  }
  if (bodies.empty())
    printf("   （0 个目标：画面里没人时这是正常的；调用链本身已验证）\n");

  body_detect_destroy(handle);
  printf("⑤ destroy 完成\n");
  printf("════ 判决: %s ════\n",
         ok_count == 5 ? "✅ 出厂视觉 SDK 在 JP5 上可直接调用"
                       : "⚠️ 调用有失败，看上面逐次结果");
  return ok_count == 5 ? 0 : 1;
}
