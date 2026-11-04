/* 仅用于诊断：崩溃时打印调用栈 */
#include <signal.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
extern "C" int backtrace(void **buffer, int size);
extern "C" void backtrace_symbols_fd(void *const *buffer, int size, int fd);
static void h(int sig, siginfo_t *info, void *) {
  char m[128];
  int n = snprintf(m, sizeof(m), "\n[CRASH] sig=%d addr=%p\n", sig, info->si_addr);
  if (n > 0) (void)!write(2, m, (size_t)n);
  void *bt[64]; int f = backtrace(bt, 64);
  backtrace_symbols_fd(bt, f, 2);
  _exit(139);
}
__attribute__((constructor)) static void inst() {
  struct sigaction sa; memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = h; sa.sa_flags = SA_SIGINFO;
  sigaction(SIGSEGV, &sa, nullptr); sigaction(SIGABRT, &sa, nullptr); sigaction(SIGBUS, &sa, nullptr);
}
