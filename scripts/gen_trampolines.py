#!/usr/bin/env python3
"""为需要 sret 跳板的导入符号生成 AArch64 汇编跳板，并重命名对象文件里的引用。

做法：
  1. import.h 里声明、审计确认走 sret 的符号，各生成一个 `<mangled>__amdl` 跳板。
  2. 编译出 .o 之后，用 objcopy --redefine-sym 把对 `<mangled>` 的引用改成
     `<mangled>__amdl`，于是调用点一行都不用改。
  3. 跳板末尾用 `b <mangled>` 尾调用真实函数，符号由 .so 在运行时解析。

跳板统一的变换：x8 <- x0（sret），其余参数整体左移一位。
无论静态函数还是成员函数，wrapper 的调用形态都是「第一个参数是 sret 指针」，
所以同一套搬移规则通用。
"""
import re
import subprocess
import sys

# 窄规则漏掉、但已由崩溃栈证实的补充项
EXTRA = {
    "_ZN17storeservicescore14RequestContext4initERKNSt6__ndk110shared_ptrINS_20RequestContextConfigEEE",
}

ALREADY_FIXED = {
    "_ZN17storeservicescore10DeviceGUID8instanceEv",
    "_ZN17storeservicescore10DeviceGUID9configureERKNSt6__ndk112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEES9_RKjRKb",
}

SHIFT = "\n".join(f"    mov x{i}, x{i + 1}" for i in range(7))


def emit(symbols):
    lines = [
        "/* 自动生成：sret 跳板（见 audit_abi.py 的审计结果） */",
        "    .text",
    ]
    for sym in symbols:
        lines += [
            "",
            f"    .globl {sym}__amdl",
            f"    .type {sym}__amdl, %function",
            f"{sym}__amdl:",
            "    mov x8, x0",
            SHIFT,
            f"    b   {sym}",
        ]
    return "\n".join(lines) + "\n"


def main():
    needed = [l.strip() for l in open(ROOT + "/sret_needed.txt") if l.strip()]
    targets = [s for s in needed if s not in ALREADY_FIXED]
    for s in EXTRA:
        if s not in targets:
            targets.append(s)
    print(f"审计命中 {len(needed)}，已手工修 {len(needed) - len(targets)}，待生成 {len(targets)}")

    asm = emit(targets)
    open(ROOT + "/sret_trampolines.S", "w").write(asm)
    print("已生成 /root/workspace/sret_trampolines.S")

    # 对每个 .o 做一次重命名（只处理确实引用了这些符号的对象）
    import glob
    total = 0
    for obj in glob.glob(ROOT + "/build/lite/obj/*.o"):
        out = subprocess.run(["nm", "-u", obj], capture_output=True, text=True).stdout
        present = [s for s in targets if s in out]
        if not present:
            continue
        args = ["objcopy"]
        for s in present:
            args += ["--redefine-sym", f"{s}={s}__amdl"]
        args.append(obj)
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  FAIL {obj}: {r.stderr.strip()[:200]}")
        else:
            total += len(present)
            print(f"  {obj.split('/')[-1]}: 重命名 {len(present)} 个引用")
    print(f"共重命名 {total} 处引用")


if __name__ == "__main__":
    sys.exit(main())
