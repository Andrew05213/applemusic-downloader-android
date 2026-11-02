/* arm64 兼容层。
 *
 * 事实：arm64 的 Apple 库与 x86-64 版存在 ABI 漂移，import.h 里有 4 个符号对不上。
 *
 * 1) FootHillConfig::config —— 真实存在，只是签名不同：
 *      x86-64: config(std::string const&)
 *      arm64 : config(std::string)          // 按值
 *    反汇编确认参数走 x0、无 x8 隐藏返回指针，所以可以直接转发。
 *    按值语义下 callee 会析构参数，因此必须先做一份真正的深拷贝。
 *
 * 2) 三个 std::make_shared<T> —— arm64 版被内联，未导出。
 *    暂时空实现（调用方已 memset，等价于空 shared_ptr），仅用于让服务起到监听状态。
 */
#include <string>

extern "C" void
_ZN14FootHillConfig6configENSt6__ndk112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEE(
    void *by_value);

extern "C" void
_ZN14FootHillConfig6configERKNSt6__ndk112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEE(
    void *by_ref) {
  // 深拷贝：按值参数由 callee 负责析构，不能让两边共享同一块堆内存
  std::string copy = *reinterpret_cast<std::string *>(by_ref);
  _ZN14FootHillConfig6configENSt6__ndk112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEE(
      &copy);
}

/* ================= arm64 版 make_shared 重建 =================
 * arm64 版把这三个模板实例化内联了、没有导出，于是按 libc++ 的
 * __shared_ptr_emplace 布局手工拼：控制块在前、对象在后。
 * 布局与尺寸来自 x86-64 版 make_shared 的反汇编：
 *   RequestContext               alloc 0x2a8, obj@0x18
 *   AuthenticateFlow             alloc 0x100, obj@0x20
 *   AndroidPresentationInterface alloc 0x120, obj@0x20
 * vptr 统一存 vtable+0x10（跳过 offset-to-top 与 typeinfo）。
 */
#include <cstring>
#include <cstdio>

extern "C" char _ZTVNSt6__ndk120__shared_ptr_emplaceIN17storeservicescore14RequestContextENS_9allocatorIS2_EEEE;
extern "C" char _ZTVNSt6__ndk120__shared_ptr_emplaceIN17storeservicescore16AuthenticateFlowENS_9allocatorIS2_EEEE;
extern "C" char _ZTVNSt6__ndk120__shared_ptr_emplaceIN20androidstoreservices28AndroidPresentationInterfaceENS_9allocatorIS2_EEEE;

extern "C" void
_ZN17storeservicescore14RequestContextC2ERKNSt6__ndk112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE(
    void *, void *);
extern "C" void
_ZN17storeservicescore16AuthenticateFlowC2ERKNSt6__ndk110shared_ptrINS_14RequestContextEEE(void *,
                                                                                         void *);
extern "C" void _ZN20androidstoreservices28AndroidPresentationInterfaceC2Ev(void *);

struct AmdlSharedPtr {
  void *obj;
  void *ctrl;
};

/* 控制块：vptr + use_count + weak_count，两个计数都置 1 */
static void amdl_emplace_init(unsigned char *block, char *vtable) {
  *(void **)block = vtable + 0x10;
  *(int *)(block + 8) = 1;
  *(int *)(block + 12) = 1;
}

extern "C" void
_ZNSt6__ndk110shared_ptrIN17storeservicescore14RequestContextEE11make_sharedIJRNS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEEES3_DpOT_(
    AmdlSharedPtr *out, void *strBuf) {
  unsigned char *block = new unsigned char[0x2a8];
  memset(block, 0, 0x2a8);
  amdl_emplace_init(
      block,
      &_ZTVNSt6__ndk120__shared_ptr_emplaceIN17storeservicescore14RequestContextENS_9allocatorIS2_EEEE);
  void *obj = block + 0x18;
  fprintf(stderr, "[SHIM] RequestContext block=%p obj=%p\n", (void*)block, obj);
  _ZN17storeservicescore14RequestContextC2ERKNSt6__ndk112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE(
      obj, strBuf);
  fprintf(stderr, "[SHIM] RequestContext ok\n");
  out->obj = obj;
  out->ctrl = block;
}

extern "C" void
_ZNSt6__ndk110shared_ptrIN17storeservicescore16AuthenticateFlowEE11make_sharedIJRNS0_INS1_14RequestContextEEEEEES3_DpOT_(
    AmdlSharedPtr *out, AmdlSharedPtr *ctx) {
  unsigned char *block = new unsigned char[0x100];
  memset(block, 0, 0x100);
  amdl_emplace_init(
      block,
      &_ZTVNSt6__ndk120__shared_ptr_emplaceIN17storeservicescore16AuthenticateFlowENS_9allocatorIS2_EEEE);
  void *obj = block + 0x20;
  fprintf(stderr, "[SHIM] AuthenticateFlow block=%p obj=%p\n", (void*)block, obj);
  _ZN17storeservicescore16AuthenticateFlowC2ERKNSt6__ndk110shared_ptrINS_14RequestContextEEE(obj, ctx);
  out->obj = obj;
  out->ctrl = block;
}

extern "C" void
_ZNSt6__ndk110shared_ptrIN20androidstoreservices28AndroidPresentationInterfaceEE11make_sharedIJEEES3_DpOT_(
    AmdlSharedPtr *out) {
  unsigned char *block = new unsigned char[0x120];
  memset(block, 0, 0x120);
  amdl_emplace_init(
      block,
      &_ZTVNSt6__ndk120__shared_ptr_emplaceIN20androidstoreservices28AndroidPresentationInterfaceENS_9allocatorIS2_EEEE);
  void *obj = block + 0x20;
  fprintf(stderr, "[SHIM] PresentationInterface block=%p obj=%p\n", (void*)block, obj);
  _ZN20androidstoreservices28AndroidPresentationInterfaceC2Ev(obj);
  fprintf(stderr, "[SHIM] PresentationInterface ok\n");
  out->obj = obj;
  out->ctrl = block;
}

/* ---- 崩溃诊断 ---- */
#include <signal.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>

extern "C" int backtrace(void **buffer, int size);
extern "C" void backtrace_symbols_fd(void *const *buffer, int size, int fd);

static void amdl_crash_handler(int sig, siginfo_t *info, void *) {
  char msg[128];
  int n = snprintf(msg, sizeof(msg), "\n[CRASH] signal=%d addr=%p\n", sig, info->si_addr);
  if (n > 0) (void)!write(2, msg, (size_t)n);
  void *bt[64];
  int frames = backtrace(bt, 64);
  backtrace_symbols_fd(bt, frames, 2);
  _exit(139);
}

extern "C" void amdl_install_crash_handler() {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = amdl_crash_handler;
  sa.sa_flags = SA_SIGINFO;
  sigaction(SIGSEGV, &sa, nullptr);
  sigaction(SIGABRT, &sa, nullptr);
  sigaction(SIGBUS, &sa, nullptr);
}

__attribute__((constructor)) static void amdl_boot_handler() { amdl_install_crash_handler(); }

/* ---- 诊断：打印 RequestContextManager 静态槽位的值 ----
 * sharedInstance/clear/userAgent 都走：
 *   adrp x8, 0x65d000 ; ldr x8, [x8, #2912]  → 0x65db60
 * 即数据段里存着「指向静态 shared_ptr 的指针」，由加载器重定位填写。 */
#include <link.h>

static uintptr_t amdl_find_base(const char *needle) {
  struct Ctx {
    const char *needle;
    uintptr_t base;
  } ctx = {needle, 0};
  dl_iterate_phdr(
      [](struct dl_phdr_info *info, size_t, void *data) -> int {
        auto *c = (Ctx *)data;
        if (info->dlpi_name && strstr(info->dlpi_name, c->needle)) {
          c->base = (uintptr_t)info->dlpi_addr;
          return 1;
        }
        return 0;
      },
      &ctx);
  return ctx.base;
}

extern "C" void amdl_dump_manager_slot(const char *tag) {
  static uintptr_t base = 0;
  if (!base) base = amdl_find_base("libandroidappmusic.so");
  if (!base) {
    fprintf(stderr, "[SLOT] %s 未找到 libandroidappmusic.so\n", tag);
    return;
  }
  uintptr_t slot = base + 0x65db60;
  void *value = *(void **)slot;
  fprintf(stderr, "[SLOT] %-22s base=%p slot=%p *slot=%p\n", tag, (void *)base,
          (void *)slot, value);
}
