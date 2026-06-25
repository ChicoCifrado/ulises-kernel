const std = @import("std");

pub const ScriptBuilder = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ScriptBuilder {
        return .{ .buffer = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *ScriptBuilder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn append(self: *ScriptBuilder, opcode: u8) !void {
        try self.buffer.append(self.allocator, opcode);
    }

    pub fn appendPushData(self: *ScriptBuilder, data: []const u8) !void {
        if (data.len == 0) {
            try self.buffer.append(self.allocator, 0x00);
            return;
        }
        if (data.len <= 75) {
            try self.buffer.append(self.allocator, @truncate(data.len));
        } else if (data.len <= 0xff) {
            try self.buffer.append(self.allocator, 0x4c);
            try self.buffer.append(self.allocator, @truncate(data.len));
        } else if (data.len <= 0xffff) {
            try self.buffer.append(self.allocator, 0x4d);
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @truncate(data.len), .little);
            try self.buffer.appendSlice(self.allocator, &len_buf);
        } else {
            try self.buffer.append(self.allocator, 0x4e);
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @truncate(data.len), .little);
            try self.buffer.appendSlice(self.allocator, &len_buf);
        }
        try self.buffer.appendSlice(self.allocator, data);
    }

    pub fn appendNum(self: *ScriptBuilder, num: i64) !void {
        if (num == 0) {
            try self.append(0x00);
        } else if (num >= 1 and num <= 16) {
            try self.append(@as(u8, @intCast(0x50 + num)));
        } else if (num == -1) {
            try self.append(0x4f);
        } else {
            const encoded = try ScriptNum.encode(num, self.allocator);
            defer self.allocator.free(encoded);
            try self.appendPushData(encoded);
        }
    }

    pub fn appendOpcode(self: *ScriptBuilder, opcode: u8) !void {
        try self.buffer.append(self.allocator, opcode);
    }

    pub fn buildP2PKH(self: *ScriptBuilder, pubkey_hash: [20]u8) !void {
        try self.appendOpcode(0x76); // OP_DUP
        try self.appendOpcode(0xa9); // OP_HASH160
        try self.appendPushData(&pubkey_hash);
        try self.appendOpcode(0x88); // OP_EQUALVERIFY
        try self.appendOpcode(0xac); // OP_CHECKSIG
    }

    pub fn buildOpReturn(self: *ScriptBuilder, data: []const u8) !void {
        try self.appendOpcode(0x6a); // OP_RETURN
        if (data.len > 0) {
            try self.appendPushData(data);
        }
    }

    pub fn buildP2PK(self: *ScriptBuilder, pubkey: []const u8) !void {
        try self.appendPushData(pubkey);
        try self.appendOpcode(0xac); // OP_CHECKSIG
    }

    pub fn buildMultiSig(self: *ScriptBuilder, required: u8, pubkeys: []const []const u8) !void {
        try self.appendNum(required);
        for (pubkeys) |pk| try self.appendPushData(pk);
        try self.appendNum(@intCast(pubkeys.len));
        try self.appendOpcode(0xae); // OP_CHECKMULTISIG
    }

    pub fn buildUnlockingP2PKH(self: *ScriptBuilder, sig: []const u8, pubkey: []const u8) !void {
        try self.appendPushData(sig);
        try self.appendPushData(pubkey);
    }

    pub fn finish(self: *ScriptBuilder) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    pub fn view(self: *const ScriptBuilder) []const u8 {
        return self.buffer.items;
    }

    pub fn reset(self: *ScriptBuilder) void {
        self.buffer.clearRetainingCapacity();
    }
};

const ScriptNum = struct {
    pub fn encode(value: i64, allocator: std.mem.Allocator) ![]u8 {
        if (value == 0) return try allocator.dupe(u8, &.{0});
        const neg = value < 0;
        var abs_val: u64 = if (neg) @as(u64, @intCast(-value)) else @as(u64, @intCast(value));
        var bytes = std.ArrayList(u8).init(allocator);
        defer bytes.deinit();
        while (abs_val > 0) {
            try bytes.append(@truncate(abs_val));
            abs_val >>= 8;
        }
        if ((bytes.items[bytes.items.len - 1] & 0x80) != 0) {
            try bytes.append(if (neg) @as(u8, 0x80) else 0);
        } else if (neg) {
            bytes.items[bytes.items.len - 1] |= 0x80;
        }
        return bytes.toOwnedSlice();
    }
};

test "builder p2pkh" {
    const allocator = std.testing.allocator;
    var b = ScriptBuilder.init(allocator);
    defer b.deinit();

    const hash = [_]u8{0xAA} ** 20;
    try b.buildP2PKH(hash);
    const script = try b.finish();
    defer allocator.free(script);

    try std.testing.expectEqual(@as(usize, 25), script.len);
    try std.testing.expectEqual(@as(u8, 0x76), script[0]); // OP_DUP
    try std.testing.expectEqual(@as(u8, 0xa9), script[1]); // OP_HASH160
    try std.testing.expectEqual(@as(u8, 20), script[2]);   // push 20 bytes
    try std.testing.expectEqual(@as(u8, 0x88), script[23]); // OP_EQUALVERIFY
    try std.testing.expectEqual(@as(u8, 0xac), script[24]); // OP_CHECKSIG
}

test "builder op_return" {
    const allocator = std.testing.allocator;
    var b = ScriptBuilder.init(allocator);
    defer b.deinit();

    try b.buildOpReturn("Hello BSV");
    const script = try b.finish();
    defer allocator.free(script);

    try std.testing.expectEqual(@as(u8, 0x6a), script[0]); // OP_RETURN
    try std.testing.expect(script.len > 1);
}

test "builder push data" {
    const allocator = std.testing.allocator;
    var b = ScriptBuilder.init(allocator);
    defer b.deinit();

    try b.appendPushData(&[_]u8{0x01, 0x02, 0x03});
    const script = try b.finish();
    defer allocator.free(script);

    try std.testing.expectEqual(@as(usize, 4), script.len);
    try std.testing.expectEqual(@as(u8, 3), script[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01, 0x02, 0x03}, script[1..]);
}

test "builder num" {
    const allocator = std.testing.allocator;
    var b = ScriptBuilder.init(allocator);
    defer b.deinit();

    try b.appendNum(0);
    try b.appendNum(1);
    try b.appendNum(16);
    try b.appendNum(-1);
    try b.appendNum(100);

    const script = try b.finish();
    defer allocator.free(script);

    try std.testing.expectEqual(@as(u8, 0x00), script[0]);
    try std.testing.expectEqual(@as(u8, 0x51), script[1]);
    try std.testing.expectEqual(@as(u8, 0x60), script[2]);
    try std.testing.expectEqual(@as(u8, 0x4f), script[3]);
}
