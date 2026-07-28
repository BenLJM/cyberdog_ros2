#!/usr/bin/env python3
"""在【已编译好的 DTB 反编译出来的 DTS】上做相机 modules 块手术。

用途：变体 J（stage1-5 全套 r32 补丁）的 DTB 是用它自己那套 DTS 改动编出来的，
当前内核树已经把那些改动还原了，重新走源码路线会得到不同的 DTB。
所以这里直接对 J 的 DTB 反编译产物动刀 —— 保证与 J 的差异【只有相机 modules 块】。

改动内容与 build/dtb-camera-modules.py 完全一致（见那份的详细说明）：
  module0 = ov13b10(bottom) / module1 = ov7251@61(center) / module2 = ov7251@62(front)
badge 必须含 libnvodm_imager 认识的位置名，它按 badge 子串匹配位置、
并按 <badge>.isp 去 /var/nvidia/nvcam/settings/ 找 ISP 配置。

用法: python3 dtb-camera-modules-dts.py <in.dts> <out.dts>
"""
import re
import sys

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

src = open(sys.argv[1]).read()
if "RBP194" in src:
    print("FATAL: 已经含 RBP194，别重复打")
    sys.exit(1)

# 锚点：tegra-camera-platform 里的 modules { ... };
m = re.search(r"(?ms)^(\t+)modules \{\n.*?^\1\};\n", src)
assert m, "找不到 modules 块"
old, ind = m.group(0), m.group(1)
assert "ov13b10_2_P2151X" in old, "锚点内容不是预期的参考板 badge"
assert old.count("module0 {") == 1 and old.count("module2 {") == 1, "模块结构异常"

i1, i2, i3, i4 = ind + "\t", ind + "\t\t", ind + "\t\t\t", ind + "\t\t\t\t"

MODULES = [
    # (badge, position, devname, sensor 节点, lens 节点)
    ("ov13b10_bottom_RBP194",  "bottom", "ov13b10 2-0036",
     "/proc/device-tree/i2c@3180000/ov13b10_e@36",
     "/proc/device-tree/p2151_lens_ov13b10@1/"),
    ("ov7251_l_center_RBP194", "center", "ov7251 2-0061",
     "/proc/device-tree/i2c@3180000/ov7251_a@61",
     "/proc/device-tree/p2151_lens_ov7251@0/"),
    ("ov7251_front_RBP194",    "front",  "ov7251 2-0062",
     "/proc/device-tree/i2c@3180000/ov7251_b@62",
     "/proc/device-tree/p2151_lens_ov7251@0/"),
]

out = [ind + "modules {\n"]
for i, (badge, pos, dev, sensor, lens) in enumerate(MODULES):
    out += [
        f"{i1}module{i} {{\n",
        f'{i2}badge = "{badge}";\n',
        f'{i2}position = "{pos}";\n',
        f'{i2}orientation = "1";\n',
        f"{i2}drivernode0 {{\n",
        f'{i3}pcl_id = "v4l2_sensor";\n',
        f'{i3}devname = "{dev}";\n',
        f'{i3}proc-device-tree = "{sensor}";\n',
        f"{i2}}};\n",
        f"{i2}drivernode1 {{\n",
        f'{i3}pcl_id = "v4l2_lens";\n',
        f'{i3}proc-device-tree = "{lens}";\n',
        f"{i2}}};\n",
        f"{i1}}};\n",
    ]
out.append(ind + "};\n")
new = "".join(out)

src = src.replace(old, new, 1)
open(sys.argv[2], "w").write(src)

assert src.count("RBP194") == 3
assert "P2151X" not in src
assert src.count('devname = "ov13b10 2-0036"') == 1
assert "ov13b10@36\"" not in src, "混进了出厂节点名(本树叫 ov13b10_e@36)"
print(f"  ✅ modules 块已替换 → {sys.argv[2]}")
print("     module0=ov13b10(bottom) module1=ov7251@61(center) module2=ov7251@62(front)")
