#!/bin/bash
# 取上游官方 arm64 发布包里的 Apple 原生库（这才是和 wrapper 源码匹配的版本）
set -eu
cd "$(dirname "$0")/.."
gh release download wrapper.arm64.latest -R WorldObservationLog/wrapper \
   -p 'Wrapper.arm64.latest.zip' -D /tmp/warm --clobber
python3 -c "import zipfile;zipfile.ZipFile('/tmp/warm/Wrapper.arm64.latest.zip').extractall('/tmp/warm/x')"
rm -rf amlibs-apple && mkdir amlibs-apple
SRC=/tmp/warm/x/rootfs/system/lib64
for n in libCoreADI libCoreFP libCoreFoundation libCoreLSKD libandroidappmusic \
         libdaapkit libdispatch libBlocksRuntime libmedialibrarycore libmediaplatform \
         libstoreservicescore libicudata_sv_apple libicui18n_sv_apple libicuuc_sv_apple \
         libc++_shared libRScpp libLLVM libcurl libssl libcrypto; do
  cp "$SRC/$n.so" amlibs-apple/ 2>/dev/null || true
done
echo "已取 $(ls amlibs-apple | wc -l) 个库到 amlibs-apple/"
