#!/bin/bash
# 干净构建：wsrc2 + 官方 arm64 Apple 库 + 自动生成的 sret 跳板
ROOT="${AMDL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
set -eu
SYS=$ROOT/ndk; API=$SYS/usr/lib/aarch64-linux-android/24
W=$ROOT/wrapper-src; CJ=$ROOT/cjson
DB=$ROOT/build/dobby; AML=$ROOT/amlibs-apple
RP=$ROOT/patches/runtime
OUT=$ROOT/build/lite3
mkdir -p "$OUT/obj"; rm -f "$OUT"/obj/*.o
INC="-I$W/lite -I$W -I$CJ -I$ROOT/dobby/include -I$RP"
CXX="clang++ --target=aarch64-linux-android24 --sysroot=$SYS"
CC="clang --target=aarch64-linux-android24 --sysroot=$SYS"
CXXFLAGS="$INC -fPIC -O2 -std=gnu++17 -DANDROID -DLITE_RELEASE -w"
CFLAGS="$INC -fPIC -O2 -std=gnu99 -DANDROID -w"

for f in lite/lite_main.cpp lite/bridge.cpp lite/auth.cpp lite/playback.cpp lite/tokens.cpp lite/apple_api.cpp; do
  $CXX $CXXFLAGS -c "$W/$f" -o "$OUT/obj/$(basename $f .cpp).o"
done
$CC $CFLAGS -c "$CJ/cJSON.c" -o "$OUT/obj/cjson.o"
$CXX $CXXFLAGS -c $ROOT/patches/crash.cpp -o "$OUT/obj/crash.o"

# 生成跳板
python3 - "$ROOT" <<'PY'
import sys
root = sys.argv[1]
need=[l.strip() for l in open(f'{root}/sret_needed.txt') if l.strip()]
lines=["    .text"]
shift="\n".join(f"    mov x{i}, x{i+1}" for i in range(7))
for s in need:
    lines += ["", f"    .globl {s}__amdl", f"    .type {s}__amdl, %function",
              f"{s}__amdl:", "    mov x8, x0", shift, f"    b   {s}"]
open(f'{root}/build/sret3.S','w').write("\n".join(lines)+"\n")
print(f"跳板 {len(need)} 个")
PY
$CC $CFLAGS -c $ROOT/build/sret3.S -o "$OUT/obj/sret3.o"

# 重命名引用
python3 - "$ROOT" <<'PY'
import glob, subprocess, sys
root = sys.argv[1]
need=[l.strip() for l in open(f'{root}/sret_needed.txt') if l.strip()]
for obj in glob.glob(f'{root}/build/lite3/obj/*.o'):
    if obj.endswith('sret3.o'): continue
    u=subprocess.run(['nm','-u',obj],capture_output=True,text=True).stdout
    present=[s for s in need if s in u]
    if present:
        args=['objcopy']
        for s in present: args+=['--redefine-sym',f'{s}={s}__amdl']
        subprocess.run(args+[obj],check=True)
        print(f"  {obj.split('/')[-1]}: {len(present)} 处")
PY

$CXX --target=aarch64-linux-android24 --sysroot=$SYS -fuse-ld=lld -rtlib=compiler-rt \
  -o "$OUT/lite" "$OUT"/obj/*.o "$DB/libdobby.a" \
  -L"$AML" -L"$API" -lc++_shared -landroidappmusic -lstoreservicescore -lmediaplatform -lcurl -llog \
  -lc -lm -ldl -Wl,--unresolved-symbols=ignore-in-object-files \
  -Wl,-pie -Wl,--dynamic-linker=/system/bin/linker64
ls -l "$OUT/lite"
