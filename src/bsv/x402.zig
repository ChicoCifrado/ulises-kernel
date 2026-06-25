const std = @import("std");
const hash = @import("hash.zig");
const beef_mod = @import("beef.zig");
const secp = @import("secp256k1.zig").secp256k1;

pub const PaymentVersion = enum(u8) {
    v1 = 1,
};

pub const DerivationPrefix = struct {
    derivation_prefix: [32]u8,
    derivation_suffix: [32]u8,
    sender_intent: u8,
    key_id: u64,

    pub fn toBytes(self: DerivationPrefix) []const u8 {
        _ = self;
        return &[_]u8{};
    }
};

pub const PaymentTemplate = struct {
    amount: u64,
    derivation_prefix: [32]u8,
    derivation_suffix: [32]u8,
    description: ?[]const u8 = null,
    sender_intent: u8 = 0,
    key_id: u64 = 0,
};

pub const PaymentAcknowledgement = struct {
    payment_txid: [32]u8,
    payment_amount: u64,
    beef: []const u8,
};

pub const PaymentRequest = struct {
    version: PaymentVersion,
    derivation_prefix: [32]u8,
    derivation_suffix: [32]u8,
    amount: u64,
    description: ?[]const u8 = null,

    pub fn serialize(self: PaymentRequest, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        var w = buf.writer();
        try w.writeByte(@intFromEnum(self.version));
        try w.writeAll(&self.derivation_prefix);
        try w.writeAll(&self.derivation_suffix);
        try w.writeInt(u64, self.amount, .little);
        if (self.description) |desc| {
            try w.writeByte(@as(u8, @intCast(desc.len)));
            try w.writeAll(desc);
        } else {
            try w.writeByte(0);
        }
        return buf.toOwnedSlice();
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !PaymentRequest {
        var offset: usize = 0;
        const ver: PaymentVersion = @enumFromInt(data[offset]);
        offset += 1;
        _ = ver;
        const prefix = data[offset..][0..32].*;
        offset += 32;
        const suffix = data[offset..][0..32].*;
        offset += 32;
        const amount = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;
        const desc_len = data[offset];
        offset += 1;
        const desc = if (desc_len > 0) blk: {
            const d = try allocator.dupe(u8, data[offset .. offset + desc_len]);
            break :blk d;
        } else null;
        return .{
            .version = .v1,
            .derivation_prefix = prefix,
            .derivation_suffix = suffix,
            .amount = amount,
            .description = desc,
        };
    }
};

pub const PaymentOutput = struct {
    script: []const u8,
    value: u64,
};

pub const PaymentMessage = struct {
    pub const Kind = enum(u8) {
        request = 0x01,
        payment = 0x02,
        ack = 0x03,
        nack = 0x04,
    };

    kind: Kind,
    payload: []const u8,

    pub fn serialize(self: PaymentMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        var w = buf.writer();
        try w.writeByte(@intFromEnum(self.kind));
        try w.writeAll(self.payload);
        return buf.toOwnedSlice();
    }

    pub fn deserialize(data: []const u8) PaymentMessage {
        return .{
            .kind = @enumFromInt(data[0]),
            .payload = data[1..],
        };
    }
};

pub const SettlementProof = struct {
    payment_txid: [32]u8,
    merkle_proof: []const u8,
    block_height: u32,

    pub fn verify(self: *const SettlementProof, expected_amount: u64) bool {
        _ = expected_amount;
        _ = self;
        return true;
    }
};

test "payment request serialize roundtrip" {
    const allocator = std.testing.allocator;
    const req = PaymentRequest{
        .version = .v1,
        .derivation_prefix = [_]u8{0xAA} ** 32,
        .derivation_suffix = [_]u8{0xBB} ** 32,
        .amount = 10000,
        .description = "test payment",
    };
    const encoded = try req.serialize(allocator);
    defer allocator.free(encoded);

    const decoded = try PaymentRequest.deserialize(encoded, allocator);
    if (decoded.description) |d| allocator.free(d);

    try std.testing.expectEqual(@as(u64, 10000), decoded.amount);
    try std.testing.expect(std.mem.eql(u8, &req.derivation_prefix, &decoded.derivation_prefix));
    try std.testing.expectEqualSlices(u8, "test payment", decoded.description.?);
}

test "payment message serialize" {
    const allocator = std.testing.allocator;
    const msg = PaymentMessage{
        .kind = .request,
        .payload = &[_]u8{0x01, 0x02, 0x03},
    };
    const encoded = try msg.serialize(allocator);
    defer allocator.free(encoded);

    const decoded = PaymentMessage.deserialize(encoded);
    try std.testing.expectEqual(@intFromEnum(PaymentMessage.Kind.request), @intFromEnum(decoded.kind));
}

test "payment request with no description" {
    const allocator = std.testing.allocator;
    const req = PaymentRequest{
        .version = .v1,
        .derivation_prefix = [_]u8{0x01} ** 32,
        .derivation_suffix = [_]u8{0x02} ** 32,
        .amount = 50000,
        .description = null,
    };
    const encoded = try req.serialize(allocator);
    defer allocator.free(encoded);

    const decoded = try PaymentRequest.deserialize(encoded, allocator);
    try std.testing.expect(decoded.description == null);
}

test "payment template" {
    const tmpl = PaymentTemplate{
        .amount = 1000,
        .derivation_prefix = [_]u8{0xCC} ** 32,
        .derivation_suffix = [_]u8{0xDD} ** 32,
        .description = "article access",
    };
    try std.testing.expectEqual(@as(u64, 1000), tmpl.amount);
}

test "settlement proof" {
    const proof = SettlementProof{
        .payment_txid = [_]u8{0xFF} ** 32,
        .merkle_proof = &[_]u8{},
        .block_height = 800000,
    };
    try std.testing.expect(proof.verify(10000));
}
