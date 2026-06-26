const std = @import("std");

pub const KERNEL_OFFSET = 0xFFFFFFFF80000000;

pub inline fn virtToPhys(vaddr: anytype) u32 {
    const v = @intFromPtr(vaddr);
    return if (v < KERNEL_OFFSET) @intCast(v) else @intCast(v -% KERNEL_OFFSET);
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
    asm volatile ("invlpg (%[v])" : : [v] "r" (vaddr) : "memory");
}

/// Map a physical MMIO region at its physical address (identity map)
/// using the pd_mmio page directory (covers physical 3-4GB).
/// phys must be in 0xC0000000-0xFFFFFFFF range. 4KB-aligned.
pub fn mapMmioRegion(phys: u64, size: u64, page_alloc: anytype) void {
    const boot = @import("x86_64/boot.zig");
    const pd_phys = @intFromPtr(&boot.pd_mmio) - KERNEL_OFFSET;
    const pd: [*]volatile u64 = @ptrFromInt(pd_phys);

    var addr = phys;
    const end = addr + size;
    while (addr < end) {
        const pd_idx = (addr - 0xC0000000) / (2 * 1024 * 1024);
        if (pd_idx >= 512) break;
        if (addr % (2 * 1024 * 1024) == 0 and addr + (2 * 1024 * 1024) <= end) {
            pd[pd_idx] = addr | 0x93;
            addr += 2 * 1024 * 1024;
        } else {
            const pt_page = page_alloc.allocPage() orelse return;
            const pt_phys = virtToPhys(pt_page);
            const pt_virt: [*]u64 = @ptrFromInt(@intFromPtr(pt_page));
            @memset(@as([*]u8, @ptrCast(pt_virt))[0..4096], 0);
            pd[pd_idx] = pt_phys | 0x03;
            const pt_end = @min(addr + 2 * 1024 * 1024, end);
            var pt_addr = addr;
            while (pt_addr < pt_end) {
                const pt_idx = (pt_addr - addr) / 4096;
                if (pt_idx >= 512) break;
                pt_virt[pt_idx] = pt_addr | 0x13;
                pt_addr += 4096;
            }
            addr = pt_end;
        }
    }
    asm volatile ("mov %[cr3], %%cr3" : : [cr3] "r" (@as(u64, @intFromPtr(&boot.pml4)) - KERNEL_OFFSET) : "memory");
}

pub fn initCpu() void {
    const result = cpuid(1, 0);
    _ = result;

    // Enable SSE (required because LLVM emits SSE ops like xorps/movups)
    // CR0: clear EM (bit 4), set MP (bit 1)
    asm volatile (
        \\movq    %%cr0, %%rax
        \\andq    $~0x10, %%rax
        \\orq     $0x02, %%rax
        \\movq    %%rax, %%cr0
    );
    // CR4: set OSFXSR (bit 9) and OSXMMEXCPT (bit 10)
    asm volatile (
        \\movq    %%cr4, %%rax
        \\orq     $0x600, %%rax
        \\movq    %%rax, %%cr4
    );
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
