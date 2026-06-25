const std = @import("std");
const builtin = @import("builtin");
const x86_64 = @import("x86_64.zig");
const spinlock = @import("../sync/spinlock.zig");
const pmm = @import("../mem/pmm.zig");

const TRAMPOLINE_ADDR = 0x7000;
const TRAMPOLINE_SIZE = 256;
const AP_STACK_SIZE = 4096;
const MAX_CPUS = 32;
const LAPIC_BASE_DEFAULT = @as(u64, 0xFEE00000);
const IOAPIC_BASE_DEFAULT = @as(u64, 0xFEC00000);

const TRAMP_DATA_OFF = 0x80;
const TRAMP_BSP_PML4_OFF = TRAMP_DATA_OFF;
const TRAMP_PER_CPU_OFF = TRAMP_DATA_OFF + 8;
const TRAMP_AP_ENTRY_OFF = TRAMP_DATA_OFF + 16;
const TRAMP_GDT_OFF = TRAMP_DATA_OFF + 24;
const TRAMP_GDT_DESC_OFF = TRAMP_DATA_OFF + 48;

const LapicReg = struct {
    pub const ID = 0x20;
    pub const VER = 0x30;
    pub const TPR = 0x80;
    pub const SVR = 0xF0;
    pub const EOI = 0xB0;
    pub const ESR = 0x280;
    pub const ICR_LOW = 0x300;
    pub const ICR_HIGH = 0x310;
    pub const LVT_LINT0 = 0x350;
    pub const LVT_LINT1 = 0x360;
    pub const LVT_ERROR = 0x370;
};

const IcrLow = packed struct(u32) {
    vector: u8,
    delivery_mode: u3,
    dest_mode: u1 = 0,
    delivery_status: u1 = 0,
    reserved1: u1 = 0,
    level: u1 = 0,
    trigger: u1 = 0,
    reserved2: u2 = 0,
    dest_shorthand: u2 = 0,
    reserved3: u12 = 0,
};

const CpuState = enum(u8) {
    disabled = 0,
    running = 1,
    halted = 2,
    startup = 3,
};

pub const PerCpu = extern struct {
    cpu_id: u32,
    apic_id: u32,
    stack_base: u64,
    lapic_base: u64,
    state: CpuState,
    _pad: [3]u8 = [_]u8{0} ** 3,
    _rsvd: [36]u8 = [_]u8{0} ** 36,
};

comptime {
    if (@sizeOf(PerCpu) != 64) @compileError("PerCpu must be 64 bytes");
}
comptime {
    if (@sizeOf(IcrLow) != 4) @compileError("IcrLow must be 4 bytes");
}

var cpu_table: [MAX_CPUS]PerCpu = undefined;
var cpu_count: u32 = 0;
var bsp_apic_id: u32 = 0;
var lapic_base: u64 = LAPIC_BASE_DEFAULT;
var page_alloc: ?*pmm.PageAllocator = null;

fn lapicRead(reg: u32) u32 {
    return @as([*]volatile u32, @ptrFromInt(lapic_base + reg))[0];
}

fn lapicWrite(reg: u32, val: u32) void {
    @as([*]volatile u32, @ptrFromInt(lapic_base + reg))[0] = val;
}

pub fn lapicId() u32 {
    return lapicRead(LapicReg.ID) >> 24;
}

fn lapicSendIcr(icr_low: IcrLow, dest: u8) void {
    lapicWrite(LapicReg.ICR_HIGH, @as(u32, dest) << 24);
    lapicWrite(LapicReg.ICR_LOW, @as(u32, @bitCast(icr_low)));
    while (lapicRead(LapicReg.ICR_LOW) & (1 << 12) != 0) {
        asm volatile ("pause");
    }
}

// --- ACPI MADT parsing ---

fn acpiFindRsdp() ?u64 {
    const sig = "RSD PTR ";
    var addr: u64 = 0xE0000;
    while (addr < 0x100000) {
        if (std.mem.eql(u8, @as(*const [8]u8, @ptrFromInt(addr)), sig[0..8])) return addr;
        addr += 16;
    }
    addr = 0x80000;
    while (addr < 0xA0000) {
        if (std.mem.eql(u8, @as(*const [8]u8, @ptrFromInt(addr)), sig[0..8])) return addr;
        addr += 16;
    }
    return null;
}

fn acpiChecksum(ptr: [*]const u8, len: usize) bool {
    var sum: u8 = 0;
    for (0..len) |i| sum +%= ptr[i];
    return sum == 0;
}

fn parseMadt(madt: [*]const u8, len: usize) void {
    const local_apic = @as(*const u32, @ptrFromInt(@intFromPtr(madt) + 0x24)).*;
    lapic_base = if (local_apic != 0) @as(u64, local_apic) else LAPIC_BASE_DEFAULT;

    var off: usize = 0x2C;
    while (off + 1 < len) {
        const entry_type = madt[off];
        const entry_len = madt[off + 1];
        if (entry_len < 2 or off + entry_len > len) break;

        if (entry_type == 0) {
            if (cpu_count < MAX_CPUS) {
                const apic_id = madt[off + 3];
                const flags = @as(*const u32, @ptrFromInt(@intFromPtr(madt) + off + 4)).*;
                if (flags & 1 != 0) {
                    cpu_table[cpu_count] = .{
                        .cpu_id = cpu_count,
                        .apic_id = apic_id,
                        .state = .disabled,
                        .stack_base = 0,
                        .lapic_base = lapic_base,
                    };
                    cpu_count += 1;
                }
            }
        }
        off += entry_len;
    }
}

fn parseAcpiTables() void {
    const rsdp_addr = acpiFindRsdp() orelse return;
    const revision = @as(*const u8, @ptrFromInt(rsdp_addr + 15)).*;

    if (revision >= 2) {
        const xsdt = @as(*const u64, @ptrFromInt(rsdp_addr + 24)).*;
        if (xsdt != 0) {
            const xsdt_len: usize = @intCast(@as(*const u32, @ptrFromInt(xsdt + 4)).*);
            if (acpiChecksum(@as([*]const u8, @ptrFromInt(xsdt)), xsdt_len)) {
                for (0..(xsdt_len - 36) / 8) |i| {
                    const entry = @as(*const u64, @ptrFromInt(xsdt + 36 + i * 8)).*;
                    if (std.mem.eql(u8, @as(*const [4]u8, @ptrFromInt(entry)), "APIC")) {
                        const madt_len: usize = @intCast(@as(*const u32, @ptrFromInt(entry + 4)).*);
                        parseMadt(@as([*]const u8, @ptrFromInt(entry)), madt_len);
                        return;
                    }
                }
            }
        }
    }

    const rsdt = @as(*const u32, @ptrFromInt(rsdp_addr + 16)).*;
    if (rsdt == 0) return;
    const hdr = @as([*]const u8, @ptrFromInt(@as(u64, rsdt)));
    const rsdt_len: usize = @intCast(@as(*const u32, @ptrFromInt(rsdt + 4)).*);
    if (!acpiChecksum(hdr, rsdt_len)) return;

    for (0..(rsdt_len - 36) / 4) |i| {
        const entry = @as(*const u32, @ptrFromInt(rsdt + 36 + i * 4)).*;
        if (std.mem.eql(u8, @as(*const [4]u8, @ptrFromInt(@as(u64, entry))), "APIC")) {
            const madt_len: usize = @intCast(@as(*const u32, @ptrFromInt(@as(u64, entry + 4))).*);
            parseMadt(@as([*]const u8, @ptrFromInt(@as(u64, entry))), madt_len);
            return;
        }
    }
}

// --- Local APIC init ---

fn lapicInit() void {
    const apic_base = x86_64.rdmsr(0x1B);
    if (apic_base & (1 << 11) == 0) {
        x86_64.wrmsr(0x1B, apic_base | (1 << 11));
    }

    lapicWrite(LapicReg.SVR, lapicRead(LapicReg.SVR) | (1 << 8) | 0xFF);
    lapicWrite(LapicReg.TPR, 0);
    lapicWrite(LapicReg.LVT_LINT0, (1 << 16));
    lapicWrite(LapicReg.LVT_LINT1, (4 << 8) | (1 << 16));
    lapicWrite(LapicReg.LVT_ERROR, (1 << 16) | 0xFE);
    lapicWrite(LapicReg.ESR, 0);
    _ = lapicRead(LapicReg.ESR);
    lapicWrite(LapicReg.ESR, 0);
    _ = lapicRead(LapicReg.ESR);
}

// --- Trampoline (AP startup code) ---

fn buildTrampoline() []const u8 {
    var buf: [TRAMPOLINE_SIZE]u8 = undefined;
    @memset(&buf, 0xCC);

    var off: usize = 0;

    // [0x00] 16-bit real mode entry
    const entry16 = [_]u8{
        0xFA,       // cli
        0xFC,       // cld
        0x31, 0xC0, // xor ax, ax
        0x8E, 0xD8, // mov ds, ax
        0x8E, 0xC0, // mov es, ax
        0x8E, 0xD0, // mov ss, ax
        0xBC, 0xFC, 0x7F, // mov sp, 0x7FFC
        0xE4, 0x92, // in al, 0x92
        0x0C, 0x02, // or al, 2
        0xE6, 0x92, // out 0x92, al
    };
    @memcpy(buf[off..][0..entry16.len], &entry16);
    off += entry16.len;

    // lgdt [gdt_desc]
    const gdd = TRAMPOLINE_ADDR + TRAMP_GDT_DESC_OFF;
    buf[off + 0] = 0x0F;
    buf[off + 1] = 0x01;
    buf[off + 2] = 0x16;
    buf[off + 3] = @as(u8, @truncate(gdd));
    buf[off + 4] = @as(u8, @truncate(gdd >> 8));
    off += 5;

    // mov eax, cr0; or al, 1; mov cr0, eax
    for ([_]u8{ 0x0F, 0x20, 0xC0 }, 0..) |b, j| buf[off + j] = b;
    off += 3;
    for ([_]u8{ 0x0C, 0x01 }, 0..) |b, j| buf[off + j] = b;
    off += 2;
    for ([_]u8{ 0x0F, 0x22, 0xC0 }, 0..) |b, j| buf[off + j] = b;
    off += 3;

    // jmp far 0x08:start32 (with operand-size override for 32-bit offset)
    const s32 = TRAMPOLINE_ADDR + 0x28;
    for ([_]u8{
        0x66, 0xEA,
        @as(u8, @truncate(s32)), @as(u8, @truncate(s32 >> 8)),
        @as(u8, @truncate(s32 >> 16)), @as(u8, @truncate(s32 >> 24)),
        0x08, 0x00,
    }, 0..) |b, j| buf[off + j] = b;
    off += 8;

    // [0x28] 32-bit protected mode
    off = 0x28;
    const entry32 = [_]u8{
        0xB8, 0x10, 0x00, 0x00, 0x00, // mov eax, 0x10
        0x8E, 0xD8, // mov ds, ax
        0x8E, 0xC0, // mov es, ax
        0x8E, 0xD0, // mov ss, ax
        0x31, 0xC0, // xor eax, eax
        0x8E, 0xE0, // mov fs, ax
        0x8E, 0xE8, // mov gs, ax
    };
    @memcpy(buf[off..][0..entry32.len], &entry32);
    off += entry32.len;

    // mov eax, [bsp_pml4_addr] ; mov cr3, eax
    const pml4_field = TRAMPOLINE_ADDR + TRAMP_BSP_PML4_OFF;
    for ([_]u8{
        0xA1,
        @as(u8, @truncate(pml4_field)), @as(u8, @truncate(pml4_field >> 8)),
        @as(u8, @truncate(pml4_field >> 16)), @as(u8, @truncate(pml4_field >> 24)),
    }, 0..) |b, j| buf[off + j] = b;
    off += 5;
    for ([_]u8{ 0x0F, 0x22, 0xD8 }, 0..) |b, j| buf[off + j] = b;
    off += 2;

    // mov eax, cr4; or eax, 0x20; mov cr4, eax
    for ([_]u8{ 0x0F, 0x20, 0xE0 }, 0..) |b, j| buf[off + j] = b;
    off += 3;
    for ([_]u8{ 0x83, 0xC8, 0x20 }, 0..) |b, j| buf[off + j] = b;
    off += 3;
    for ([_]u8{ 0x0F, 0x22, 0xE0 }, 0..) |b, j| buf[off + j] = b;
    off += 3;

    // mov ecx, 0xC0000080 ; rdmsr ; or eax, 0x100 ; wrmsr
    for ([_]u8{ 0xB9, 0x80, 0x00, 0xC0, 0x00 }, 0..) |b, j| buf[off + j] = b;
    off += 5;
    for ([_]u8{ 0x0F, 0x32 }, 0..) |b, j| buf[off + j] = b;
    off += 2;
    for ([_]u8{ 0x0D, 0x00, 0x01, 0x00, 0x00 }, 0..) |b, j| buf[off + j] = b;
    off += 5;
    for ([_]u8{ 0x0F, 0x30 }, 0..) |b, j| buf[off + j] = b;
    off += 2;

    // mov eax, cr0; or eax, 0x80000000; mov cr0, eax
    for ([_]u8{ 0x0F, 0x20, 0xC0 }, 0..) |b, j| buf[off + j] = b;
    off += 3;
    for ([_]u8{ 0x0D, 0x00, 0x00, 0x00, 0x80 }, 0..) |b, j| buf[off + j] = b;
    off += 5;
    for ([_]u8{ 0x0F, 0x22, 0xC0 }, 0..) |b, j| buf[off + j] = b;
    off += 3;

    // jmp far 0x08:start64
    const s64 = TRAMPOLINE_ADDR + 0x80;
    for ([_]u8{
        0x66, 0xEA,
        @as(u8, @truncate(s64)), @as(u8, @truncate(s64 >> 8)),
        @as(u8, @truncate(s64 >> 16)), @as(u8, @truncate(s64 >> 24)),
        0x08, 0x00,
    }, 0..) |b, j| buf[off + j] = b;
    off += 8;

    // [0x80] 64-bit long mode
    off = 0x80;

    // mov rax, [per_cpu_data]
    const pcpu_field = TRAMPOLINE_ADDR + TRAMP_PER_CPU_OFF;
    for ([_]u8{
        0x48, 0xA1,
        @as(u8, @truncate(pcpu_field)), @as(u8, @truncate(pcpu_field >> 8)),
        @as(u8, @truncate(pcpu_field >> 16)), @as(u8, @truncate(pcpu_field >> 24)),
    }, 0..) |b, j| buf[off + j] = b;
    off += 6;

    // mov rcx, 0xC0000101 ; xor edx, edx ; wrmsr
    for ([_]u8{ 0xB9, 0x01, 0x01, 0xC0, 0x00 }, 0..) |b, j| buf[off + j] = b;
    off += 5;
    for ([_]u8{ 0x31, 0xD2 }, 0..) |b, j| buf[off + j] = b;
    off += 2;
    for ([_]u8{ 0x0F, 0x30 }, 0..) |b, j| buf[off + j] = b;
    off += 2;

    // mov rax, [ap_entry_func]
    const aentry_field = TRAMPOLINE_ADDR + TRAMP_AP_ENTRY_OFF;
    for ([_]u8{
        0x48, 0xA1,
        @as(u8, @truncate(aentry_field)), @as(u8, @truncate(aentry_field >> 8)),
        @as(u8, @truncate(aentry_field >> 16)), @as(u8, @truncate(aentry_field >> 24)),
    }, 0..) |b, j| buf[off + j] = b;
    off += 6;

    // xor ebp, ebp ; call rax
    for ([_]u8{ 0x31, 0xED }, 0..) |b, j| buf[off + j] = b;
    off += 2;
    for ([_]u8{ 0xFF, 0xD0 }, 0..) |b, j| buf[off + j] = b;
    off += 2;

    // cli ; hlt ; jmp $-2
    for ([_]u8{ 0xFA, 0xF4, 0xEB, 0xFE }, 0..) |b, j| buf[off + j] = b;
    off += 4;

    // [0x80 + 24] GDT (3 entries × 8 bytes = 24 bytes)
    off = TRAMP_GDT_OFF;
    for ([_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, 0..) |b, j| buf[off + j] = b;
    off += 8;
    for ([_]u8{ 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xAF, 0x00 }, 0..) |b, j| buf[off + j] = b;
    off += 8;
    for ([_]u8{ 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xAF, 0x00 }, 0..) |b, j| buf[off + j] = b;
    off += 8;

    // GDT descriptor (6 bytes)
    off = TRAMP_GDT_DESC_OFF;
    const gdt_base = TRAMPOLINE_ADDR + TRAMP_GDT_OFF;
    for ([_]u8{
        23, 0,
        @as(u8, @truncate(gdt_base)), @as(u8, @truncate(gdt_base >> 8)),
        @as(u8, @truncate(gdt_base >> 16)), @as(u8, @truncate(gdt_base >> 24)),
    }, 0..) |b, j| buf[off + j] = b;
    off += 6;

    return buf[0..off];
}

var tramp_buf: [TRAMPOLINE_SIZE]u8 = undefined;

fn writeTrampoline() void {
    const code = buildTrampoline();
    @memcpy(tramp_buf[0..code.len], code);
}

// --- AP boot sequence ---

fn readCr3() u64 {
    var val: u64 = undefined;
    asm volatile ("mov %%cr3, %[v]" : [v] "=r" (val));
    return val;
}

fn apMain() callconv(.C) void {
    const cpu = thisCpu();
    cpu.state = .running;
    x86_64.sti();
    while (true) {
        asm volatile ("hlt");
    }
}

fn wakeUpCpu(cpu_id: u32) bool {
    if (cpu_id >= cpu_count) return false;
    const cpu = &cpu_table[cpu_id];
    if (cpu.state != .disabled) return true;

    const stack_mem = page_alloc.?.allocPage() orelse return false;
    cpu.stack_base = @intFromPtr(stack_mem) + AP_STACK_SIZE;

    const dest = @as([*]u8, @ptrFromInt(TRAMPOLINE_ADDR));
    @memcpy(dest[0..tramp_buf.len], &tramp_buf);

    @as(*u64, @ptrFromInt(TRAMPOLINE_ADDR + TRAMP_BSP_PML4_OFF)).* = readCr3();
    @as(*u64, @ptrFromInt(TRAMPOLINE_ADDR + TRAMP_PER_CPU_OFF)).* = @intFromPtr(cpu);
    @as(*u64, @ptrFromInt(TRAMPOLINE_ADDR + TRAMP_AP_ENTRY_OFF)).* = @intFromPtr(&apMain);

    cpu.state = .startup;

    const init_icr = IcrLow{
        .vector = 0,
        .delivery_mode = 5, // INIT IPI
        .level = 1,
        .trigger = 1,
        .dest_shorthand = 3, // all except self
    };
    lapicSendIcr(init_icr, 0);

    for (0..10000) |_| asm volatile ("pause");
    for (0..10000) |_| asm volatile ("pause");

    const sipi_icr = IcrLow{
        .vector = @as(u8, @truncate(TRAMPOLINE_ADDR >> 12)),
        .delivery_mode = 6, // STARTUP IPI
        .dest_shorthand = 3,
    };
    lapicSendIcr(sipi_icr, 0);

    for (0..10000) |_| {
        if (cpu.state == .running) return true;
        asm volatile ("pause");
    }

    lapicSendIcr(sipi_icr, 0);

    for (0..50000) |_| {
        if (cpu.state == .running) return true;
        asm volatile ("pause");
    }

    cpu.state = .disabled;
    return false;
}

// --- Public API ---

pub fn initSmp(page_allocator: *pmm.PageAllocator) void {
    page_alloc = page_allocator;
    if (builtin.target.cpu.arch != .x86_64) return;

    parseAcpiTables();
    lapicInit();

    if (cpu_count == 0) {
        cpu_count = 1;
        cpu_table[0] = .{
            .cpu_id = 0,
            .apic_id = lapicId(),
            .state = .running,
            .stack_base = 0,
            .lapic_base = lapic_base,
        };
    }

    if (cpu_count <= 1) return;

    writeTrampoline();
    for (1..cpu_count) |i| {
        _ = wakeUpCpu(@as(u32, @intCast(i)));
    }
}

pub fn cpuCount() u32 {
    return cpu_count;
}

pub fn thisCpu() *PerCpu {
    if (builtin.target.cpu.arch == .x86_64) {
        const gs_base = x86_64.rdmsr(0xC0000101);
        return @as(*PerCpu, @ptrFromInt(gs_base));
    }
    return &cpu_table[0];
}

pub fn sendIpi(cpu_id: u32, vector: u8) void {
    if (cpu_id >= cpu_count) return;
    const icr = IcrLow{
        .vector = vector,
        .delivery_mode = 0, // fixed
    };
    lapicSendIcr(icr, cpu_table[cpu_id].apic_id);
}

pub fn sendBroadcastIpi(vector: u8) void {
    const icr = IcrLow{
        .vector = vector,
        .delivery_mode = 0,
        .dest_shorthand = 3, // all except self
    };
    lapicSendIcr(icr, 0);
}

pub fn waitForAp(cpu_id: u32) bool {
    if (cpu_id >= cpu_count) return false;
    for (0..100000) |_| {
        if (cpu_table[cpu_id].state == .running) return true;
        asm volatile ("pause");
    }
    return false;
}

test "smp trampoline generation" {
    if (builtin.target.cpu.arch != .x86_64) return error.SkipZigTest;
    const code = buildTrampoline();
    try std.testing.expect(code.len <= TRAMPOLINE_SIZE);
    try std.testing.expect(code.len > 80);
}

test "smp per-cpu size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(PerCpu));
}

test "smp icr packed size" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(IcrLow));
}
