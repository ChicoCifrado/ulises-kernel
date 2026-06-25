const std = @import("std");
const builtin = @import("builtin");
const idt_mod = @import("idt.zig");
const x86_64 = @import("../x86_64.zig");

const names = [32][]const u8{
    "Divide By Zero (#DE)",
    "Debug (#DB)",
    "Non-Maskable Interrupt (#NMI)",
    "Breakpoint (#BP)",
    "Overflow (#OF)",
    "Bound Range Exceeded (#BR)",
    "Invalid Opcode (#UD)",
    "Device Not Available (#NM)",
    "Double Fault (#DF)",
    "Coprocessor Segment Overrun",
    "Invalid TSS (#TS)",
    "Segment Not Present (#NP)",
    "Stack-Segment Fault (#SS)",
    "General Protection Fault (#GP)",
    "Page Fault (#PF)",
    "Reserved (#15)",
    "x87 Floating-Point (#MF)",
    "Alignment Check (#AC)",
    "Machine Check (#MC)",
    "SIMD Floating-Point (#XM)",
    "Virtualization (#VE)",
    "Control Protection (#CP)",
    "Reserved (#22)",
    "Reserved (#23)",
    "Reserved (#24)",
    "Reserved (#25)",
    "Reserved (#26)",
    "Reserved (#27)",
    "Hypervisor Injection (#HV)",
    "VMM Communication (#VC)",
    "Security Exception (#SX)",
    "Reserved (#31)",
};

const pf_desc = [_][]const u8{ "P  ", "W  ", "U  ", "RSV", "ID " };

fn logRaw(msg: []const u8) void {
    if (comptime builtin.target.os.tag != .freestanding or builtin.target.cpu.arch != .x86_64) return;
    for (msg) |ch| {
        if (ch == '\n') {
            while ((x86_64.inb(0x3F8 + 5) & 0x20) == 0) {}
            x86_64.outb(0x3F8, '\r');
        }
        while ((x86_64.inb(0x3F8 + 5) & 0x20) == 0) {}
        x86_64.outb(0x3F8, ch);
    }
    while ((x86_64.inb(0x3F8 + 5) & 0x20) == 0) {}
    x86_64.outb(0x3F8, '\r');
    while ((x86_64.inb(0x3F8 + 5) & 0x20) == 0) {}
    x86_64.outb(0x3F8, '\n');
}

fn hex64(val: u64, buf: *[18]u8) []const u8 {
    const hex = "0123456789ABCDEF";
    buf[0] = '0';
    buf[1] = 'x';
    for (0..16) |i| {
        buf[2 + i] = hex[@as(u8, @truncate((val >> @as(u6, @intCast((15 - i) * 4))) & 0xF))];
    }
    return buf[0..18];
}

fn hex32(val: u32, buf: *[10]u8) []const u8 {
    const hex = "0123456789ABCDEF";
    buf[0] = '0';
    buf[1] = 'x';
    for (0..8) |i| {
        buf[2 + i] = hex[@as(u8, @truncate((val >> @as(u5, @intCast((7 - i) * 4))) & 0xF))];
    }
    return buf[0..10];
}

fn dec64(val: u64, buf: *[21]u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [20]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) {
        tmp[i] = @as(u8, @intCast(n % 10)) + '0';
        n /= 10;
        i += 1;
    }
    for (0..i) |j| buf[j] = tmp[i - 1 - j];
    return buf[0..i];
}

fn readCr2() u64 {
    var v: u64 = undefined;
    asm volatile ("mov %%cr2, %[v]" : [v] "=r" (v));
    return v;
}

fn hasErrCode(vec: u8) bool {
    return switch (vec) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

fn dumpReg(label: []const u8, val: u64) void {
    var buf: [18]u8 = undefined;
    const h = hex64(val, &buf);
    var msg: [64]u8 = undefined;
    var i: usize = 0;
    for (label) |ch| { msg[i] = ch; i += 1; }
    msg[i] = ' '; i += 1;
    msg[i] = ' '; i += 1;
    for (h) |ch| { msg[i] = ch; i += 1; }
    logRaw(msg[0..i]);
}

pub fn handler(frame: *const idt_mod.InterruptFrame) u64 {
    x86_64.cli();
    logRaw("===== KERNEL PANIC =====");

    const vec = frame.vector;
    if (vec < 32) {
        var dbuf: [21]u8 = undefined;
        const d = dec64(vec, &dbuf);
        var msg: [128]u8 = undefined;
        var i: usize = 0;
        for (names[@as(usize, @intCast(vec))]) |ch| { msg[i] = ch; i += 1; }
        msg[i] = ' '; i += 1;
        for (d) |ch| { msg[i] = ch; i += 1; }
        logRaw(msg[0..i]);
    }

    if (vec == 14) {
        const cr2 = readCr2();
        const err = frame.error_code;
        var cr2buf: [18]u8 = undefined;
        const cr2h = hex64(cr2, &cr2buf);
        logRaw("Page-Fault Information:");
        var m: [64]u8 = undefined;
        var j: usize = 0;
        for ("  CR2: ") |ch| { m[j] = ch; j += 1; }
        for (cr2h) |ch| { m[j] = ch; j += 1; }
        logRaw(m[0..j]);
        logRaw("  Error code flags:");
        for (0..5) |k| {
            if ((err >> @as(u6, @intCast(k))) & 1 != 0) {
                var fl: [32]u8 = undefined;
                var fli: usize = 0;
                fl[fli] = ' '; fli += 1;
                fl[fli] = ' '; fli += 1;
                for (pf_desc[k]) |ch| { fl[fli] = ch; fli += 1; }
                logRaw(fl[0..fli]);
            }
        }
    } else if (hasErrCode(@as(u8, @truncate(vec)))) {
        var ebuf: [18]u8 = undefined;
        const eh = hex64(frame.error_code, &ebuf);
        var em: [32]u8 = undefined;
        var ei: usize = 0;
        for ("  Error Code: ") |ch| { em[ei] = ch; ei += 1; }
        for (eh) |ch| { em[ei] = ch; ei += 1; }
        logRaw(em[0..ei]);
    }

    logRaw("--- Registers ---");
    dumpReg("RDI", frame.rdi);
    dumpReg("RSI", frame.rsi);
    dumpReg("RDX", frame.rdx);
    dumpReg("RCX", frame.rcx);
    dumpReg("R8 ", frame.r8);
    dumpReg("R9 ", frame.r9);
    dumpReg("R10", frame.r10);
    dumpReg("R11", frame.r11);
    dumpReg("RBX", frame.rbx);
    dumpReg("RBP", frame.rbp);
    dumpReg("R12", frame.r12);
    dumpReg("R13", frame.r13);
    dumpReg("R14", frame.r14);
    dumpReg("R15", frame.r15);
    logRaw("");
    dumpReg("RIP", frame.rip);
    dumpReg("CS ", frame.cs);
    dumpReg("RFL", frame.rflags);
    dumpReg("RSP", frame.rsp);
    dumpReg("SS ", frame.ss);
    logRaw("==========================");

    logRaw("System halted.");
    while (true) {
        asm volatile ("cli; hlt");
    }
}
