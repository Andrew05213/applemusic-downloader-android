# Apple Music Downloader — Android arm64 移植

把 Windows 版的原生引擎（wrapper 的 `lite`）跑在 **arm64 Android** 上。
无 QEMU、无 chroot、无 root、无 Debian 内核。

> ⚠️ **授权警告**：本目录不含任何 Apple 二进制。运行时需要的 `libCoreFP.so`、
> `libCoreADI.so`、`libstoreservicescore.so` 等属于 Apple 的专有材料，
> 请自行从你合法拥有的设备/安装包中取得，并遵守所在地法律与 Apple 的服务条款。
> **不要提交进 git。**

---

## 当前状态（2026-11-02 实测）

| 能力 | 状态 |
| --- | --- |
| arm64 交叉编译 | ✅ |
| Dobby 在 arm64 上构建 | ✅ |
| lite 在设备上原生运行 | ✅ |
| `GET /status` → 200 | ✅ |
| `GET /native/tokens` 未登录 → 401（正确语义） | ✅ |
| 登录能连到 Apple 并拿到真实认证响应 | ✅ 用假账号验证 |
| 真实账号登录 + 2FA | ⏸ 等待账号 |
| 播放/下载解密（FairPlay 钩子） | ❌ x86 专用，需按 arm64 重写 |
| APK 打包 | ❌ 未开始 |

---

## 关键结论：**不要用应用商店最新 APK 的库**

第一版移植踩了最大的坑：拿 Apple Music **4.9.7.2** 的 arm64 库去配 wrapper，结果
符号缺失、签名漂移、结构体布局对不上，被迫写了大量 ABI 补丁。

**正确做法**：上游自己发布过 arm64 包：

```bash
gh release download wrapper.arm64.latest -R WorldObservationLog/wrapper \
   -p 'Wrapper.arm64.latest.zip' -D /tmp/warm
```

里面 `rootfs/system/lib64/` 就是 **arm64** 的 Apple 库，而且：

| 判据 | 官方 arm64 包 | 4.9.7.2 APK |
| --- | --- | --- |
| `FootHillConfig::config` | `const&` ✅ | 按值 ❌ |
| libcurl | 7.64.0 ✅ | 7.84.0 ❌ |
| libc++ | NDK r23b 同代 ✅ | 更新代 ❌ |
| `import.h` 缺失符号 | 0 ✅ | 7 ❌ |

换回官方库后，三个 `make_shared` 不用再手工重建，`accountStore` 等偏移问题也全部消失。

---

## 构建

前提：`clang` `lld`（`apt install clang lld`）、Go 与 `gh`（取官方包）。

```bash
# 1. NDK sysroot（只需 51MB，不是整包 717MB）
python3 scripts/fetch_sysroot.py
cp ndk/usr/lib/aarch64-linux-android/libclang_rt.builtins-aarch64-android.a \
   /usr/lib/llvm-18/lib/clang/18/lib/linux/

# 2. Dobby
./scripts/build_dobby.sh

# 3. Apple 原生库：优先取本仓库 vendor 附件，取不到再回退上游发布包
./scripts/fetch_official_arm64.sh

# 4. wrapper 源码（锁定 commit，应用原项目三个补丁）
curl -L https://codeload.github.com/WorldObservationLog/wrapper/tar.gz/2fd7e0eaef081f93cf687428b965674937832ba4 -o wrapper.tar.gz
mkdir -p wsrc2 && tar xzf wrapper.tar.gz -C wsrc2 --strip-components=1
git init -q wsrc2 && git -C wsrc2 add -A && git -C wsrc2 commit -qm base
for p in lite-native lite-session lite-store-bridge; do
  git -C wsrc2 apply --recount --unidiff-zero patches/$p.patch
done
# 两处 arm64 适配：playback.cpp 的 x86 寄存器钩子加守卫、offline 检查加开关

# 5. 审计 + 生成 sret 跳板 + 构建
ARM_GLOB="$PWD/amlibs-apple/*.so" python3 scripts/audit_abi.py
./scripts/build_lite3.sh

# 6. 运行
./scripts/run_lite3.sh &
curl -s http://127.0.0.1:12341/status
```

---

## arm64 移植的三个真问题

### 1. sret 寄存器不同（必须修）

C++ 返回非平凡类型时，x86-64 SysV 把隐藏返回指针放 **rdi**（参数 1），AArch64 放 **x8**。
wrapper 的 `import.h` 按 x86-64 写死，所以这类导入在 arm64 上全部传错寄存器。

修法：汇编跳板 `mov x8, x0` + 其余参数整体左移，再用 `objcopy --redefine-sym`
批量改名，**调用点一行不用改**。官方库下共 16 个符号需要跳板。

### 2. 播放路径的寄存器钩子是 x86 专属（未解决）

`lite/playback.cpp` 的 `r1_capture_cb` 直接从 `rsi/r9/rbp/rcx` 读调用现场，
并从 `rbp - 0x2000` 拷 0x2100 字节栈缓冲区；挂载点是 `base + 0x1d5709`，
而这个偏移**不是指令对齐的**（`% 4 == 1`），落在一条指令中间。

arm64 上必须重新做运行时分析，静态平移不可行。移植时先用
`#if !defined(__x86_64__) return;` 短路，保证登录/服务可用。

### 3. 未登录时 `offline_available_impl()` 会挂

它要向 Apple 查订阅状态。加 `AMDL_SKIP_OFFLINE_CHECK=1` 跳过。

---

## 登录与 2FA

登录走 stdin：`lite --native-login-stdin --base-dir /data`，喂一行 JSON：

```json
{"appleEmail":"...","applePassword":"..."}
```

出现 `AMDL_NATIVE_EVENT:{"type":"two_factor_required"}` 后，再喂 `{"code":"123456"}`。

**2FA 对话框**由 `dialogHandler` 处理。默认只自动选 "Use Existing Apple ID"，
其它对话框只打印按钮。可用环境变量在运行时选择：

```bash
AMDL_DIALOG_SELECT_INDEX=1     # 按序号
AMDL_DIALOG_SELECT=Retry       # 按标题子串（不区分大小写）
```

> 没有受信任 Apple 设备时，短信验证码需要在这一步手动选择；
> 部分账号状态下 Apple 会直接要求「账户恢复」，那就拿不到验证码了。

---

## 目录

```
scripts/   构建、运行、审计、取官方库
patches/   wrapper 的上游补丁 + arm64 兼容层
reports/   设计文档与实测记录
```
