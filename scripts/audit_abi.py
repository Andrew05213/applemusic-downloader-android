#!/usr/bin/env python3
"""审计 wrapper 的 import.h：哪些符号在 arm64 上必须加 sret 跳板。

原理：C++ 返回非平凡类型时，x86-64 SysV 把隐藏返回指针放 rdi（参数 1），
AArch64 放 x8。wrapper 的 import.h 按 x86-64 写死，所以在 arm64 上
凡是「真函数走 sret」的导入，都必须先 mov x8, x0（成员函数还要左移其余参数）。

检测方法：对同一符号，分别反汇编两个 ABI 的入口若干条指令，
  x86-64 命中 `mov %rdi,%rXX`
  arm64  命中 `mov xXX, x8`
两边同时命中 → 需要跳板。
"""
import glob
import os

ROOT = os.environ.get("AMDL_ROOT", "/root/workspace")
import re
import subprocess

X86_TOOL = "x86_64-linux-gnu-objdump"
ARM_TOOL = "objdump"
IMPORT_H = ROOT + "/wsrc/import.h"
X86_GLOB = ROOT + "/amd-native/legacy/v1/wrapper-linux/rootfs/system/lib64/lib*.so"
ARM_GLOB = os.environ.get("ARM_GLOB", ROOT + "/amlibs-apple/*.so")


def symtab(paths):
    table = {}
    for path in paths:
        out = subprocess.run(
            ["nm", "-D", "--defined-only", path], capture_output=True, text=True
        ).stdout
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3:
                try:
                    table.setdefault(parts[-1], (path, int(parts[0], 16)))
                except ValueError:
                    pass
    return table


def instructions(tool, path, addr, span=64):
    """取函数入口处的指令助记符列表。地址必须以 0x 十六进制传给 objdump。"""
    out = subprocess.run(
        [tool, "-d", f"--start-address=0x{addr:x}", f"--stop-address=0x{addr + span:x}", path],
        capture_output=True,
        text=True,
    ).stdout
    result = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and re.match(r"^\s*[0-9a-f]+:$", parts[0]):
            # arm64 objdump 把助记符和操作数分成两列，必须拼回去
            result.append(" ".join(x.strip() for x in parts[2:]).strip())
    return result[:40]


def main():
    imports = sorted(set(re.findall(r"\b(_Z[A-Za-z0-9_]+)\b", open(IMPORT_H).read())))
    x86 = symtab(glob.glob(X86_GLOB))
    arm = symtab(glob.glob(ARM_GLOB))

    both = [s for s in imports if s in x86 and s in arm and not s.startswith("_ZTV")]
    only_arm = [s for s in imports if s in arm and s not in x86]
    only_x86 = [s for s in imports if s in x86 and s not in arm]
    neither = [s for s in imports if s not in x86 and s not in arm]

    print(f"import.h 符号总数      : {len(imports)}")
    print(f"两个 ABI 都导出        : {len(both)}")
    print(f"只有 arm64 有           : {len(only_arm)}")
    print(f"只有 x86-64 有          : {len(only_x86)}")
    print(f"两边都没有              : {len(neither)}")

    need, unknown = [], []
    for sym in both:
        x_ins = instructions(X86_TOOL, *x86[sym])
        a_ins = instructions(ARM_TOOL, *arm[sym])
        if not x_ins or not a_ins:
            unknown.append(sym)
            continue
        # 只认「寄存器到寄存器」的搬移：这是 sret 的强特征。
        # 不认 str x8,[sp] —— x8 在 AAPCS64 里也可以当普通临时寄存器，会假阳性。
        x_sret = any(re.match(r"mov\s+%rdi,%r", i) for i in x_ins)
        a_sret = any(re.match(r"mov\s+x\d+,\s*x8$", i) for i in a_ins)
        if x_sret and a_sret:
            need.append(sym)

    print(f"\n反汇编成功比对          : {len(both) - len(unknown)}")
    print(f"两边都走 sret，需跳板   : {len(need)}")
    for s in need:
        print("   ", s)

    if unknown:
        print(f"\n无法比对（反汇编为空）  : {len(unknown)}")
        for s in unknown[:10]:
            print("   ", s)

    with open(ROOT + "/sret_needed.txt", "w") as f:
        f.write("\n".join(need))
    print("\n已写入 /root/workspace/sret_needed.txt")


if __name__ == "__main__":
    main()
