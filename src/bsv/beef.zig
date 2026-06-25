const std = @import("std");
const primitives = @import("primitives.zig");
const hash = @import("hash.zig");

pub const BeefError = error{
    InvalidFormat,
    InvalidTxCount,
    TxTooLarge,
    BufferFull,
};

pub const BeefTx = struct {
    txid: [32]u8,
    raw: []const u8,
};

pub const Beef = struct {
    txs: []const BeefTx,

    pub fn encode(txs: []const BeefTx, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        var w = buf.writer();
        try primitives.writeVarIntFull(w, txs.len);
        for (txs) |tx| {
            try primitives.writeVarIntFull(w, tx.raw.len);
            try w.writeAll(tx.raw);
        }
        return buf.toOwnedSlice();
    }

    pub fn decode(data: []const u8, allocator: std.mem.Allocator) !Beef {
        var offset: usize = 0;
        const count = primitives.decodeVarInt(data[offset..]);
        offset += count.consumed;

        if (count.value == 0) return error.InvalidTxCount;
        var txs = try allocator.alloc(BeefTx, count.value);

        for (0..count.value) |i| {
            if (offset >= data.len) return error.InvalidFormat;
            const tx_len = primitives.decodeVarInt(data[offset..]);
            offset += tx_len.consumed;
            if (offset + tx_len.value > data.len) return error.InvalidFormat;
            const raw = try allocator.dupe(u8, data[offset .. offset + tx_len.value]);
            offset += tx_len.value;
            const txid = hash.doubleSha256(raw);
            txs[i] = .{ .txid = txid, .raw = raw };
        }
        return .{ .txs = txs };
    }

    pub fn deinit(self: *Beef, allocator: std.mem.Allocator) void {
        for (self.txs) |tx| allocator.free(tx.raw);
        allocator.free(self.txs);
    }

    pub fn topTx(self: *const Beef) ?BeefTx {
        if (self.txs.len == 0) return null;
        return self.txs[0];
    }

    pub fn findParent(self: *const Beef, txid: [32]u8) ?BeefTx {
        for (self.txs[1..]) |tx| {
            if (std.mem.eql(u8, &tx.txid, &txid)) return tx;
        }
        return null;
    }
};

pub fn buildBeef(tx_raw: []const u8, parents: []const []const u8, allocator: std.mem.Allocator) ![]u8 {
    var txs = try allocator.alloc(BeefTx, 1 + parents.len);
    defer allocator.free(txs);

    txs[0] = .{ .txid = hash.doubleSha256(tx_raw), .raw = tx_raw };
    for (parents, 1..) |parent, i| {
        txs[i] = .{ .txid = hash.doubleSha256(parent), .raw = parent };
    }
    return try Beef.encode(txs, allocator);
}

test "beef encode decode roundtrip" {
    const allocator = std.testing.allocator;
    const tx1 = [_]u8{0x01} ** 100;
    const tx2 = [_]u8{0x02} ** 200;

    var txs: [2]BeefTx = .{
        .{ .txid = hash.doubleSha256(&tx1), .raw = &tx1 },
        .{ .txid = hash.doubleSha256(&tx2), .raw = &tx2 },
    };
    const encoded = try Beef.encode(&txs, allocator);
    defer allocator.free(encoded);

    var decoded = try Beef.decode(encoded, allocator);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), decoded.txs.len);
    try std.testing.expect(std.mem.eql(u8, &txs[0].txid, &decoded.txs[0].txid));
    try std.testing.expect(std.mem.eql(u8, &txs[1].txid, &decoded.txs[1].txid));
}

test "beef top tx" {
    const allocator = std.testing.allocator;
    const tx1 = [_]u8{0xAA} ** 50;
    const tx2 = [_]u8{0xBB} ** 75;

    var txs: [2]BeefTx = .{
        .{ .txid = hash.doubleSha256(&tx1), .raw = &tx1 },
        .{ .txid = hash.doubleSha256(&tx2), .raw = &tx2 },
    };
    const encoded = try Beef.encode(&txs, allocator);
    defer allocator.free(encoded);

    var decoded = try Beef.decode(encoded, allocator);
    defer decoded.deinit(allocator);

    const top = decoded.topTx().?;
    try std.testing.expect(std.mem.eql(u8, &txs[0].txid, &top.txid));
}

test "beef single tx" {
    const allocator = std.testing.allocator;
    const tx = [_]u8{0xCC} ** 64;

    var txs: [1]BeefTx = .{
        .{ .txid = hash.doubleSha256(&tx), .raw = &tx },
    };
    const encoded = try Beef.encode(&txs, allocator);
    defer allocator.free(encoded);

    var decoded = try Beef.decode(encoded, allocator);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.txs.len);
    try std.testing.expect(std.mem.eql(u8, &txs[0].txid, &decoded.txs[0].txid));
}

test "build beef" {
    const allocator = std.testing.allocator;
    const tx = [_]u8{0xDD} ** 80;
    const parent1 = [_]u8{0xEE} ** 120;
    const parent2 = [_]u8{0xFF} ** 160;

    const beef = try buildBeef(&tx, &.{ &parent1, &parent2 }, allocator);
    defer allocator.free(beef);

    var decoded = try Beef.decode(beef, allocator);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), decoded.txs.len);
}
