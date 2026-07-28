#!/usr/bin/env python3
"""CUDA 初始化探针 —— EGL 打通后的下一堵墙。

libargus 的 SCF 在 GLService 之后启动 CudaService，那里 cuInit 返回
CUDA_ERROR_UNKNOWN(999)，被笼统报成 "NotSupported"。这里直接调 cuInit
拿到真实错误码，再配合 strace 定位是哪个 ioctl 谈不拢。
"""
import ctypes
import sys

CUDA_ERRS = {
    0: "CUDA_SUCCESS", 3: "CUDA_ERROR_NOT_INITIALIZED",
    100: "CUDA_ERROR_NO_DEVICE", 101: "CUDA_ERROR_INVALID_DEVICE",
    200: "CUDA_ERROR_INVALID_IMAGE", 201: "CUDA_ERROR_INVALID_CONTEXT",
    304: "CUDA_ERROR_OPERATING_SYSTEM", 802: "CUDA_ERROR_SYSTEM_NOT_READY",
    803: "CUDA_ERROR_SYSTEM_DRIVER_MISMATCH", 999: "CUDA_ERROR_UNKNOWN",
}


def main():
    try:
        cu = ctypes.CDLL("libcuda.so.1")
    except OSError as e:
        print("  ✗ 加载 libcuda.so.1 失败: %s" % e)
        return 1

    rc = cu.cuInit(0)
    print("  cuInit(0) -> %s(%d)" % (CUDA_ERRS.get(rc, "未知"), rc))
    if rc != 0:
        return 1

    ver = ctypes.c_int(0)
    cu.cuDriverGetVersion(ctypes.byref(ver))
    n = ctypes.c_int(0)
    cu.cuDeviceGetCount(ctypes.byref(n))
    print("  驱动版本=%d  设备数=%d" % (ver.value, n.value))
    print("  🏆 CUDA 可用")
    return 0


if __name__ == "__main__":
    sys.exit(main())
