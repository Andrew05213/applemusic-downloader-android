#!/bin/bash
# 在当前设备上原生运行交叉编译出来的 lite 引擎（arm64 Android）。
# 不需要 root、不需要 chroot、不需要 QEMU。
set -u
. "$(dirname "$0")/env_lite.sh"
exec "$LITE_BIN" --native-service --base-dir "$ANDROID_DATA" --host 127.0.0.1 --port 12341
