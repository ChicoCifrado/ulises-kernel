const std = @import("std");

pub const Slot = extern struct {
    txid: [32]u8,
    value: u64,
    vout: u32,
    height: u32,
    flags: u16,
    script_off: u32,
    script_len: u32,

    comptime {
        std.debug.assert(@sizeOf(Slot) == 64);
    }

    pub const Flags = packed struct(u16) {
        spent: bool = false,
        locked: bool = false,
        coinbase: bool = false,
        reserved: u13 = 0,
    };

    pub fn init(txid: [32]u8, vout: u32, value: u64, height: u32, init_flags: Flags) Slot {
        return .{
            .txid = txid,
            .vout = vout,
            .value = value,
            .height = height,
            .flags = @bitCast(init_flags),
            .script_off = 0,
            .script_len = 0,
        };
    }

    pub fn outpoint(self: *const Slot) [36]u8 {
        var buf: [36]u8 = undefined;
        @memcpy(buf[0..32], &self.txid);
        std.mem.writeInt(u32, buf[32..36], self.vout, .little);
        return buf;
    }

    pub fn isSpent(self: *const Slot) bool {
        return @as(Flags, @bitCast(self.flags)).spent;
    }

    pub fn markSpent(self: *Slot) void {
        var f: Flags = @bitCast(self.flags);
        f.spent = true;
        self.flags = @bitCast(f);
    }

    pub fn markUnspent(self: *Slot) void {
        var f: Flags = @bitCast(self.flags);
        f.spent = false;
        self.flags = @bitCast(f);
    }
};

test "slot size is exactly 64 bytes" {
    try std.testing.expectEqual(64, @sizeOf(Slot));
}

test "slot init and access" {
    const txid: [32]u8 = @splat(0xAA);
    var slot = Slot.init(txid, 1, 100000, 800000, .{});
    try std.testing.expectEqual(1, slot.vout);
    try std.testing.expectEqual(100000, slot.value);
    try std.testing.expectEqual(800000, slot.height);
    try std.testing.expect(!slot.isSpent());
}

test "slot mark spent" {
    const txid: [32]u8 = @splat(0xBB);
    var slot = Slot.init(txid, 0, 5000, 700000, .{});
    try std.testing.expect(!slot.isSpent());
    slot.markSpent();
    try std.testing.expect(slot.isSpent());
}

test "slot outpoint serialization" {
    const txid: [32]u8 = @splat(0xCC);
    var slot = Slot.init(txid, 42, 0, 0, .{});
    const op = slot.outpoint();
    try std.testing.expectEqual(36, op.len);
    try std.testing.expectEqualSlices(u8, &txid, op[0..32]);
    try std.testing.expectEqual(42, std.mem.readInt(u32, op[32..36], .little));
}
