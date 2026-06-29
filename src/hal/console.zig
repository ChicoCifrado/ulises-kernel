const std = @import("std");
const builtin = @import("builtin");
const global_alloc = @import("../mem/global.zig");
const usb = @import("usb.zig");

const VGA_WIDTH = 80;
const VGA_HEIGHT = 25;
const VGA_ADDR = @as([*]volatile u16, @ptrFromInt(0xB8000));

pub const ConsoleColor = enum(u4) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

const serialPutChar_impl = if (builtin.target.cpu.arch == .x86_64) struct {
    fn f(c: u8) void {
        const x86 = @import("../arch/x86_64.zig");
        while ((x86.inb(0x3F8 + 5) & 0x20) == 0) {}
        x86.outb(0x3F8, c);
    }
}.f else if (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .arm) struct {
    fn f(c: u8) void {
        const arch = @import("../arch/aarch64.zig");
        arch.serialPutChar(c);
    }
}.f else struct {
    fn f(_: u8) void {}
}.f;

const serialCanRead_impl = if (builtin.target.cpu.arch == .x86_64) struct {
    fn f() bool {
        return @import("../arch/x86_64.zig").serialCanRead();
    }
}.f else if (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .arm) struct {
    fn f() bool {
        return @import("../arch/aarch64.zig").serialCanRead();
    }
}.f else struct {
    fn f() bool { return false; }
}.f;

const serialReadChar_impl = if (builtin.target.cpu.arch == .x86_64) struct {
    fn f() u8 {
        return @import("../arch/x86_64.zig").serialReadChar();
    }
}.f else if (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .arm) struct {
    fn f() u8 {
        return @import("../arch/aarch64.zig").serialReadChar();
    }
}.f else struct {
    fn f() u8 { return 0; }
}.f;

const displayWrite_impl = if (builtin.target.cpu.arch == .x86_64) struct {
    fn f(offset: usize, val: u16) void {
        if (builtin.is_test) return;
        VGA_ADDR[offset] = val;
    }
}.f else struct {
    fn f(_: usize, _: u16) void {}
}.f;

const scrollConsole_impl = if (builtin.target.cpu.arch == .x86_64) struct {
    fn f() void {
        if (builtin.is_test) return;
        var y: usize = 1;
        while (y < VGA_HEIGHT) {
            var x: usize = 0;
            while (x < VGA_WIDTH) {
                VGA_ADDR[(y - 1) * VGA_WIDTH + x] = VGA_ADDR[y * VGA_WIDTH + x];
                x += 1;
            }
            y += 1;
        }
        var x: usize = 0;
        while (x < VGA_WIDTH) {
            VGA_ADDR[(VGA_HEIGHT - 1) * VGA_WIDTH + x] = 0x0700 | ' ';
            x += 1;
        }
    }
}.f else struct {
    fn f() void {}
}.f;

pub const Console = struct {
    row: u8 = 0,
    col: u8 = 0,
    fg: ConsoleColor = .light_gray,
    bg: ConsoleColor = .black,

    pub fn init() Console {
        return .{};
    }

    pub fn clear(self: *Console) void {
        const blank: u16 = makeAttr(.light_gray, .black) | ' ';
        var i: usize = 0;
        while (i < VGA_WIDTH * VGA_HEIGHT) {
            displayWrite_impl(@as(u16, @intCast(i)), blank);
            i += 1;
        }
        self.row = 0;
        self.col = 0;
    }

    pub fn putChar(self: *Console, ch: u8) void {
        if (builtin.target.os.tag == .freestanding and !builtin.is_test) {
            if (ch == '\n') serialPutChar_impl('\r');
            serialPutChar_impl(ch);
        }
        switch (ch) {
            '\n' => self.newline(),
            '\r' => self.col = 0,
            '\t' => {
                self.col = (self.col + 4) & ~@as(u8, 3);
                if (self.col >= VGA_WIDTH) self.newline();
            },
            0x08 => {
                if (self.col > 0) {
                    self.col -= 1;
                    displayWrite_impl(@as(usize, self.row) * VGA_WIDTH + @as(usize, self.col), makeAttr(self.fg, self.bg) | ' ');
                }
            },
            0x00...0x07, 0x0B...0x0C, 0x0E...0x1F => {},
            else => {
                displayWrite_impl(@as(usize, self.row) * VGA_WIDTH + @as(usize, self.col), makeAttr(self.fg, self.bg) | ch);
                self.col += 1;
                if (self.col >= VGA_WIDTH) self.newline();
            },
        }
    }

    pub fn write(self: *Console, data: []const u8) void {
        for (data) |ch| self.putChar(ch);
    }

    pub fn writeFmt(self: *Console, comptime fmt: []const u8, args: anytype) void {
        const alloc = global_alloc.get();
        const buf = std.fmt.allocPrint(alloc, fmt, args) catch return;
        defer alloc.free(buf);
        self.write(buf);
    }

    pub fn setFg(self: *Console, color: ConsoleColor) void {
        self.fg = color;
    }

    pub fn setBg(self: *Console, color: ConsoleColor) void {
        self.bg = color;
    }

    fn newline(self: *Console) void {
        self.col = 0;
        if (self.row + 1 < VGA_HEIGHT) {
            self.row += 1;
        } else {
            scrollConsole_impl();
        }
    }

    pub fn readLine(self: *Console, prompt: []const u8, buf: []u8) ![]u8 {
        self.write(prompt);
        var idx: usize = 0;
        while (true) {
            if (usb.isInitialized()) {
                const sc = usb.readScanCode();
                if (sc != 0) {
                    if (sc == 0x28) {
                        buf[idx] = 0;
                        self.write("\n");
                        return buf[0..idx];
                    }
                    if (sc == 0x2A) {
                        if (idx > 0) {
                            idx -= 1;
                            self.col -= 1;
                            displayWrite_impl(@as(usize, self.row) * VGA_WIDTH + @as(usize, self.col), makeAttr(self.fg, self.bg) | ' ');
                        }
                        continue;
                    }
                    const ch = usb.scanToAscii(sc);
                    if (ch != 0 and idx < buf.len) {
                        buf[idx] = ch;
                        self.putChar(ch);
                        idx += 1;
                    }
                    continue;
                }
            }
            if (serialCanRead_impl()) {
                const ch = serialReadChar_impl();
                if (ch == '\r' or ch == '\n') {
                    buf[idx] = 0;
                    self.write("\n");
                    return buf[0..idx];
                }
                if (ch == 0x7F or ch == 0x08) {
                    if (idx > 0) {
                        idx -= 1;
                        self.col -= 1;
                        displayWrite_impl(@as(usize, self.row) * VGA_WIDTH + @as(usize, self.col), makeAttr(self.fg, self.bg) | ' ');
                    }
                    continue;
                }
                if (ch >= 0x20 and ch < 0x7F and idx < buf.len) {
                    buf[idx] = ch;
                    self.putChar(ch);
                    idx += 1;
                }
            }
        }
    }
};

fn makeAttr(fg: ConsoleColor, bg: ConsoleColor) u16 {
    return (@as(u16, @intFromEnum(bg)) << 12) | (@as(u16, @intFromEnum(fg)) << 8);
}

var global_console: Console = .{};

pub fn getConsole() *Console {
    return &global_console;
}

test "console init" {
    const con = Console.init();
    try std.testing.expectEqual(@as(u8, 0), con.row);
    try std.testing.expectEqual(@as(u8, 0), con.col);
}

test "console write" {
    var con = Console.init();
    con.write("hi");
    try std.testing.expectEqual(@as(u8, 2), con.col);
}

test "console newline advances row" {
    var con = Console.init();
    con.putChar('\n');
    try std.testing.expectEqual(@as(u8, 1), con.row);
}

test "console color" {
    var con = Console.init();
    con.setFg(.red);
    con.setBg(.blue);
    try std.testing.expectEqual(@intFromEnum(ConsoleColor.red), @intFromEnum(con.fg));
}
