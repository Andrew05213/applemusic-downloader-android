/* AArch64 的 sret（隐藏返回指针）走 x8，而 x86-64 SysV 走 rdi（参数 1）。
 * wrapper 的 import.h 按 x86-64 写，指针落在 x0；这里做一次寄存器搬移后
 * 用 b（尾调用）进入真实函数，x30 保持为调用方的返回地址。 */
    .text
    .globl amdl_deviceguid_instance
    .type amdl_deviceguid_instance, %function
amdl_deviceguid_instance:
    mov x8, x0
    b   _ZN17storeservicescore10DeviceGUID8instanceEv

/* DeviceGUID::configure 是非静态成员函数：
 *   x86-64: rdi=sret, rsi=this, rdx=a1, rcx=a2, r8=a3, r9=a4
 *   arm64 : x8=sret,  x0=this, x1=a1, x2=a2, x3=a3, x4=a4
 * 所以除了搬 sret，还要把其余参数整体左移一位。 */
    .globl amdl_deviceguid_configure
    .type amdl_deviceguid_configure, %function
amdl_deviceguid_configure:
    mov x8, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    b   _ZN17storeservicescore10DeviceGUID9configureERKNSt6__ndk112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEES9_RKjRKb
