const std = @import("std");

pub fn sti() void {
    asm volatile ("sti");
}

pub fn cli() void {
    asm volatile ("cli");
}

pub fn hlt() void {
    asm volatile ("hlt");
}

pub fn cpuid(eax: u32, ecx: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    var rax: u32 = eax;
    var rbx: u32 = undefined;
    var rcx: u32 = ecx;
    var rdx: u32 = undefined;
    asm volatile ("cpuid"
        : [rax] "+{eax}" (rax),
          [rbx] "={ebx}" (rbx),
          [rcx] "+{ecx}" (rcx),
          [rdx] "={edx}" (rdx)
    );
    return .{ .eax = rax, .ebx = rbx, .ecx = rcx, .edx = rdx };
}

pub fn wrmsr(msr: u32, value: u64) void {
    const lo = @as(u32, @truncate(value));
    const hi = @as(u32, @truncate(value >> 32));
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (lo),
          [hi] "{edx}" (hi)
    );
}

pub fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi)
        : [msr] "{ecx}" (msr)
    );
    return (@as(u64, hi) << 32) | lo;
}

pub fn initCpu() void {
    const result = cpuid(1, 0);
    _ = result;
    sti();
}

test "cpuid works" {
    const result = cpuid(0, 0);
    try std.testing.expect(result.eax > 0);
}

test "rdtsc works" {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc" : [lo] "={eax}" (lo), [hi] "={edx}" (hi));
    const tsc = (@as(u64, hi) << 32) | lo;
    try std.testing.expect(tsc > 0);
}
