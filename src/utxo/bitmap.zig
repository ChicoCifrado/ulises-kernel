const std = @import("std");
const builtin = @import("builtin");

pub const Bitmap = struct {
    words: []u64,
    count: usize,

    pub fn init(words: []u64) Bitmap {
        return .{
            .words = words,
            .count = 0,
        };
    }

    pub fn initZeroed(words: []u64) Bitmap {
        @memset(words, 0);
        return .{
            .words = words,
            .count = 0,
        };
    }

    pub fn capacity(self: *const Bitmap) usize {
        return self.words.len * 64;
    }

    pub fn set(self: *Bitmap, index: usize) void {
        const word_idx = index / 64;
        const bit_idx = @as(u6, @intCast(index % 64));
        self.words[word_idx] |= (@as(u64, 1) << bit_idx);
    }

    pub fn unset(self: *Bitmap, index: usize) void {
        const word_idx = index / 64;
        const bit_idx = @as(u6, @intCast(index % 64));
        self.words[word_idx] &= ~(@as(u64, 1) << bit_idx);
    }

    pub fn isSet(self: *const Bitmap, index: usize) bool {
        const word_idx = index / 64;
        const bit_idx = @as(u6, @intCast(index % 64));
        return (self.words[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }

    pub fn findFree(self: *const Bitmap) ?usize {
        const arch = builtin.target.cpu.arch;
        var base: usize = 0;
        for (self.words) |word| {
            if (word == std.math.maxInt(u64)) {
                base += 64;
                continue;
            }
            const free_bit = switch (arch) {
                .x86_64, .x86 => findFreeX86(word),
                .aarch64, .arm => findFreeArm(word),
                .riscv64 => findFreeRiscv(word),
                else => findFreeGeneric(word),
            };
            if (free_bit) |b| return base + b;
            base += 64;
        }
        return null;
    }

    pub fn findSet(self: *const Bitmap) ?usize {
        var base: usize = 0;
        for (self.words) |word| {
            if (word == 0) {
                base += 64;
                continue;
            }
            const set_bit = findFirstSet(word);
            if (set_bit) |b| return base + b;
            base += 64;
        }
        return null;
    }

    pub fn countFree(self: *const Bitmap) usize {
        var free: usize = 0;
        for (self.words) |word| {
            free += @as(usize, @intCast(@popCount(~word)));
        }
        return free;
    }

    pub fn occupied(self: *const Bitmap) usize {
        return self.capacity() - self.countFree();
    }

    pub fn clear(self: *Bitmap) void {
        @memset(self.words, 0);
        self.count = 0;
    }

    inline fn findFreeX86(word: u64) ?usize {
        const inv = ~word;
        if (inv == 0) return null;
        return @as(usize, @intCast(@ctz(inv)));
    }

    inline fn findFreeArm(word: u64) ?usize {
        const inv = ~word;
        if (inv == 0) return null;
        return @as(usize, @intCast(@clz(inv)));
    }

    inline fn findFreeRiscv(word: u64) ?usize {
        const inv = ~word;
        if (inv == 0) return null;
        return @as(usize, @intCast(@ctz(inv)));
    }

    inline fn findFreeGeneric(word: u64) ?usize {
        const inv = ~word;
        if (inv == 0) return null;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            if ((inv >> @as(u6, @intCast(i))) & 1 == 1) return i;
        }
        return null;
    }

    inline fn findFirstSet(word: u64) ?usize {
        if (word == 0) return null;
        return @as(usize, @intCast(@ctz(word)));
    }
};

test "bitmap set and check" {
    var words: [4]u64 = @splat(0);
    var bm = Bitmap.init(&words);
    try std.testing.expect(!bm.isSet(10));
    bm.set(10);
    try std.testing.expect(bm.isSet(10));
    bm.unset(10);
    try std.testing.expect(!bm.isSet(10));
}

test "bitmap find free" {
    var words: [4]u64 = @splat(0);
    var bm = Bitmap.init(&words);
    const free = bm.findFree();
    try std.testing.expect(free != null);
    try std.testing.expectEqual(0, free.?);
    bm.set(0);
    const free2 = bm.findFree();
    try std.testing.expectEqual(1, free2.?);
}

test "bitmap full word" {
    var words: [4]u64 = .{ std.math.maxInt(u64), 0, std.math.maxInt(u64), 0 };
    var bm = Bitmap.init(words[0..2]);
    const free = bm.findFree();
    try std.testing.expect(free != null);
    try std.testing.expectEqual(64, free.?);
}

test "bitmap count free" {
    var words: [4]u64 = .{ 0b1010, 0, 0b1010, 0 };
    var bm = Bitmap.init(words[0..2]);
    try std.testing.expectEqual(126, bm.countFree());
}
