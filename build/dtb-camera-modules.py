#!/usr/bin/env python3
"""把 tegra-camera-platform 的 modules 块换成【出厂 tegra194-mi-k91.dtb 的描述】。

2026-07-28 定位：我们移植 DTB 时这一节用成了 NVIDIA 参考板 (P2151) 的写法，
与出厂 (小米 RBP194) 有三处差异，全部影响 argus/PCL 用户态：

  ┌───────────┬──────────────────────────┬──────────────────────────┐
  │           │ 出厂 JP4                 │ 参考板(我们现在)         │
  ├───────────┼──────────────────────────┼──────────────────────────┤
  │ badge     │ ov13b10_bottom_RBP194    │ ov13b10_2_P2151X         │
  │ position  │ "bottom"                 │ "2"                      │
  │ 模块顺序  │ module0 = ov13b10(主相机)│ module2 = ov13b10        │
  └───────────┴──────────────────────────┴──────────────────────────┘

① badge：`/var/nvidia/nvcam/settings/<badge>.isp` 按 badge 命名查找，且
   libnvodm_imager 认的位置名是【固定集合】bottom/center/centerleft/
   centerright/front/rear —— 它不读 position 属性，而是在 **badge 字符串里
   做子串匹配**(dtsi 自己的注释也写了 badge 第二段就是位置)。
   badge 不对 ⇒ "Could not map module to ISP config string" ⇒ 三个 .isp 全加载不了。
   已用运行时覆盖验证：换回出厂 badge 后三个 .isp 全部加载成功。

② 模块顺序：`camera_server` 打开的是 camera **id 0**。出厂 module0 是主相机
   ov13b10，我们这儿却是鱼眼 ov7251 —— 这是【本次要验证的核心假设】：
   argus 迟迟不对 v4l2 通道下 STREAMON(实测只有 QUERYCAP/QUERY_EXT_CTRL)，
   很可能就是因为 id 0 指向了错误的传感器。

⚠️ 只改 badge / position / 顺序。`devname` 与 `proc-device-tree` 保持指向
   **我们自己**的节点名(ov13b10_e@36 / ov7251_a@61 / ov7251_b@62)，不能抄出厂的
   (出厂叫 ov13b10@36 / ov7251@61 / ov7251@60)，否则 PCL 解析不到。

⚠️ 风险面：badge/position/模块顺序【内核驱动完全不消费】(驱动只认 i2c 子节点
   和 ports/endpoint)，纯用户态元数据 ⇒ 不可能影响内核 probe。
"""
import re
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/hardware/nvidia/"
     "platform/t19x/jakku/kernel-dts/common/tegra194-camera-p2151.dtsi")

src = open(F).read()

if "RBP194" in src:
    print("FATAL: 已经打过本补丁(出现 RBP194)")
    sys.exit(1)

# 锚点：整个 modules { ... }; 块（缩进 2 个 tab）
m = re.search(r"(?m)^\t\tmodules \{\n.*?^\t\t\};\n", src, re.S)
assert m, "找不到 modules 块"
old = m.group(0)
assert old.count("module0 {") == 1 and old.count("module2 {") == 1, "模块块结构异常"
assert "ov13b10_2_P2151X" in old, "锚点里没有预期的参考板 badge"

NEW = '''\t\tmodules {
\t\t\t/*
\t\t\t * 顺序与 badge 对齐出厂 tegra194-mi-k91.dtb：
\t\t\t *   module0 = ov13b10 主相机（camera_server 打开的是 camera id 0）
\t\t\t *   module1 = ov7251 左/中鱼眼   module2 = ov7251 上鱼眼
\t\t\t * badge 第二段必须是 libnvodm_imager 认识的位置名
\t\t\t * （bottom/center/centerleft/centerright/front/rear），它按 badge 子串
\t\t\t * 匹配位置，并按 <badge>.isp 去 /var/nvidia/nvcam/settings/ 找 ISP 配置。
\t\t\t * devname / proc-device-tree 仍指向本树自己的节点名，不能抄出厂的。
\t\t\t */
\t\t\tmodule0 {
\t\t\t\tbadge = "ov13b10_bottom_RBP194";
\t\t\t\tposition = "bottom";
\t\t\t\torientation = "1";
\t\t\t\tdrivernode0 {
\t\t\t\t\tpcl_id = "v4l2_sensor";
\t\t\t\t\tdevname = "ov13b10 2-0036";
\t\t\t\t\tproc-device-tree = "/proc/device-tree/i2c@3180000/ov13b10_e@36";
\t\t\t\t};
\t\t\t\tdrivernode1 {
\t\t\t\t\tpcl_id = "v4l2_lens";
\t\t\t\t\tproc-device-tree = "/proc/device-tree/p2151_lens_ov13b10@1/";
\t\t\t\t};
\t\t\t};
\t\t\tmodule1 {
\t\t\t\tbadge = "ov7251_l_center_RBP194";
\t\t\t\tposition = "center";
\t\t\t\torientation = "1";
\t\t\t\tdrivernode0 {
\t\t\t\t\tpcl_id = "v4l2_sensor";
\t\t\t\t\tdevname = "ov7251 2-0061";
\t\t\t\t\tproc-device-tree = "/proc/device-tree/i2c@3180000/ov7251_a@61";
\t\t\t\t};
\t\t\t\tdrivernode1 {
\t\t\t\t\tpcl_id = "v4l2_lens";
\t\t\t\t\tproc-device-tree = "/proc/device-tree/p2151_lens_ov7251@0/";
\t\t\t\t};
\t\t\t};
\t\t\tmodule2 {
\t\t\t\tbadge = "ov7251_front_RBP194";
\t\t\t\tposition = "front";
\t\t\t\torientation = "1";
\t\t\t\tdrivernode0 {
\t\t\t\t\tpcl_id = "v4l2_sensor";
\t\t\t\t\tdevname = "ov7251 2-0062";
\t\t\t\t\tproc-device-tree = "/proc/device-tree/i2c@3180000/ov7251_b@62";
\t\t\t\t};
\t\t\t\tdrivernode1 {
\t\t\t\t\tpcl_id = "v4l2_lens";
\t\t\t\t\tproc-device-tree = "/proc/device-tree/p2151_lens_ov7251@0/";
\t\t\t\t};
\t\t\t};
\t\t};
'''

src = src.replace(old, NEW, 1)
open(F, "w").write(src)

# 自检：改完必须满足的不变量
assert src.count('badge = "ov13b10_bottom_RBP194"') == 1
assert src.count('proc-device-tree = "/proc/device-tree/i2c@3180000/ov13b10_e@36"') == 1
assert "ov13b10@36\"" not in src, "混进了出厂的节点名(会解析不到)"
assert "P2151X" not in src, "还有残留的参考板 badge"
print("  ✅ tegra194-camera-p2151.dtsi: modules 块已换成出厂描述")
print("     module0=ov13b10(bottom) module1=ov7251@61(center) module2=ov7251@62(front)")
