const std = @import("std");
const builtin = @import("builtin");

const LOG_TAG = "LOG";

const serialInit_impl = if (builtin.target.cpu.arch == .x86_64) struct {
    fn f() void {
        const x86 = @import("../arch/x86_64.zig");
        const COM1 = @as(u16, 0x3F8);
        x86.outb(COM1 + 1, 0x00);
        x86.outb(COM1 + 3, 0x80);
        x86.outb(COM1 + 0, 0x01);
        x86.outb(COM1 + 1, 0x00);
        x86.outb(COM1 + 3, 0x03);
        x86.outb(COM1 + 2, 0xC7);
        x86.outb(COM1 + 4, 0x0B);
    }
}.f else if (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .arm) struct {
    fn f() void {
        const arch = @import("../arch/aarch64.zig");
        arch.serialInit();
    }
}.f else struct {
    fn f() void {}
}.f;

const serialPutChar_impl = if (builtin.target.cpu.arch == .x86_64) struct {
    fn f(ch: u8) void {
        const x86 = @import("../arch/x86_64.zig");
        const COM1 = @as(u16, 0x3F8);
        while ((x86.inb(COM1 + 5) & 0x20) == 0) {}
        x86.outb(COM1, ch);
    }
}.f else if (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .arm) struct {
    fn f(ch: u8) void {
        const arch = @import("../arch/aarch64.zig");
        arch.serialPutChar(ch);
    }
}.f else struct {
    fn f(_: u8) void {}
}.f;

fn isTarget() bool {
    return builtin.target.os.tag == .freestanding and !builtin.is_test;
}

pub fn init() void {
    if (comptime !isTarget()) return;
    serialInit_impl();
}

pub fn write(data: []const u8) void {
    if (comptime !isTarget()) return;
    for (data) |ch| {
        if (ch == '\n') serialPutChar_impl('\r');
        serialPutChar_impl(ch);
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
