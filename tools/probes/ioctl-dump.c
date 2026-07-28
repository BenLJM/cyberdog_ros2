/* ioctl 拦截器 —— 抓 nvgpu 'G' 类 ALLOC_AS(nr=8) 的真实入参/出参
 *
 * 目的：R32 用户态发 16 字节的 ALLOC_AS，R35 内核只认 64 字节 → ENOTTY → EGL 起不来。
 * 要写翻译层就得知道 R35 用户态到底往那 64 字节里填了什么(尤其 va_range_start/end/split
 * —— 内核对它们为零直接 -EINVAL，见 common/mm/as.c:95)。这里在宿主(R35 用户态)上原样 dump。
 *
 * 编译: gcc -shared -fPIC -O2 -o ioctl-dump.so ioctl-dump.c -ldl
 * 使用: LD_PRELOAD=./ioctl-dump.so <程序>
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <asm/ioctl.h>

static int (*real_ioctl)(int, unsigned long, ...);

static void dump(const char *tag, const unsigned char *p, unsigned n)
{
    fprintf(stderr, "IOCTLDUMP %s [%u字节]:", tag, n);
    for (unsigned i = 0; i < n; i++) {
        if (i % 8 == 0) fprintf(stderr, "\n  +%02u:", i);
        fprintf(stderr, " %02x", p[i]);
    }
    fprintf(stderr, "\n");
    /* 按 R35 struct nvgpu_alloc_as_args 解读 */
    if (n >= 40) {
        const uint32_t *u32 = (const uint32_t *)p;
        const uint64_t *u64 = (const uint64_t *)(p + 16);
        fprintf(stderr,
                "  解读: big_page_size=0x%x as_fd=%d flags=0x%x reserved=0x%x\n"
                "        va_range_start=0x%llx va_range_end=0x%llx va_range_split=0x%llx\n",
                u32[0], (int)u32[1], u32[2], u32[3],
                (unsigned long long)u64[0], (unsigned long long)u64[1],
                (unsigned long long)u64[2]);
    }
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    void *arg;
    int r;

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (!real_ioctl) real_ioctl = dlsym(RTLD_NEXT, "ioctl");

    int hit = (_IOC_TYPE(req) == 'G' && _IOC_NR(req) == 8);
    if (hit) {
        fprintf(stderr, "IOCTLDUMP === ALLOC_AS fd=%d size=%u ===\n", fd, _IOC_SIZE(req));
        dump("入参", arg, _IOC_SIZE(req));
    }

    r = real_ioctl(fd, req, arg);

    if (hit) {
        dump("出参", arg, _IOC_SIZE(req));
        fprintf(stderr, "IOCTLDUMP 返回=%d\n", r);
    }
    return r;
}
