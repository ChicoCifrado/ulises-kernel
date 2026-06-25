const std = @import("std");
const builtin = @import("builtin");

const COM1 = 0x3F8;
const LOG_TAG = "LOG";

pub fn init() void {
    if (comptime !isTarget()) return;
    const x86 = cpu();
    x86.outb(COM1 + 1, 0x00);
    x86.outb(COM1 + 3, 0x80);
    x86.outb(COM1 + 0, 0x01);
    x86.outb(COM1 + 1, 0x00);
    x86.outb(COM1 + 3, 0x03);
    x86.outb(COM1 + 2, 0xC7);
    x86.outb(COM1 + 4, 0x0B);
}

fn isTarget() bool {
    return builtin.target.os.tag == .freestanding and
        builtin.target.cpu.arch == .x86_64 and
        !builtin.is_test;
}

fn cpu() type {
    return @import("../arch/x86_64.zig");
}

fn serialPutChar(ch: u8) void {
    const x86 = cpu();
    while ((x86.inb(COM1 + 5) & 0x20) == 0) {}
    x86.outb(COM1, ch);
}

pub fn write(data: []const u8) void {
    if (comptime !isTarget()) return;
    for (data) |ch| {
        if (ch == '\n') serialPutChar('\r');
        serialPutChar(ch);
    }
}

pub fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    if (comptime !isTarget()) return;
    const alloc = if (builtin.is_test) std.testing.allocator else @import("../mem/global.zig").get();
    const buf = std.fmt.allocPrint(alloc, fmt, args) catch return;
    defer alloc.free(buf);
    write(buf);
}

pub fn errorLog(msg: []const u8) void {
    if (comptime !isTarget()) return;
    write("[ERROR] ");
    write(msg);
    write("\n");
}

pub fn panicLog(msg: []const u8) void {
    if (comptime !isTarget()) return;
    write("[PANIC] ");
    write(msg);
    write("\n");
}
