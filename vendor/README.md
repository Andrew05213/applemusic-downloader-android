# 运行时二进制

本目录不放文件。Apple 的 arm64 原生库挂在 Release 附件 `vendor-arm64` 上（约 36 MB）。

来源：上游 `WorldObservationLog/wrapper` 的 `Wrapper.arm64.latest` 发布包，提取其中 20 个
aarch64 `.so`。这些是 Apple 的二进制，不属于本项目。

```bash
gh release download vendor-arm64 -R Andrew05213/applemusic-downloader-android \
   -p 'amlibs-apple.tar.gz' -D /tmp/vendor
mkdir -p amlibs-apple && tar xzf /tmp/vendor/amlibs-apple.tar.gz -C amlibs-apple
```

`scripts/fetch_official_arm64.sh` 会优先从这里取，取不到再回退到上游发布包。

| 类别 | 文件 |
| --- | --- |
| FairPlay / DRM | `libCoreFP.so`、`libCoreADI.so`、`libCoreLSKD.so`、`libCoreFoundation.so` |
| 商店与会话 | `libstoreservicescore.so`、`libmediaplatform.so`、`libmedialibrarycore.so` |
| 应用主体 | `libandroidappmusic.so`、`libdaapkit.so`、`libRSCpp.so`、`libLLVM.so` |
| 运行时依赖 | `libc++_shared.so`、`libcurl.so`、`libssl.so`、`libcrypto.so`、`libicu*_sv_apple.so`、`libdispatch.so`、`libBlocksRuntime.so` |
