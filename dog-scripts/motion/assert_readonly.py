#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""断言「只读桥」真的没有发送路径 —— 用 AST 解析，不用 grep。

为什么不用 grep：注释里出现 "不调用 sendto" 会被 grep 数成命中，
于是这个安全断言会一直"命中然后被人工解释掉"，等于没有断言。
AST 只看真实代码。

用法: python3 assert_readonly.py motion_bridge_node.py
"""
import ast
import sys

# 真正会把数据打出去的 socket 方法
FORBIDDEN_CALLS = {"sendto", "sendmsg", "sendall", "send"}
# 只读桥不该 import 的东西（写侧必须是独立进程）
FORBIDDEN_IMPORTS = {"motion_safety"}


def check(path):
    src = open(path, encoding="utf-8").read()
    tree = ast.parse(src, path)
    problems = []

    for node in ast.walk(tree):
        # ① 方法调用 x.sendto(...)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            if node.func.attr in FORBIDDEN_CALLS:
                # publish() 不算；只查 socket 系
                problems.append("第 %d 行：调用了 .%s()" % (node.lineno, node.func.attr))
        # ② import
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name.split(".")[0] in FORBIDDEN_IMPORTS:
                    problems.append("第 %d 行：import %s" % (node.lineno, a.name))
        if isinstance(node, ast.ImportFrom):
            if node.module and node.module.split(".")[0] in FORBIDDEN_IMPORTS:
                problems.append("第 %d 行：from %s import" % (node.lineno, node.module))

    return problems


def main():
    rc = 0
    for path in sys.argv[1:]:
        p = check(path)
        if p:
            rc = 1
            print("❌ %s 不是只读的：" % path)
            for x in p:
                print("   " + x)
        else:
            print("✅ %s 无发送路径、无写侧依赖（AST 验证）" % path)
    return rc


if __name__ == "__main__":
    sys.exit(main())
