#!/bin/bash
# 手工构建 Dobby（arm64 Android），绕开其 CMake 对 NDK x86_64 宿主的假设。
ROOT="${AMDL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
set -eu
SYS=$ROOT/ndk
D=$ROOT/dobby
OUT=$ROOT/build/dobby
mkdir -p "$OUT/obj"

CC="clang --target=aarch64-linux-android24 --sysroot=$SYS"
CXX="clang++ --target=aarch64-linux-android24 --sysroot=$SYS"

INC="-I$D -I$D/include -I$D/source -I$D/source/include -I$D/source/UserMode \
-I$D/external -I$D/external/logging -I$D/external/xnucxx -I$D/external/misc-helper \
-I$D/builtin-plugin"

DEFS='-D__DOBBY_BUILD_VERSION__="1.0.0"'

CXXFLAGS="$INC $DEFS -fPIC -O2 -std=gnu++17 -fno-rtti -fvisibility=hidden -fvisibility-inlines-hidden -w"
CFLAGS="$INC $DEFS -fPIC -O2 -std=gnu99 -w -fvisibility=hidden"

SRCS_CPP="
source/core/arch/CpuFeature.cc
source/core/arch/CpuRegister.cc
source/core/modules/assembler/assembler.cc
source/core/modules/assembler/assembler-arm64.cc
source/core/modules/codegen/codegen-arm64.cc
source/MemoryAllocator/CodeBuffer/CodeBufferBase.cc
source/MemoryAllocator/CodeBuffer/code-buffer-arm64.cc
source/MemoryAllocator/AssemblyCodeBuilder.cc
source/MemoryAllocator/MemoryArena.cc
source/MemoryAllocator/NearMemoryArena.cc
source/InterceptRouting/RoutingPlugin/NearBranchTrampoline/NeaBranchTrampoline.cc
source/InstructionRelocation/arm64/ARM64InstructionRelocation.cc
source/InterceptRouting/InterceptRouting.cpp
source/TrampolineBridge/Trampoline/arm64/trampoline-arm64.cc
source/InterceptRouting/Routing/FunctionInlineReplace/function-inline-replace.cc
source/InterceptRouting/Routing/FunctionInlineReplace/FunctionInlineReplaceExport.cc
source/InterceptRouting/RoutingPlugin/RoutingPlugin.cc
source/InterceptRouting/Routing/DynamicBinaryInstrument/dynamic-binary-instrument.cc
source/InterceptRouting/Routing/DynamicBinaryInstrument/DynamicBinaryInstrumentExport.cc
source/InterceptRouting/Routing/DynamicBinaryInstrument/intercept_routing_handler.cc
source/UserMode/PlatformUtil/Linux/ProcessRuntimeUtility.cc
source/UserMode/UnifiedInterface/platform-posix.cc
source/UserMode/ExecMemory/code-patch-tool-posix.cc
source/dobby.cpp
source/Interceptor.cpp
builtin-plugin/SymbolResolver/elf/dobby_symbol_resolver.cc
external/xnucxx/LiteMemOpt.cc
external/xnucxx/LiteObject.cc
external/xnucxx/LiteIterator.cc
external/xnucxx/LiteCollection.cc
external/xnucxx/LiteMutableBuffer.cc
external/xnucxx/LiteMutableArray.cc
source/TrampolineBridge/ClosureTrampolineBridge/common-bridge-handler.cc
source/TrampolineBridge/ClosureTrampolineBridge/arm64/helper-arm64.cc
source/TrampolineBridge/ClosureTrampolineBridge/arm64/closure-bridge-arm64.cc
source/TrampolineBridge/ClosureTrampolineBridge/arm64/ARM64AssemblyClosureTrampoline.cc
"

SRCS_C="
source/UserMode/ExecMemory/clear-cache-tool-all.c
external/logging/logging.c
"

fail=0
for f in $SRCS_CPP; do
  o="$OUT/obj/$(echo "$f" | tr '/' '_').o"
  if ! $CXX $CXXFLAGS -c "$D/$f" -o "$o" 2>"$OUT/$(basename $f).err"; then
    echo "FAIL $f"
    head -5 "$OUT/$(basename $f).err"
    fail=1
  else
    echo "ok   $f"
  fi
done

for f in $SRCS_C; do
  o="$OUT/obj/$(echo "$f" | tr '/' '_').o"
  if ! $CC $CFLAGS -c "$D/$f" -o "$o" 2>"$OUT/$(basename $f).err"; then
    echo "FAIL $f"; head -5 "$OUT/$(basename $f).err"; fail=1
  else
    echo "ok   $f"
  fi
done

[ "$fail" = "0" ] || { echo "有编译失败"; exit 1; }
/usr/bin/ar rcs "$OUT/libdobby.a" "$OUT"/obj/*.o
echo "== 产出 =="
ls -l "$OUT/libdobby.a"
