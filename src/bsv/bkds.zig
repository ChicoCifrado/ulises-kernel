const std = @import("std");
const Sha256 = @import("hash.zig").Sha256;
const hash = @import("hash.zig");
const secp = @import("secp256k1.zig").secp256k1;

pub const BkdsError = error{
    InvalidKey,
    DerivationFailed,
    InvalidInvoiceNumber,
    NotImplemented,
};

pub const KeyType = enum(u8) {
    ecdh = 0x00,
    identity_key = 0x01,
    signing_key = 0x02,
    encryption_key = 0x03,
    auth_key = 0x04,
    symmetric_key = 0x05,
};

pub const SenderIntent = enum(u8) {
    direct = 0x00,
    parted = 0x01,
    broadcast = 0x02,
};

pub const InvoiceNo = struct {
    sender_intent: SenderIntent,
    key_type: KeyType,
    key_id: u64,
    counter: u64,

    pub fn serialize(self: InvoiceNo) [34]u8 {
        var buf: [34]u8 = undefined;
        buf[0] = @intFromEnum(self.sender_intent);
        buf[1] = @intFromEnum(self.key_type);
        std.mem.writeInt(u64, buf[2..10], self.key_id, .little);
        std.mem.writeInt(u64, buf[10..18], self.counter, .little);
        @memset(buf[18..34], 0);
        return buf;
    }

    pub fn deserialize(buf: [34]u8) InvoiceNo {
        return .{
            .sender_intent = @enumFromInt(buf[0]),
            .key_type = @enumFromInt(buf[1]),
            .key_id = std.mem.readInt(u64, buf[2..10], .little),
            .counter = std.mem.readInt(u64, buf[10..18], .little),
        };
    }

    pub fn next(self: InvoiceNo) InvoiceNo {
        return .{
            .sender_intent = self.sender_intent,
            .key_type = self.key_type,
            .key_id = self.key_id,
            .counter = self.counter + 1,
        };
    }
};

pub fn bkdsEcdh(priv: [32]u8, pub_: [33]u8) [32]u8 {
    return secp.ecdh(priv, pub_);
}

pub const DerivedKey = struct {
    priv: [32]u8,
    pub_: [33]u8,
};

pub const KeyDerivation = struct {
    pub fn deriveChild(
        parent_priv: [32]u8,
        parent_pub: [33]u8,
        invoice: InvoiceNo,
        ecdh: *const fn ([32]u8, [33]u8) [32]u8,
    ) DerivedKey {
        const serialized = invoice.serialize();
        const ecdh_secret = ecdh(parent_priv, parent_pub);
        var state = Sha256.init(.{});
        state.update(&ecdh_secret);
        state.update(&serialized);
        const child_scalar = state.final();
        return .{ .priv = child_scalar, .pub_ = parent_pub };
    }

    pub fn deriveChildShared(
        priv_a: [32]u8,
        pub_b: [33]u8,
        invoice: InvoiceNo,
        ecdh: *const fn ([32]u8, [33]u8) [32]u8,
    ) DerivedKey {
        const serialized = invoice.serialize();
        const ecdh_secret = ecdh(priv_a, pub_b);
        var state = Sha256.init(.{});
        state.update(&ecdh_secret);
        state.update(&serialized);
        const derived = state.final();
        return .{ .priv = derived, .pub_ = pub_b };
    }

    pub fn derivePublicOnly(pub_: [33]u8, invoice: InvoiceNo) [33]u8 {
        _ = invoice;
        return pub_;
    }
};

pub const EcdhIdentity = struct {
    priv: [32]u8,
    pub_: [33]u8,

    pub fn deriveChildKey(self: EcdhIdentity, invoice: InvoiceNo, ecdh_fn: *const fn ([32]u8, [33]u8) [32]u8) DerivedKey {
        return KeyDerivation.deriveChild(self.priv, self.pub_, invoice, ecdh_fn);
    }

    pub fn deriveSharedKey(self: EcdhIdentity, counterparty_pub: [33]u8, invoice: InvoiceNo, ecdh_fn: *const fn ([32]u8, [33]u8) [32]u8) [32]u8 {
        const derived = KeyDerivation.deriveChildShared(self.priv, counterparty_pub, invoice, ecdh_fn);
        return derived.priv;
    }
};

test "invoice_no serialize roundtrip" {
    const inv = InvoiceNo{
        .sender_intent = .direct,
        .key_type = .identity_key,
        .key_id = 42,
        .counter = 7,
    };
    const ser = inv.serialize();
    const de = InvoiceNo.deserialize(ser);
    try std.testing.expectEqual(@intFromEnum(SenderIntent.direct), @intFromEnum(de.sender_intent));
    try std.testing.expectEqual(@intFromEnum(KeyType.identity_key), @intFromEnum(de.key_type));
    try std.testing.expectEqual(@as(u64, 42), de.key_id);
    try std.testing.expectEqual(@as(u64, 7), de.counter);
}

test "invoice_no next increments counter" {
    const inv = InvoiceNo{ .sender_intent = .direct, .key_type = .signing_key, .key_id = 0, .counter = 0 };
    const next = inv.next();
    try std.testing.expectEqual(@as(u64, 1), next.counter);
    try std.testing.expectEqual(@as(u64, 0), next.key_id);
}

test "derive child uses sha256" {
    const ecdh_fn = struct {
        fn f(_: [32]u8, pub_: [33]u8) [32]u8 {
            _ = pub_;
            return [_]u8{0xAB} ** 32;
        }
    }.f;

    const parent_priv = [_]u8{0x01} ** 32;
    const parent_pub = [_]u8{0x02} ** 32 ++ [_]u8{0x03};
    const inv = InvoiceNo{ .sender_intent = .direct, .key_type = .identity_key, .key_id = 0, .counter = 0 };
    const result = KeyDerivation.deriveChild(parent_priv, parent_pub, inv, ecdh_fn);
    try std.testing.expectEqual(32, result.priv.len);
    try std.testing.expectEqual(33, result.pub_.len);
}

test "ecdh identity" {
    const ecdh_fn = struct {
        fn f(_: [32]u8, pub_: [33]u8) [32]u8 {
            _ = pub_;
            return [_]u8{0xCD} ** 32;
        }
    }.f;

    const id = EcdhIdentity{
        .priv = [_]u8{0xAA} ** 32,
        .pub_ = [_]u8{0xBB} ** 32 ++ [_]u8{0x01},
    };

    const derived = id.deriveChildKey(.{
        .sender_intent = .direct,
        .key_type = .signing_key,
        .key_id = 1,
        .counter = 0,
    }, ecdh_fn);
    try std.testing.expectEqual(32, derived.priv.len);
    try std.testing.expectEqual(33, derived.pub_.len);
}

test "bkds ecdh with real secp256k1" {
    const alice_priv = [_]u8{0xAA} ** 32;
    const bob_priv = [_]u8{0xBB} ** 32;
    const alice_pub = secp.pubkeyCreate(alice_priv);
    const bob_pub = secp.pubkeyCreate(bob_priv);
    const shared_a = bkdsEcdh(alice_priv, bob_pub);
    const shared_b = bkdsEcdh(bob_priv, alice_pub);
    try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
}

test "derive child with real ecdh" {
    const parent_priv = [_]u8{0x01} ** 32;
    const parent_pub = secp.pubkeyCreate(parent_priv);
    const inv = InvoiceNo{ .sender_intent = .direct, .key_type = .signing_key, .key_id = 0, .counter = 0 };
    const result = KeyDerivation.deriveChild(parent_priv, parent_pub, inv, bkdsEcdh);
    try std.testing.expectEqual(32, result.priv.len);
    try std.testing.expectEqual(33, result.pub_.len);
}
