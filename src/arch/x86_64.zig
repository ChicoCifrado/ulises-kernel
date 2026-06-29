const std = @import("std");

pub const KERNEL_OFFSET = 0x0;

pub inline fn virtToPhys(vaddr: anytype) u32 {
    return @intCast(@intFromPtr(vaddr));
}

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

pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port)
    );
}

pub fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port)
    );
}

pub fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "{dx}" (port)
    );
}

pub fn inb(port: u16) u8 {
    var val: u8 = undefined;
    asm volatile ("inb %[port], %[val]"
        : [val] "={al}" (val)
        : [port] "{dx}" (port)
    );
    return val;
}

pub fn serialCanRead() bool {
    return inb(0x3F8 + 5) & 1 != 0;
}

pub fn serialReadChar() u8 {
    while ((inb(0x3F8 + 5) & 1) == 0) {}
    return inb(0x3F8);
}

pub fn invlpg(vaddr: u64) void {
    const ptr: *volatile u64 = @ptrFromInt(vaddr);
    asm volatile ("invlpg %[v]"
        :
        : [v] "m" (ptr.*),
        : .{ .memory = true }
    );
}

/// Map a physical MMIO region at its physical address (identity map).
/// phys must be in 0xC0000000-0xFFFFFFFF range. 4KB-aligned.
pub fn mapMmioRegion(phys: u64, size: u64, page_alloc: anytype) void {
    _ = page_alloc;
    _ = size;
    // Identity mapping via PD already covers 0-1GB with 2MB pages.
    // phys is already accessible. Nothing to do.
    _ = phys;
}

fn readCr0() u64 {
    var val: u64 = undefined;
    asm volatile ("movq %%cr0, %[val]"
        : [val] "=r" (val)
    );
    return val;
}

fn writeCr0(val: u64) void {
    asm volatile ("movq %[val], %%cr0"
        :
        : [val] "r" (val)
        : .{ .memory = true }
    );
}

fn readCr4() u64 {
    var val: u64 = undefined;
    asm volatile ("movq %%cr4, %[val]"
        : [val] "=r" (val)
    );
    return val;
}

fn writeCr4(val: u64) void {
    asm volatile ("movq %[val], %%cr4"
        :
        : [val] "r" (val)
        : .{ .memory = true }
    );
}

pub fn initCpu() void {
    const result = cpuid(1, 0);
    _ = result;

    // Enable SSE (required because LLVM emits SSE ops like xorps/movups)
    // CR0: clear EM (bit 4), set MP (bit 1); CR4: set OSFXSR (bit 9) and OSXMMEXCPT (bit 10)
    var cr0 = readCr0();
    cr0 &= ~@as(u64, 0x10);
    cr0 |= 0x02;
    writeCr0(cr0);
    var cr4 = readCr4();
    cr4 |= 0x600;
    writeCr4(cr4);
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
