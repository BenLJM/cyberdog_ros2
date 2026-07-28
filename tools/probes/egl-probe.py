#!/usr/bin/env python3
"""EGL 初始化探针 —— 在 chroot(JP4 R32 用户态) 里直接问 EGL 本人为什么起不来。

libargus 的 SCF GLService 在 createCameraProvider() 里初始化 EGL，失败会被
笼统地报成 "InsufficientMemory"，什么信息都没有。这里直接调 eglInitialize
并读 eglGetError()，把真实错误码挖出来。

对照两种环境：出厂栈设的 DISPLAY=:0（日志里那句 "No protocol specified" 的来源）
vs 无 DISPLAY 的纯 headless。
"""
import ctypes
import os
import sys

EGL_ERRS = {
    0x3000: "EGL_SUCCESS", 0x3001: "EGL_NOT_INITIALIZED", 0x3002: "EGL_BAD_ACCESS",
    0x3003: "EGL_BAD_ALLOC", 0x3004: "EGL_BAD_ATTRIBUTE", 0x3005: "EGL_BAD_CONFIG",
    0x3006: "EGL_BAD_CONTEXT", 0x3007: "EGL_BAD_CURRENT_SURFACE",
    0x3008: "EGL_BAD_DISPLAY", 0x3009: "EGL_BAD_MATCH", 0x300A: "EGL_BAD_NATIVE_PIXMAP",
    0x300B: "EGL_BAD_NATIVE_WINDOW", 0x300C: "EGL_BAD_PARAMETER",
    0x300D: "EGL_BAD_SURFACE", 0x300E: "EGL_CONTEXT_LOST",
}
EGL_VENDOR, EGL_VERSION, EGL_EXTENSIONS = 0x3053, 0x3054, 0x3055


def probe(tag):
    out = ["── %s (DISPLAY=%r) ──" % (tag, os.environ.get("DISPLAY"))]
    try:
        egl = ctypes.CDLL("libEGL.so.1")
    except OSError as e:
        out.append("  ✗ 加载 libEGL.so.1 失败: %s" % e)
        return "\n".join(out)

    egl.eglGetDisplay.restype = ctypes.c_void_p
    egl.eglGetDisplay.argtypes = [ctypes.c_void_p]
    egl.eglInitialize.argtypes = [ctypes.c_void_p,
                                  ctypes.POINTER(ctypes.c_int),
                                  ctypes.POINTER(ctypes.c_int)]
    egl.eglQueryString.restype = ctypes.c_char_p
    egl.eglQueryString.argtypes = [ctypes.c_void_p, ctypes.c_int]

    def err():
        e = egl.eglGetError()
        return "%s(0x%x)" % (EGL_ERRS.get(e, "未知"), e)

    # 客户端扩展（display 为 NULL 时可查）——能看出 GLVND 找没找到厂商 ICD
    cext = egl.eglQueryString(None, EGL_EXTENSIONS)
    out.append("  客户端扩展: %s" % (cext.decode()[:150] if cext else "(空)"))

    dpy = egl.eglGetDisplay(None)          # EGL_DEFAULT_DISPLAY
    out.append("  eglGetDisplay(DEFAULT) -> %s   err=%s" %
               (hex(dpy) if dpy else "EGL_NO_DISPLAY", err()))
    if not dpy:
        return "\n".join(out)

    major, minor = ctypes.c_int(0), ctypes.c_int(0)
    ok = egl.eglInitialize(dpy, ctypes.byref(major), ctypes.byref(minor))
    out.append("  eglInitialize -> %s   err=%s" % ("成功" if ok else "失败", err()))
    if ok:
        out.append("  EGL %d.%d  vendor=%s" % (
            major.value, minor.value,
            (egl.eglQueryString(dpy, EGL_VENDOR) or b"?").decode()))
        out.append("  🏆 EGL 可用")
    return "\n".join(out)


if __name__ == "__main__":
    print(probe(sys.argv[1] if len(sys.argv) > 1 else "probe"))
