#!/bin/bash
# 官方匹配库 + 干净构建的运行环境
ROOT="${AMDL_ROOT:-/root/workspace}"
BASE=$ROOT
APEXP=""
while read -r d; do
  if [ -d "$d" ]; then APEXP="${APEXP}${d}:"; fi
done < <(awk '$2 ~ /^\/apex\/[^/]+@[^/]+$/ {n=$2; sub(/@.*/,"",n); print n"/lib64"}' /proc/self/mounts | sort -u)
export LD_LIBRARY_PATH="$BASE/amlibs-apple:/system/lib64:${APEXP}"
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
export AMDL_SKIP_OFFLINE_CHECK=1
export LITE_BIN="$BASE/build/lite3/lite"
mkdir -p /data
