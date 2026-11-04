#!/bin/bash
# 把 wrapper 的 lite 交叉编译成 arm64 Android 可执行文件。
ROOT="${AMDL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
set -eu
SYS=$ROOT/ndk
API=$SYS/usr/lib/aarch64-linux-android/24
W=$ROOT/wsrc
CJ=$ROOT/cjson
DB=$ROOT/build/dobby
AML=$ROOT/amlibs
RP=$ROOT/patches/runtime
OUT=$ROOT/build/lite
mkdir -p "$OUT/obj"
rm -f "$OUT"/obj/*.o

INC="-I$W/lite -I$W -I$CJ -I$ROOT/dobby/include -I$RP"

CXX="clang++ --target=aarch64-linux-android24 --sysroot=$SYS"
CC="clang --target=aarch64-linux-android24 --sysroot=$SYS"

CXXFLAGS="$INC -fPIC -O2 -std=gnu++17 -DANDROID -DLITE_RELEASE -Wno-unused-variable -w"
CFLAGS="$INC -fPIC -O2 -std=gnu99 -DANDROID -w"

fail=0
for f in lite/lite_main.cpp lite/bridge.cpp lite/auth.cpp lite/playback.cpp lite/tokens.cpp lite/apple_api.cpp; do
  o="$OUT/obj/$(basename $f .cpp).o"
  if ! $CXX $CXXFLAGS -c "$W/$f" -o "$o" 2>"$OUT/$(basename $f).err"; then
    echo "FAIL $f"; head -12 "$OUT/$(basename $f).err"; fail=1
  else echo "ok   $f"; fi
done

# AccountStore 补丁
if ! $CXX $CXXFLAGS -c $ROOT/account_store.cpp -o "$OUT/obj/account_store.o" 2>"$OUT/as.err"; then
  echo "FAIL account_store"; head -8 "$OUT/as.err"; fail=1
else echo "ok   account_store"; fi

# shim：补齐 arm64 缺失的模板实例化
if ! $CXX $CXXFLAGS -c $ROOT/shim.cpp -o "$OUT/obj/shim.o" 2>"$OUT/shim.err"; then
  echo "FAIL shim"; head -8 "$OUT/shim.err"; fail=1
else echo "ok   shim"; fi

# sret 跳板（arm64）
if ! $CC $CFLAGS -c $ROOT/sret_arm64.S -o "$OUT/obj/sret.o" 2>"$OUT/sret.err"; then
  echo "FAIL sret.S"; head -8 "$OUT/sret.err"; fail=1
else echo "ok   sret.S"; fi

# cJSON
if ! $CC $CFLAGS -c "$CJ/cJSON.c" -o "$OUT/obj/cjson.o" 2>"$OUT/cjson.err"; then
  echo "FAIL cJSON.c"; head -8 "$OUT/cjson.err"; fail=1
else echo "ok   cJSON.c"; fi

# store bridge 的实现已经由 auth.cpp 引入（宏在那边定义），无需另编

[ "$fail" = "0" ] || { echo "编译失败"; exit 1; }

echo "== 生成 sret 跳板并重命名引用 =="
python3 $ROOT/gen_trampolines.py
if ! $CC $CFLAGS -c $ROOT/sret_trampolines.S -o "$OUT/obj/sret_tramps.o" 2>"$OUT/tramp.err"; then
  echo "FAIL sret_trampolines.S"; head -8 "$OUT/tramp.err"; exit 1
fi
echo "ok   sret_trampolines.S"

echo "== 链接 =="
$CXX --target=aarch64-linux-android24 --sysroot=$SYS -fuse-ld=lld -rtlib=compiler-rt \
  -o "$OUT/lite" "$OUT"/obj/*.o "$DB/libdobby.a" \
  -L"$AML" -L"$API" \
  -lc++_shared -landroidappmusic -lstoreservicescore -lmediaplatform -lcurl -llog \
  -lc -lm -ldl \
  -Wl,--unresolved-symbols=ignore-in-object-files \
  -Wl,-pie -Wl,--dynamic-linker=/system/bin/linker64 2>&1 | head -15

ls -l "$OUT/lite" 2>/dev/null && echo "== 链接完成 =="
