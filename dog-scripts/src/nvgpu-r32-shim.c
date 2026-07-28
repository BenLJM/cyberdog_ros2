/* nvgpu-r32-shim —— 让 JP4(R32) 用户态的 EGL/argus 在 JP5(R35) 内核上跑起来
 * ===========================================================================
 * 2026-07-28 定位过程：
 *   出厂 camera_server 拍照返回 RESULT_INVALID_STATE，追进去发现是
 *   `ArgusCameraContext::takePicture()` 头一句 `if (!m_isStreaming)` ——
 *   真正的崩溃在 START_LIVE_STREAM 时：
 *       SCF: Error InsufficientMemory: Unable to initialize EGL (GLService.cpp:144)
 *       → createCameraProvider 失败 → assert(m_initialized) → 进程 abort
 *
 *   把 EGL 单独拎出来用 ctypes 探针测：eglInitialize 返回 EGL_BAD_ACCESS。
 *   strace 差分(R32 用户态 vs R35 用户态，同一颗内核)显示整条 EGL 初始化链上
 *   11 个 'G' 类 nvgpu ioctl 逐条一致，**只差最后一个**：
 *
 *       R32 用户态: _IOC(RW, 'G', 8, 0x10)  → ENOTTY   ← 16 字节
 *       R35 用户态: _IOC(RW, 'G', 8, 0x40)  → 0        ← 64 字节
 *
 *   即 NVGPU_GPU_IOCTL_ALLOC_AS 的 struct nvgpu_alloc_as_args 从 R32 的 16 字节
 *   涨到 R35 的 64 字节。ioctl 号把 size 编进去了，所以内核 switch(cmd) 直接落到
 *   default → ENOTTY。整个 GPU/EGL/argus 栈就卡死在这一个 ioctl 上。
 *
 * 本 shim 拦截 ioctl()，把 16 字节的 R32 请求翻译成 64 字节的 R35 请求。
 *
 * 【为什么不能简单零填充】R35 内核 common/mm/as.c:95 起对 va_range_start/end
 *   为零一律 -EINVAL。所以必须补出合法区间 —— 取值来自实测：在宿主上 LD_PRELOAD
 *   dump 了 R35 自己的 libnvrm_gpu 传的那 64 字节(见下方常量)。
 *
 * 编译(必须在 chroot 内，链 JP4 的 glibc):
 *   gcc -shared -fPIC -O2 -o /opt/nvgpu-r32-shim.so nvgpu-r32-shim.c -ldl
 * 使用:
 *   LD_PRELOAD=/opt/nvgpu-r32-shim.so <程序>
 *   NVGPU_R32_SHIM_DEBUG=1 时往 stderr 打诊断
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <asm/ioctl.h>

#define NVGPU_GPU_MAGIC    'G'   /* /dev/nvhost-ctrl-gpu */
#define NVGPU_AS_MAGIC     'A'   /* ALLOC_AS 返回的地址空间 fd */
#define NVGPU_CH_MAGIC     'H'   /* 通道 fd */

#define NR_ALLOC_AS        8
#define R32_ALLOC_AS_SIZE  16
#define R35_ALLOC_AS_SIZE  64

#define NR_ALLOC_SPACE     6
#define R32_ALLOC_SPACE_SZ 24
#define R35_ALLOC_SPACE_SZ 32

/* R35 内核实测接受的 VA 区间(宿主 R35 用户态原样传的值)。
 * 内核校验: 非零 + PDE 对齐 + start < end; UNIFIED_VA 下 split 必须为 0。 */
#define R35_VA_RANGE_START 0x4000000ULL       /* 64 MiB   */
#define R35_VA_RANGE_END   0x2000000000ULL    /* 128 GiB  */
#define FLAG_USERSPACE_MANAGED (1U << 0)
#define FLAG_UNIFIED_VA        (1U << 1)

/* R32: { u32 big_page_size; s32 as_fd; u64 flags; } —— 也可能是 u32 flags+u32 reserved，
 * 小端下两种布局的有效标志位都落在偏移 8 的那个 u32，故本 shim 对两者都成立。 */
struct r32_args {
    uint32_t big_page_size;
    int32_t  as_fd;
    uint32_t flags;
    uint32_t flags_hi_or_reserved;
};

struct r35_args {
    uint32_t big_page_size;
    int32_t  as_fd;
    uint32_t flags;
    uint32_t reserved;
    uint64_t va_range_start;
    uint64_t va_range_end;
    uint64_t va_range_split;
    uint32_t padding[6];
};

/* --- NVGPU_AS_IOCTL_ALLOC_SPACE ('A' nr=6): pages 从 u32 拓宽到 u64，
 *     后面的字段整体挪位。o_a 两边都在偏移 16，且是 inout。 --- */
struct r32_alloc_space {
    uint32_t pages;       /* @0  */
    uint32_t page_size;   /* @4  */
    uint32_t flags;       /* @8  */
    uint32_t padding;     /* @12 */
    uint64_t o_a;         /* @16 inout: offset(FIXED_OFFSET 时) 或 align */
};

struct r35_alloc_space {
    uint64_t pages;       /* @0  */
    uint32_t page_size;   /* @8  */
    uint32_t flags;       /* @12 */
    uint64_t o_a;         /* @16 */
    uint32_t padding[2];  /* @24 */
};

static int (*real_ioctl)(int, unsigned long, ...);
static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static FILE *(*real_fopen)(const char *, const char *);
static FILE *(*real_fopen64)(const char *, const char *);
static int (*real_access)(const char *, int);
static int dbg = -1;

/* ---------------------------------------------------------------------------
 * tegra_fuse sysfs 补位
 *
 * R32 的 libnvrm 依次找:
 *     /sys/module/tegra_fuse/parameters/{tegra_chip_id,tegra_chip_rev,tegra_platform}
 *     /sys/module/fuse/parameters/{同上}
 * chip_id / chip_rev 找不到还能回落到 /sys/devices/soc0/{soc_id,revision}，
 * 但 **tegra_platform 没有回落**  → 打 "NvRmPrivGetChipPlatform: Could not read
 * platform information"，libnvscf 随后 "Unknown HW element! Using default
 * settings!" → "Tegra chip ID not supported"(PowerServiceHwIsp.cpp:74)。
 *
 * R35 内核没有 tegra_fuse 这个模块，但同样的信息在 /sys/devices/soc0/ 下都有
 * (soc_id=25=0x19=T194, platform=0=silicon, revision=A02)。这里把 R32 找的路径
 * 重定向到由 nvgpu-r32-compat-setup.sh 依据 soc0 生成的真实文件。
 * ------------------------------------------------------------------------- */
/* ---------------------------------------------------------------------------
 * 设备树属性覆盖（AI 相机 PCL 前置）
 *
 * 2026-07-28: 出厂 camera_server 拍不出照的最后一环 —— PCL 读不到任何传感器模块:
 *     NvPclHwGetModuleList: WARNING: Could not map module to ISP config string
 *     NvPclHwGetModuleList: No module data found      ← 三个模块全军覆没
 * 根因是 `position` 属性。libnvodm_imager.so 里位置名是个【固定集合】:
 *     bottom / center / centerleft / centerright / front / rear
 * 而我们移植的 DTB 用的是 NVIDIA P2151 参考板写法 "0"/"1"/"2" —— 映射不上,
 * 模块被丢弃 ⇒ 没人给 ov13b10 上电 ⇒ MIPI 无数据 ⇒ waitCsiFrameEnd 超时。
 * 出厂 DTB 用的是 position="bottom"、badge="ov13b10_bottom_RBP194"。
 *
 * /proc/device-tree 改不了,所以这里按同样的相对路径从 COMPAT_DIR/dt/ 下取覆盖值
 * (⚠️ DT 属性是 NUL 结尾的字符串,覆盖文件必须照样带结尾 NUL)。
 * 这是运行时验证/兜底;正解是修 DTB 源码里的 tegra-camera-platform 节点。
 * ------------------------------------------------------------------------- */
#define COMPAT_DIR "/opt/nvgpu-r32-compat"
#define DT_PREFIX  "/proc/device-tree/"

/* remap() 判断覆盖文件是否存在时【必须】走真 access —— 本 shim 自己也拦了
 * access(),直接调会绕回自己造成递归。 */
static int real_access_ok(const char *p)
{
    if (!real_access) real_access = dlsym(RTLD_NEXT, "access");
    return real_access(p, R_OK) == 0;
}

static const char *remap(const char *path)
{
    static const char *const names[] = {
        "tegra_chip_id", "tegra_chip_rev", "tegra_platform", NULL
    };
    static char buf[512];
    const char *tail;
    int i;

    if (!path) return NULL;

    if (strncmp(path, DT_PREFIX, sizeof(DT_PREFIX) - 1) == 0) {
        snprintf(buf, sizeof(buf), "%s/dt/%s", COMPAT_DIR,
                 path + sizeof(DT_PREFIX) - 1);
        return real_access_ok(buf) ? buf : NULL;
    }

    if (strncmp(path, "/sys/module/tegra_fuse/parameters/", 34) == 0)
        tail = path + 34;
    else if (strncmp(path, "/sys/module/fuse/parameters/", 28) == 0)
        tail = path + 28;
    else
        return NULL;

    for (i = 0; names[i]; i++) {
        if (strcmp(tail, names[i]) == 0) {
            snprintf(buf, sizeof(buf), "%s/%s", COMPAT_DIR, names[i]);
            /* 只补真正准备了的那几个。没准备的一律放行走原路径 —— chip_id/chip_rev
             * 本来就能正确回落到 /sys/devices/soc0/{soc_id,revision}，硬塞反而
             * 可能塞错值。改什么由 COMPAT_DIR 里放了什么决定。 */
            return real_access_ok(buf) ? buf : NULL;
        }
    }
    return NULL;
}

static void dbg_init(void)
{
    if (dbg < 0) {
        const char *e = getenv("NVGPU_R32_SHIM_DEBUG");
        dbg = (e && *e == '1') ? 1 : 0;
    }
}

/* open 家族：只对上面那几条 tegra_fuse 路径改道，其余原样放行。
 * 注意 glibc 内部调用(如 fopen→__open64)不走 PLT，拦不到；实测 libnvrm 用的是
 * open()/openat()，能覆盖。 */
#define REMAP_BODY(realfn, callexpr)                                          \
    do {                                                                      \
        const char *rp = remap(path);                                         \
        if (rp) {                                                             \
            if (dbg < 0) dbg_init();                                          \
            if (dbg) fprintf(stderr, "[nvgpu-r32-shim] 改道 %s → %s\n",       \
                             path, rp);                                       \
            path = rp;                                                        \
        }                                                                     \
        return callexpr;                                                      \
    } while (0)

int open(const char *path, int flags, ...)
{
    va_list ap; mode_t m;
    va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap);
    if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
    REMAP_BODY(real_open, real_open(path, flags, m));
}

int open64(const char *path, int flags, ...)
{
    va_list ap; mode_t m;
    va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap);
    if (!real_open64) real_open64 = dlsym(RTLD_NEXT, "open64");
    REMAP_BODY(real_open64, real_open64(path, flags, m));
}

int openat(int dirfd, const char *path, int flags, ...)
{
    va_list ap; mode_t m;
    va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap);
    if (!real_openat) real_openat = dlsym(RTLD_NEXT, "openat");
    REMAP_BODY(real_openat, real_openat(dirfd, path, flags, m));
}

/* fopen 家族：libnvodm_imager 读设备树属性走的是 fopen 而不是 open —— 只拦
 * open/openat 的话 `cat` 能改道、它却不受影响,查这个花了一轮。access 一并拦,
 * 它用来探 <badge>.bin 之类文件是否存在。 */
FILE *fopen(const char *path, const char *mode)
{
    const char *rp = remap(path);
    if (!real_fopen) real_fopen = dlsym(RTLD_NEXT, "fopen");
    if (rp && dbg) fprintf(stderr, "[nvgpu-r32-shim] 改道(fopen) %s → %s\n", path, rp);
    return real_fopen(rp ? rp : path, mode);
}

FILE *fopen64(const char *path, const char *mode)
{
    const char *rp = remap(path);
    if (!real_fopen64) real_fopen64 = dlsym(RTLD_NEXT, "fopen64");
    if (rp && dbg) fprintf(stderr, "[nvgpu-r32-shim] 改道(fopen64) %s → %s\n", path, rp);
    return real_fopen64(rp ? rp : path, mode);
}

int access(const char *path, int mode)
{
    const char *rp = remap(path);   /* remap 内部走 real_access_ok(),不会绕回这里 */
    if (!real_access) real_access = dlsym(RTLD_NEXT, "access");
    return real_access(rp ? rp : path, mode);
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    void *arg;

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (!real_ioctl) real_ioctl = dlsym(RTLD_NEXT, "ioctl");

    dbg_init();

    /* ---- 'G' nr=8 NVGPU_GPU_IOCTL_ALLOC_AS : 16 → 64 字节 ---- */
    if (_IOC_TYPE(req) == NVGPU_GPU_MAGIC && _IOC_NR(req) == NR_ALLOC_AS &&
        _IOC_SIZE(req) == R32_ALLOC_AS_SIZE && arg != NULL) {
        struct r32_args *in = (struct r32_args *)arg;
        struct r35_args out;
        unsigned long r35_req = _IOC(_IOC_READ | _IOC_WRITE, NVGPU_GPU_MAGIC,
                                     NR_ALLOC_AS, R35_ALLOC_AS_SIZE);
        int r;

        memset(&out, 0, sizeof(out));
        out.big_page_size = in->big_page_size;
        out.as_fd         = in->as_fd;
        /* R32 没有 UNIFIED_VA 这个概念；R35 内核在非 unified 路径下要求给出
         * va_range_split，而 R32 用户态永远不会提供它 → 只能走 unified。
         * 这也正是 R35 自家用户态的做法(实测 flags=0x2)。 */
        out.flags          = (in->flags & FLAG_USERSPACE_MANAGED) | FLAG_UNIFIED_VA;
        out.va_range_start = R35_VA_RANGE_START;
        out.va_range_end   = R35_VA_RANGE_END;
        out.va_range_split = 0;   /* UNIFIED_VA 下内核要求为 0 */

        r = real_ioctl(fd, r35_req, &out);
        if (r == 0) in->as_fd = out.as_fd;

        if (dbg)
            fprintf(stderr,
                    "[nvgpu-r32-shim] ALLOC_AS 16→64 fd=%d bps=0x%x "
                    "flags 0x%x→0x%x  ⇒ rc=%d as_fd=%d\n",
                    fd, in->big_page_size, in->flags, out.flags, r, in->as_fd);
        return r;
    }

    /* ---- 'A' nr=6 NVGPU_AS_IOCTL_ALLOC_SPACE : 24 → 32 字节 ----
     * R35 把 pages 从 u32 拓宽到 u64，page_size/flags 因此各后移 4 字节。
     * o_a 两边同在偏移 16，是 inout（FIXED_OFFSET 时回填分配到的地址）。 */
    if (_IOC_TYPE(req) == NVGPU_AS_MAGIC && _IOC_NR(req) == NR_ALLOC_SPACE &&
        _IOC_SIZE(req) == R32_ALLOC_SPACE_SZ && arg != NULL) {
        struct r32_alloc_space *in = (struct r32_alloc_space *)arg;
        struct r35_alloc_space out;
        unsigned long r35_req = _IOC(_IOC_READ | _IOC_WRITE, NVGPU_AS_MAGIC,
                                     NR_ALLOC_SPACE, R35_ALLOC_SPACE_SZ);
        int r;

        memset(&out, 0, sizeof(out));
        out.pages     = (uint64_t)in->pages;
        out.page_size = in->page_size;
        out.flags     = in->flags;
        out.o_a       = in->o_a;

        r = real_ioctl(fd, r35_req, &out);
        if (r == 0) in->o_a = out.o_a;      /* inout 回填 */

        if (dbg)
            fprintf(stderr,
                    "[nvgpu-r32-shim] ALLOC_SPACE 24→32 fd=%d pages=%u psz=%u "
                    "flags=0x%x o_a=0x%llx ⇒ rc=%d o_a=0x%llx\n",
                    fd, in->pages, in->page_size, in->flags,
                    (unsigned long long)out.o_a, r,
                    (unsigned long long)in->o_a);
        return r;
    }

    {
        int r = real_ioctl(fd, req, arg);
        /* 诊断：还有哪些 nvgpu ioctl 因 ABI 变更被内核拒掉(ENOTTY=switch 落 default)。
         * 只在 DEBUG 下打，用来一次看清还剩几堵墙，不必一堵一堵试。 */
        if (dbg && r == -1) {
            unsigned t = _IOC_TYPE(req);
            if (t == NVGPU_GPU_MAGIC || t == NVGPU_AS_MAGIC || t == NVGPU_CH_MAGIC)
                fprintf(stderr,
                        "[nvgpu-r32-shim] ⚠️ 未翻译 '%c' nr=%u size=%u fd=%d 被拒\n",
                        (char)t, (unsigned)_IOC_NR(req),
                        (unsigned)_IOC_SIZE(req), fd);
        }
        return r;
    }
}
