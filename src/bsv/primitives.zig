const std = @import("std");
const Sha256 = @import("hash.zig").Sha256;

pub const Network = enum { mainnet, testnet, regtest };

pub const OutPoint = struct {
    txid: [32]u8,
    vout: u32,

    pub fn eql(self: OutPoint, other: OutPoint) bool {
        return std.mem.eql(u8, &self.txid, &other.txid) and self.vout == other.vout;
    }

    pub fn hash(self: OutPoint) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (&self.txid) |b| {
            h = (h ^ b) *% 0x100000001b3;
        }
        h ^= self.vout;
        return h;
    }

    pub fn serialize(self: OutPoint) [36]u8 {
        var buf: [36]u8 = undefined;
        @memcpy(buf[0..32], &self.txid);
        std.mem.writeInt(u32, buf[32..36], self.vout, .little);
        return buf;
    }

    pub fn deserialize(buf: [36]u8) OutPoint {
        return .{
            .txid = buf[0..32].*,
            .vout = std.mem.readInt(u32, buf[32..36], .little),
        };
    }
};

pub const TxIn = struct {
    prev_out: OutPoint,
    script: []const u8,
    sequence: u32 = 0xffffffff,
};

pub const TxOut = struct {
    value: u64,
    script: []const u8,
};

pub const Tx = struct {
    version: i32,
    inputs: []TxIn,
    outputs: []TxOut,
    locktime: u32,
    txid: [32]u8,

    pub fn computeTxid(self: *Tx) void {
        var state = Sha256.init(.{});

        var buf: [8]u8 = undefined;

        std.mem.writeInt(i32, &buf, self.version, .little);
        state.update(buf[0..4]);

        state.update(&[_]u8{@intCast(self.inputs.len)});

        for (self.inputs) |in_| {
            state.update(&in_.prev_out.txid);
            std.mem.writeInt(u32, &buf, in_.prev_out.vout, .little);
            state.update(buf[0..4]);
            writeVarInt(state.writer(), in_.script.len);
            state.update(in_.script);
            std.mem.writeInt(u32, &buf, in_.sequence, .little);
            state.update(buf[0..4]);
        }

        state.update(&[_]u8{@intCast(self.outputs.len)});

        for (self.outputs) |out| {
            std.mem.writeInt(u64, &buf, out.value, .little);
            state.update(buf[0..8]);
            writeVarInt(state.writer(), out.script.len);
            state.update(out.script);
        }

        std.mem.writeInt(u32, &buf, self.locktime, .little);
        state.update(buf[0..4]);

        const hash1 = state.final();

        var state2 = Sha256.init(.{});
        state2.update(&hash1);
        self.txid = state2.final();
    }
};

pub const BlockHeader = struct {
    version: i32,
    prev_hash: [32]u8,
    merkle_root: [32]u8,
    timestamp: u32,
    bits: u32,
    nonce: u32,
    height: u32,
    hash: [32]u8,

    pub fn computeHash(self: *BlockHeader) void {
        var state = Sha256.init(.{});
        var buf: [8]u8 = undefined;

        std.mem.writeInt(i32, &buf, self.version, .little);
        state.update(buf[0..4]);
        state.update(&self.prev_hash);
        state.update(&self.merkle_root);
        std.mem.writeInt(u32, &buf, self.timestamp, .little);
        state.update(buf[0..4]);
        std.mem.writeInt(u32, &buf, self.bits, .little);
        state.update(buf[0..4]);
        std.mem.writeInt(u32, &buf, self.nonce, .little);
        state.update(buf[0..4]);

        const hash1 = state.final();

        var state2 = Sha256.init(.{});
        state2.update(&hash1);
        self.hash = state2.final();
    }
};

pub const Block = struct {
    header: BlockHeader,
    txs: []Tx,
};

fn writeVarInt(writer: anytype, value: usize) void {
    var buf: [9]u8 = undefined;
    const n = encodeVarInt(&buf, value);
    writer.writeAll(buf[0..n]) catch {};
}

pub fn writeVarIntFull(writer: anytype, value: usize) !void {
    var buf: [9]u8 = undefined;
    const n = encodeVarInt(&buf, value);
    try writer.writeAll(buf[0..n]);
}

pub fn encodeVarInt(buf: []u8, value: usize) usize {
    if (value < 0xfd) {
        buf[0] = @truncate(value);
        return 1;
    } else if (value <= 0xffff) {
        buf[0] = 0xfd;
        std.mem.writeInt(u16, buf[1..3], @truncate(value), .little);
        return 3;
    } else if (value <= 0xffffffff) {
        buf[0] = 0xfe;
        std.mem.writeInt(u32, buf[1..5], @truncate(value), .little);
        return 5;
    } else {
        buf[0] = 0xff;
        std.mem.writeInt(u64, buf[1..9], @truncate(value), .little);
        return 9;
    }
}

pub fn decodeVarInt(data: []const u8) struct { value: usize, consumed: usize } {
    if (data.len == 0) return .{ .value = 0, .consumed = 0 };
    const prefix = data[0];
    if (prefix < 0xfd) return .{ .value = prefix, .consumed = 1 };
    if (prefix == 0xfd) return .{ .value = std.mem.readInt(u16, data[1..3], .little), .consumed = 3 };
    if (prefix == 0xfe) return .{ .value = std.mem.readInt(u32, data[1..5], .little), .consumed = 5 };
    return .{ .value = std.mem.readInt(u64, data[1..9], .little), .consumed = 9 };
}

test "outpoint serialize roundtrip" {
    const op = OutPoint{ .txid = [_]u8{0xAA} ** 32, .vout = 42 };
    const ser = op.serialize();
    const de = OutPoint.deserialize(ser);
    try std.testing.expect(op.eql(de));
}

test "varint encoding" {
    var buf: [9]u8 = undefined;
    try std.testing.expectEqual(1, encodeVarInt(&buf, 0));
    try std.testing.expectEqual(1, encodeVarInt(&buf, 0xfc));
    try std.testing.expectEqual(3, encodeVarInt(&buf, 0xfd));
    try std.testing.expectEqual(3, encodeVarInt(&buf, 0xffff));
    try std.testing.expectEqual(5, encodeVarInt(&buf, 0x10000));
    try std.testing.expectEqual(5, encodeVarInt(&buf, 0xffffffff));
    try std.testing.expectEqual(9, encodeVarInt(&buf, 0x100000000));
}

test "varint decode" {
    var buf: [9]u8 = undefined;
    _ = encodeVarInt(&buf, 0xfc);
    try std.testing.expectEqual(@as(usize, 0xfc), decodeVarInt(buf[0..1]).value);
    _ = encodeVarInt(&buf, 0x1000);
    try std.testing.expectEqual(@as(usize, 0x1000), decodeVarInt(buf[0..3]).value);
}
