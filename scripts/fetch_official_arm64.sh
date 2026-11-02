#!/bin/bash
# 取得与 wrapper 源码匹配的 arm64 Apple 库。
# 优先用本仓库的 vendor 附件；取不到则回退到上游 wrapper.arm64.latest。
set -eu
cd "$(dirname "$0")/.."
DEST=amlibs-apple
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if gh release download vendor-arm64 -R Andrew05213/applemusic-downloader-android \
      -p 'amlibs-apple.tar.gz' -D "$TMP" --clobber 2>/dev/null; then
  rm -rf "$DEST"; mkdir -p "$DEST"
  tar xzf "$TMP/amlibs-apple.tar.gz" -C "$DEST"
  echo "已从本仓库 vendor 附件取得 $(ls "$DEST" | wc -l) 个库 → $DEST/"
  exit 0
fi

echo "vendor 附件不可用，回退到上游发布包…"
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
