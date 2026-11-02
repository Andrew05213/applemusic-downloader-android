#!/bin/bash
# lite 引擎在本机运行所需的环境（被 run_lite.sh 和登录脚本共用）
ROOT="${AMDL_ROOT:-/root/workspace}"
BASE=$ROOT
APEXP=""
while read -r d; do
  if [ -d "$d" ]; then APEXP="${APEXP}${d}:"; fi
done < <(awk '$2 ~ /^\/apex\/[^/]+@[^/]+$/ {n=$2; sub(/@.*/,"",n); print n"/lib64"}' /proc/self/mounts | sort -u)
export LD_LIBRARY_PATH="$BASE/amlibs:/system/lib64:${APEXP}"
export ANDROID_ROOT=/system
export ANDROID_DATA="$BASE/litedata"
export AMDL_SKIP_OFFLINE_CHECK=1
export LITE_BIN="$BASE/build/lite/lite"
mkdir -p "$BASE/litedata"
