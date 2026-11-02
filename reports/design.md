> **历史文档说明**
> 本文是最初基于 Apple Music 4.9.7.2 的 APK 库所做的可行性分析，其中的版本判断
> （缺失符号、签名漂移、手工重建 `make_shared` 等）**已被后续结论取代**：
> 上游官方 `Wrapper.arm64.latest` 提供了与 wrapper 源码匹配的 arm64 库，
> 换用之后大部分 ABI 补丁不再需要。当前做法见仓库根目录 `README.md`。
> 本文保留作为分析过程记录。

# Apple Music Downloader：Windows/QEMU → Android 原生改造方案

版本：草案 v1（基于 2026-11-01 本机实测）
适用对象：`Andrew05213/applemusic-downloader-native` v1.0.0

---

## 0. 结论先行

这不是「移植」，是**换宿主**。核心判断有三条：

1. **Go 后端几乎不用动。** 它和引擎之间的边界是 `127.0.0.1` 上的 HTTP + 64 位 capability token，与操作系统、架构无关。QEMU 存在的唯一理由是给 Android 用户态一个 Linux 内核，安卓设备天生就有。
2. **体积会掉一个数量级。** 现在 244MB 安装包里，116MB 是 x86-64 的 Android 系统库 + Date 内核 + BusyBox，这些东西在安卓上要么系统自带、要么不存在。arm64 的 Apple 侧库实测只有 **64MB**。
3. **最大风险不是技术，是授权。** 技术上已经验证可行（见附录），但 `/NOTICE` 里那些未完成的第三方权利审查，换成 APK 之后一点没少，反而因为「可直接安装运行」更显眼。

---

## 1. 现状：四条进程边界

```
Electron renderer (src/renderer/*)
        │ node IPC
Electron main (src/main/native-main.js)
        │ 子进程
amdl-service.exe  (Go, windows/amd64)
        │ QEMU hostfwd  tcp:127.0.0.1:<port> → guest:12340
qemu-system-x86_64.exe  (Debian kernel + BusyBox init)
        │ chroot
Android x86-64 用户态 (linker64 + /system/lib64)
        │ exec
/system/bin/lite  ──HTTP 127.0.0.1:12341──▶ Apple 的 .so (libCoreFP 等)
```

关键代码位置：

| 边界 | 文件 | 说明 |
| --- | --- | --- |
| 引擎启动 | `internal/guestagent/runner_linux.go` | `exec /system/bin/lite --native-service --host 127.0.0.1 --port 12341` |
| 登录 | 同上 `loginInput` | stdin 传 JSON，stdout 回 `AMDL_NATIVE_EVENT:{"type":"two_factor_required"}` |
| 取 token | 同上 `Tokens` | `GET /native/tokens` → `{code,data:{developer,media,region}}` |
| 媒体代理 | 同上 `Proxy` | 走 `/media`，Range 透传 |
| 端口转发 | `internal/nativeruntime/bundle.go:279` | `hostfwd=tcp:127.0.0.1:<port>-:12340` |
| capability | `process_secret_fd*.go` | 64 位十六进制，经 secretfd 传给子进程 |

---

## 2. 目标架构（一个 APK）

```
Compose UI  (app 进程)
    │ JNI (gomobile / c-shared)
Go core  (app 进程内的 .so)
    │ HTTP 127.0.0.1:12341 + capability
liblite.so  (android:process=":engine")
    │ dlopen
Apple arm64 .so × 19  →  /system/lib64  +  /apex/*
```

要点：

- **没有 QEMU、没有内核、没有 chroot、没有 Debian、没有 BusyBox。**
- 引擎扔进独立进程 `:engine`，崩了不影响 UI，也隔离了 Apple 库可能触发的 abort。
- 引擎和 Go core 之间**保留现有 HTTP 协议**，一行协议代码都不用改。等以后性能敏感再换 JNI 直调。

---

## 3. 层映射：现有文件去留

| 现有 | 处置 | 说明 |
| --- | --- | --- |
| `apple-music-downloader/*.go`（jobs/download/mp4audio/filename/tags） | **保留** | 纯 Go、零 cgo，`GOOS=android GOARCH=arm64` 直接编 |
| `internal/guestclient/` | **保留** | 只连 loopback，端口写死即可 |
| `internal/nativeauth/` | 保留 | 会话/token 逻辑与平台无关 |
| `internal/guestagent/runner_linux.go` | **重写** | exec 改成 JNI 启动 `:engine` |
| `internal/nativeruntime/*`（bundle/controller/process） | **删除** | QEMU 专用，含写死的 `qemu-system-x86_64.exe` |
| `internal/secretfd/` | **删除** | fd 传密钥换成 JNI 参数或 `filesDir` 下 0600 文件 |
| `job_protocol_windows.go` | **删除** | 命名管道换 local socket + capability |
| `native-runtime/` 整个目录 | **删除** | Dockerfile、init、kernel、QEMU 锁、补丁全部作废 |
| `legacy/v1/`（120MB） | **移出仓库** | 与 Android 版无关 |
| `src/main/`、`src/renderer/`、`web/` | **重写为 Compose** | 约 10k 行 JS → 估 6~8k 行 Kotlin |
| `electron/`、`electron-builder.native.cjs` | **删除** | 换 AGP |
| `test/electron/*`、`test/native/*` | **大部分作废** | 保留纯逻辑单测 |

---

## 4. 四个必须改的点

### 4.1 引擎启动：exec → JNI

现状：`exec("/system/bin/lite", "--native-service", ...)`。
问题：Android 10+ 对 `targetSdk>=29` 有 W^X 限制，`exec` 应用目录里的二进制可能被拒（本机实测当前容器允许，但不保证）。

改法：把 `lite` 编成 `liblite.so`，暴露一个入口：

```c
// lite_jni.c —— 保持与现有 CLI 完全一致的参数语义
JNIEXPORT jint JNICALL
Java_...Engine_start(JNIEnv* env, jobject, jstring baseDir, jint port) {
    // 起线程跑 lite_main，失败立即返回错误码
}
```

JNI 层只做三件事：切工作目录到 `filesDir`、把 `ANDROID_DATA`/`ANDROID_ROOT` 设好、起线程。**lite 内部的 HTTP 服务、登录流程、hook 安装全部沿用。**

### 4.2 目录与密钥

| 现在 | 改成 |
| --- | --- |
| `/data`（guest 内挂载 ext4） | `Context.getFilesDir()` |
| `/run/control.secret`（fw_cfg 注入） | `filesDir/capability` 0600，或直接 JNI 传 `jstring` |
| `/usr/local/android/cert.pem` | `res/raw/cacert.pem` 解到 `filesDir`，路径通过 JNI 传 |

### 4.3 传输：删掉 QEMU 端口转发

现在 `bundle.go:279` 用 `hostfwd=tcp:...-:12340` 把宿主端口映射进 VM。
安卓上 `127.0.0.1` 天然可达，**这一层整个消失**，`guestclient.New(12341, capability)` 直接连。

### 4.4 下载落盘：SAF / MediaStore

现在直接写用户选的目录。Android 10+ 必须走 `MediaStore` 或 `ACTION_OPEN_DOCUMENT_TREE`：

- 默认落 `Music/Apple Music/`（MediaStore，无需权限）。
- 高级用户选目录则持久化 `treeUri`。

---

## 5. 里程碑

| 阶段 | 内容 | 完成判据 | 预估 |
| --- | --- | --- | --- |
| M0 | arm64 `liblite.so` 编出来并能加载 | `System.loadLibrary("lite")` 不崩，`/status` 返回 200 | **工具链已实测打通**（见附录 B），剩 wrapper 源码编译 |
| M1 | 引擎跑通登录 | 真账号登录 + 2FA，拿到 developer/media token | 2~3 天 |
| M2 | 单曲 ALAC 下载 | 下完一首，`ffprobe` 校验 ALAC + 标签/封面/歌词 | 3~5 天 |
| M3 | UI + 前台服务 | 浏览/搜索/下载队列/通知，后台不断 | 1~2 周 |
| M4 | 打包签名 | 安装、冷启动、卸载干净 | 2~3 天 |

M0 原本是唯一有真实不确定性的阶段——因为 NDK 只发 x86_64 宿主。**这一点已经在 aarch64 机器上实测穿过**（附录 B），不需要 x86_64 主机，也不需要 Docker。剩余工作只是把 wrapper 源码本身编译过来。

---

## 6. 风险与对策

| 风险 | 等级 | 对策 |
| --- | --- | --- |
| **第三方授权未清** | 高 | 与平台无关。APK 直接安装反而更显眼；公开分发前必须解决 `/NOTICE` 里列的每一项 |
| `exec` W^X 限制 | 中 | 已经用 JNI `.so` 规避，不 exec |
| SELinux 拒绝加载 | 低 | **本机实测通过**：应用私有目录的 `.so` 被正常加载（见附录） |
| Play Integrity / 设备指纹 | 中 | 只做侧载可忽略；上架不可能 |
| 2FA / 会话刷新 | 中 | lite 已有 `token_cache.json`，沿用 |
| 存储权限碎片化 | 中 | MediaStore 优先，SAF 兜底 |
| 签名与更新 | 低 | 自签 + 自建更新检查 |

---

## 7. 收益量化

| 指标 | 现在（Windows/QEMU） | 改造后（Android APK） |
| --- | --- | --- |
| 分发体积 | 244 MB | ≈ 85 MB（64MB Apple 库 + Go .so + UI） |
| 常驻内存 | QEMU 虚拟机 + Electron + Go | 单进程 Go + Compose |
| 冷启动 | Electron 引导 + VM 引导 | 应用冷启动 |
| 平台 | 仅 Windows x64 | 仅 Android arm64 |
| 构建依赖 | Docker + NDK + QEMU 锁文件 | AGP + NDK |

代价也很明确：**丢掉 Windows 用户**。如果两个平台都要，等于维护两套引擎宿主。

---

## 附录：本机实测记录（2026-11-01）

设备：aarch64 安卓，Android 14（OPPO 系），proot Ubuntu 24.04。

1. 从 Apple Music 4.9.7.2 全 ABI APK 解出 **19 个 arm64 库**，共 64MB。
2. 用设备自带 `/system/bin/linker64` 解析依赖：

   | 库 | 结果 | 解析库数 |
   | --- | --- | --- |
   | `libandroidappmusic.so` | exit=0 | 273 |
   | `libstoreservicescore.so` | exit=0 | 264 |
   | `libmediaplatform.so` | exit=0 | 263 |
   | `libCoreFP.so` | exit=0 | 7 |
   | `libCoreADI.so` | exit=0 | 6 |

3. 加载路径全部来自应用私有目录 + `/system/lib64` + `/apex/com.android.*/lib64`，无需 root、无需 chroot、无需 QEMU。
4. Hook 目标符号在 arm64 库中确认存在：
   - `libstoreservicescore.so` → `AuthenticateRequest::_makeMessage`
   - `libmediaplatform.so` → `HTTPMessage::setHeader`
5. `/sdcard` 为 noexec（实测 Permission denied），产物必须放应用私有目录。
6. 补上 23 个 APEX 路径后，原先两个 `CANNOT LINK`（`libcom.android.tethering.connectivity_native.so`、`libicu.so`）全部消失——它们本就存在于 `/apex`，只是缺一份 linker config。

---

## 附录 B：M0 工具链验证记录（2026-11-01，同机实测）

目标：证明「在 aarch64 机器上，不用 x86_64 宿主、不用 Docker，能否产出可运行的 arm64 Android 原生库」。

### 结论：能，全链路已跑通

| 阶段 | 内容 | 结果 |
| --- | --- | --- |
| A | 不依赖 libc 的最小 `.so` | ✅ 编译成功，设备 linker 加载 `exit=0` |
| B | 依赖 libc/pthread/malloc 的 `.so` | ✅ 依赖解析到 `/apex` 的 bionic libc |
| C | 真正的 arm64 Android 可执行文件 | ✅ 在设备上 `dlopen` 并调用，`exit=0` |
| D | C++ + `libc++_shared`（`std::regex`/`std::function`） | ✅ 输出 `libcpp-ok re=42 sq=49` |

阶段 C 的实际输出：

```
amdl_selftest -> 4 | counter=4 pid=22165 libc-ok
amdl_add(19,23) = 42
amdl_cxx_probe -> 21 | libcpp-ok re=42 sq=49
exit=0
```

### 构建配方

```bash
# 1. 编译器（Ubuntu 24.04 arm64）
apt-get install -y --no-install-recommends clang lld

# 2. NDK sysroot —— 只取需要的部分
#    NDK r23b 整包 717MB，其中约 600MB 是 x86_64 宿主的 clang 二进制，用不上。
#    用 HTTP Range 只抽 sysroot：实际传输 51.1MB / 1971 个文件。
python3 fetch_sysroot.py

# 3. Android 版 compiler-rt（Ubuntu 的 clang 不自带，0.43MB）
#    从同一个包里单独取出，放到 clang 的 resource dir
cp ndk/usr/lib/aarch64-linux-android/libclang_rt.builtins-aarch64-android.a \
   /usr/lib/llvm-18/lib/clang/18/lib/linux/

# 4. 编共享库
SYS=/root/workspace/ndk
L=$SYS/usr/lib/aarch64-linux-android/24
clang --target=aarch64-linux-android24 --sysroot=$SYS \
      -fuse-ld=lld -rtlib=compiler-rt -shared -fPIC -O2 \
      -L$L -o libfoo.so foo.c -lc -lm -ldl

# 5. 编可执行文件（NDK 标准配方）
clang --target=aarch64-linux-android24 --sysroot=$SYS \
      -fuse-ld=lld -rtlib=compiler-rt -O2 -L$L -o prog main.c \
      -lc -lm -ldl -Wl,-pie -Wl,--dynamic-linker=/system/bin/linker64
```

### 两个坑

1. **`-nodefaultlibs` 不是必须的**，但 Ubuntu 的 clang 默认给出 `-lgcc`，且 Android 版 compiler-rt 不在 resource dir 里。补上第 3 步就恢复正常默认参数。
2. **API 级的库目录**指的是 `sysroot/usr/lib/aarch64-linux-android/24/`（含 `libc.so` 等 stub），不是上一层的 `libc.a`。漏了 `-L` 会报 `unable to find library -lpthread`——顺便说，API 24 起 pthread 已并入 libc，不要再 `-lpthread`。

### 对 M0 的意义

M0 上最大的未知（「aarch64 机器能不能自己编出 arm64 Android 原生库」）已经消除。剩下的只是把 wrapper 的 C++ 源码编过来，那属于工作量而不是风险。

---

## 附录 C：M0 收尾实验（lite 本体交叉编译，2026-11-01）

目标：把 wrapper 的 `lite` 真正编成 arm64 并在设备上跑起来。

### 做到了什么

| 步骤 | 结果 |
| --- | --- |
| 拉取 wrapper 源码 `2fd7e0ea` | ✅ SHA-256 与 `inputs.lock.json` 完全一致 |
| 应用仓库三个补丁 | ✅ `lite-native` / `lite-session` / `lite-store-bridge` 全部干净应用 |
| 交叉编译 Dobby（arm64） | ✅ 手写源文件清单，31 个文件编成 `libdobby.a` |
| 交叉编译 lite | ✅ 6 个 `.cpp` + cJSON + Dobby 链接成 862KB 的 aarch64 可执行文件 |
| 设备上解析依赖 | ✅ 274 个库全部解析，含 `libCoreFP` / `libstoreservicescore` |
| 启动 | ✅ 输出 `[INFO] initializing...` |

也就是说：**工具链、依赖库、Dobby、编译、链接、加载这条链路，全部打通了。**

### 但是：初始化时段错误

根因不是编译器，而是 **arm64 的 Apple 库与 x86-64 的导出符号不一致**。

`import.h` 声明了 97 个要导入的符号。逐个比对两个 ABI 的导出集合：

| | 数量 |
| --- | --- |
| arm64 库导出符号 | 47,467 |
| x86-64 库导出符号 | 112,992 |
| `import.h` 在 arm64 缺失 | **7** |
| 其中只在 arm64 缺（x86-64 有） | **4** |

这 4 个是：

1. `std::make_shared<storeservicescore::AuthenticateFlow>` 
2. `std::make_shared<storeservicescore::RequestContext>`
3. `std::make_shared<androidstoreservices::AndroidPresentationInterface>`
4. `FootHillConfig::config(std::string const&)`

**第 4 个已经定位到原因**——它不是不存在，是**签名漂移**：

```
x86-64: _ZN14FootHillConfig6configERKNSt6__ndk1...   // 参数 const string&
arm64:  _ZN14FootHillConfig6configENSt6__ndk1...      // 参数 string 按值
```

同一个函数，arm64 版按值传参。这说明 arm64 那套库不是同一份源码同一套编译参数出来的，`import.h` 里那批手写 mangled name 是按 x86-64 校准的。

前 3 个是 `make_shared` 模板实例化：`AuthenticateFlow` 在 arm64 里有 37 个符号（构造、析构、run、response 都在），只是这个模板实例化被内联进了调用方，没有作为动态符号导出。

### 结论

「重编到 arm64 就行」这个假设**在这一层被证伪**，但缺口很小且边界清楚：

- 不是架构不兼容，是 **ABI 符号集漂移**，只有 4 个点。
- 修法是可做的：`FootHillConfig::config` 换成按值签名的声明即可；3 个 `make_shared` 要么按导出构造函数手工构造 `shared_ptr`（需要推导对象大小），要么 hook arm64 里内联它的调用点。
- 这项工作与「重写 FairPlay」完全不是一个量级，但它确实是**必须做的移植工作**，不能靠改编译参数绕过。

### 另一处硬发现：播放路径的寄存器钩子是 x86-64 专属

`lite/playback.cpp` 的 `r1_capture_cb` 直接从 `rsi` / `r9` / `rbp` / `rcx` 抓 CBCS 密钥上下文，并从 `rbp - 0x2000` 读栈上状态缓冲区（`0x8000` / `0x2100` 两个固定大小）。这段是**上游代码**，不是本仓库补丁引入的。

AArch64 上必须重新推导：调用约定换成 `x0-x7` / `x29`，两个栈偏移要按 arm64 的真实栈帧重新定位。这是本次实验里最实打实的移植工作量。

本次实验在 arm64 上把它短路了（`#if !defined(__x86_64__)` 直接 return），其余部分照常编译 —— 这也是能编译通过的原因。

### C.2 真正的根因：sret 寄存器不同

崩溃定位到 `DeviceGUID::instance()`。反汇编两边入口：

| ABI | 入口指令 | 隐藏返回指针位置 |
| --- | --- | --- |
| x86-64 SysV | `mov %rdi, %rbx` | **rdi（参数 1）** |
| AArch64 | `mov x19, x8` | **x8** |

`import.h` 把 out 指针当普通参数传 → x86-64 上恰好落进 rdi，**碰巧正确**；arm64 上落进 x0，**传错寄存器**，callee 拿到垃圾 sret 指针后写飞。

这条规则影响的不止一个函数，而是**所有返回非平凡类型的导入**。两个已验证的修法（都是汇编跳板，尾调用 `b` 保持 x30）：

```asm
/* 静态函数：只需搬 sret */
amdl_deviceguid_instance:
    mov x8, x0
    b   _ZN17storeservicescore10DeviceGUID8instanceEv

/* 非静态成员：搬 sret 后其余参数整体左移一位 */
amdl_deviceguid_configure:
    mov x8, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    b   _ZN17storeservicescore10DeviceGUID9configureERKNSt6__ndk1...
```

改完后 `init()` 完整跑通，输出走到 `[TRACE] init done`，进入 `initializing ctx...`。

### C.3 当前位置

剩下唯一的阻塞是三个 `make_shared` 桩。好消息是可以在 arm64 上重建，不需要 x86：

- arm64 导出了 `__shared_ptr_emplace<RequestContext>` 的虚表和 `RequestContext::RequestContext(std::string const&)` 构造函数。
- x86-64 的 `make_shared` 反汇编里 `mov $0x2a8,%edi` 直接给出分配大小：**680 字节**。
- 仓库对 `RequestContextConfig` 已经用过同样手法（自己分配 + 伪造 vtbl + 调构造函数），可以照做。

### C.4 推进记录（sret 跳板 + 对象重建）

**1. sret 根因确认后，用汇编跳板修了两处：**

| 函数 | 跳板内容 |
| --- | --- |
| `DeviceGUID::instance()` | `mov x8, x0` + 尾调用 |
| `DeviceGUID::configure(...)` | `mov x8, x0` + 参数整体左移一位 + 尾调用 |

**2. 三个 `make_shared` 按 libc++ `__shared_ptr_emplace` 布局手工重建。**

尺寸和对象偏移全部来自 x86-64 版 `make_shared` 的反汇编（`lea 0x18(%rbx)` 之类直接给出偏移）：

| 类 | 分配大小 | 对象偏移 | 构造函数 |
| --- | --- | --- | --- |
| `RequestContext` | 0x2a8 | 0x18 | `RequestContext(std::string const&)` |
| `AuthenticateFlow` | 0x100 | 0x20 | `AuthenticateFlow(shared_ptr<RequestContext> const&)` |
| `AndroidPresentationInterface` | 0x120 | 0x20 | 默认构造 |

控制块：vptr 存 `vtable+0x10`，`use_count` / `weak_count` 置 1。arm64 侧虚表和构造函数都是导出的，所以不需要 x86 机器。

**3. 结果：`init()` 和 `init_ctx()` 全部跑通。**

```
[INFO ] initializing...
[TRACE] config returned
[TRACE] instance returned
[TRACE] init done
[INFO ] initializing ctx...
[SHIM] RequestContext ok
[SHIM] PresentationInterface ok
[TRACE] setDialogHandler / setCredentialsHandler / setPresentationInterface
[TRACE] init_ctx done
[TRACE] init_ctx returned
```

**4. 新的崩溃点：** `setup_services()` → `SVPlaybackLeaseManager` 构造函数 → `RequestContextManager::sharedInstance()`，从静态区读到一个非法指针（`addr=0x790000000c`）。

反汇编显示 `sharedInstance` 从 `.data.rel.ro` 取一个静态指针再解引用；该值此刻是垃圾。怀疑方向：静态初始化顺序 —— 我们不是真正的 app 进程，某些 `__attribute__((constructor))` 或 JNI 侧的一次性初始化没有执行。

### C.5 经验教训（给后续移植用）

1. **不要逐个试错。** 正确做法是把 `import.h` 里 97 个符号全做一次 ABI 比对：x86 入口是否 `mov %rdi,%rXX`、arm64 入口是否 `mov x19, x8`，凡两边都命中的都自动生成跳板。这个审计脚本本轮没跑通（objdump 某些区间返回空），需要修。
2. **调试时先给信号处理器加自检。** 本轮有一次 shim 被整体重写，把崩溃处理器一起删了，导致连续几次「静默 SIGSEGV」，白追了很久。
3. **`objdump` 在 arm64 宿主机上拆不了 x86**，需要 `binutils-x86-64-linux-gnu`。

### C.6 全量 ABI 审计结果

脚本：`/root/workspace/audit_abi.py`（README 级说明见脚本头注释）

方法：对 `import.h` 里每个符号，分别反汇编 x86-64 与 arm64 的入口若干条指令，
命中 `mov %rdi,%rXX` 与 `mov xXX, x8` 的判定为「走 sret」。窗口取 24 条指令。

| 项 | 数量 |
| --- | --- |
| `import.h` 声明符号 | 97 |
| 两个 ABI 都导出 | 85 |
| 只有 arm64 导出 | 1 |
| 只有 x86-64 导出 | 4（即三个 `make_shared` 等） |
| 两边都没有 | 3 |
| **确认需要 sret 跳板** | **13** |

13 个的完整清单在 `/root/workspace/sret_needed.txt`，其中已修 2 个：
`DeviceGUID::instance`、`DeviceGUID::configure`。剩余 11 个待修。

**自校验**：窗口从 12 条放宽到 24 条后，`configure` 从不命中变成命中，
与运行时观察一致（撤掉它的跳板会更早崩溃）。说明这个启发式是可靠的。

**踩过的两个坑**：

1. `objdump` 的 `--start-address` 我按十进制传了整数，它当成十进制地址解析，
   区间全空 → 审计结果假 0。必须格式化成 `0x%x`。
2. arm64 的 `objdump` 把助记符和操作数分在**两个制表符列**里，
   `split('\t')[-1]` 只拿到操作数（`x19, x8`），正则永远匹配不上。

### C.7 当前状态与下一步

运行时现在的表现：`init()` 与 `init_ctx()` 通过，`setup_services()` 里
构造 `SVPlaybackLeaseManager` 时，`RequestContextManager::sharedInstance()`
从静态区取到非法指针（`addr=0x790000000c`）。

下一步很明确：

1. 按 `sret_needed.txt` 把剩下 11 个跳板补全（参数个数可从 `import.h` 的声明里解析）。
2. 再回到 `sharedInstance` 的静态指针问题——若补完跳板仍复现，就说明是静态初始化
   顺序问题，需要找出 Apple 侧那个「一次性初始化」入口并显式调用。

### C.8 批量跳板已落地

脚本：`/root/workspace/gen_trampolines.py`，已接进 `build_lite.sh`。

做法是**不动任何调用点**：

1. 对审计出的 11 个符号生成汇编跳板 `<mangled>__amdl`（统一变换：`x8 <- x0`，其余参数整体左移一位）。
2. 编译完 `.o` 之后，用 `objcopy --redefine-sym` 把这些符号的引用改名到跳板。
3. 跳板末尾 `b <mangled>` 尾调用真实函数，符号由 `.so` 在运行时解析。

本轮结果：

- 生成 11 个跳板，`nm` 确认全部进入产物。
- `playback.o` 改名 5 处、`tokens.o` 改名 4 处（其余符号在当前代码里没有被引用）。
- **当前崩溃点没有变化** —— `RequestContextManager::sharedInstance()` 依旧读到非法指针。

### C.9 对当前崩溃的判断

`sharedInstance` / `clear` / `userAgent` 三个函数是同一个形态：

```asm
adrp x8, 0x65d000
ldr  x8, [x8, #2912]     ; 从 .data 取一个指针
ldr  x0, [x8, #8]        ; 再解引用
```

也就是说数据段里存的是「指向静态 shared_ptr 的指针」，正常情况下由加载器的
`R_AARCH64_RELATIVE` 重定位填好。现在读到的是垃圾（`0x7c0000000c` 这类值）。

结论：这**不是 sret 问题**，跳板修不了它。两个可能方向：

1. 该槽位被我们自己的代码写坏（例如伪造 `__shared_ptr_emplace` 控制块时越界）。
2. Apple 侧有一次性的初始化入口（JNI 或 `__attribute__((constructor))`）在真实 app 进程里会跑，我们这里没跑。

区分方法：在 `init_ctx` 之后、`setup_services` 之前把该槽位的值打印出来，
再和 `configure` 调用后对比 —— 如果是我们写坏的，值会在这两步之间变化。
