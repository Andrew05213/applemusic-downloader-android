#!/bin/bash
# 取得与 wrapper 源码匹配的 arm64 Apple 库。
#
# 本仓库不分发这些二进制（它们是 Apple 的专有材料），脚本从上游
# WorldObservationLog/wrapper 的官方 arm64 发布包中提取。
# 也可以自行从你合法拥有的设备/安装包中取得，放到 amlibs-apple/ 即可。
set -eu
cd "$(dirname "$0")/.."
DEST=amlibs-apple
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

gh release download wrapper.arm64.latest -R WorldObservationLog/wrapper \
   -p 'Wrapper.arm64.latest.zip' -D "$TMP" --clobber
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
   "$TMP/Wrapper.arm64.latest.zip" "$TMP/x"

SRC="$TMP/x/rootfs/system/lib64"
rm -rf "$DEST"; mkdir -p "$DEST"
for n in libCoreADI libCoreFP libCoreFoundation libCoreLSKD libandroidappmusic \
         libdaapkit libdispatch libBlocksRuntime libmedialibrarycore libmediaplatform \
         libstoreservicescore libicudata_sv_apple libicui18n_sv_apple libicuuc_sv_apple \
         libc++_shared libRScpp libLLVM libcurl libssl libcrypto; do
  cp "$SRC/$n.so" "$DEST/" 2>/dev/null || true
done
echo "已从上游取得 $(ls "$DEST" | wc -l) 个库 → $DEST/"
