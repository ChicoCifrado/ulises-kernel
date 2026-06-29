const std = @import("std");

pub const ProtocolType = enum(u8) {
    self = 0x00,
    key_type = 0x01,
    custom = 0x02,
    default = 0x03,
};

pub const ProtocolId = struct {
    protocol_type: ProtocolType,
    value: [32]u8,

    pub fn fromSlice(slice: []const u8) ProtocolId {
        var value: [32]u8 = @splat(0);
        const copy_len = @min(slice.len, 32);
        @memcpy(value[0..copy_len], slice[0..copy_len]);
        return .{ .protocol_type = .custom, .value = value };
    }

    pub fn fromType(key_type: u8) ProtocolId {
        var value: [32]u8 = @splat(0);
        value[0] = key_type;
        return .{ .protocol_type = .key_type, .value = value };
    }

    pub fn self() ProtocolId {
        return .{ .protocol_type = .self, .value = @as([32]u8, @splat(0)) };
    }

    pub fn default() ProtocolId {
        return .{ .protocol_type = .default, .value = @as([32]u8, @splat(0)) };
    }

    pub fn eql(a: ProtocolId, b: ProtocolId) bool {
        return a.protocol_type == b.protocol_type and std.mem.eql(u8, &a.value, &b.value);
    }

    pub fn hashId(pid: ProtocolId) u64 {
        var h: u64 = 0xcbf29ce484222325;
        h = (h ^ @intFromEnum(pid.protocol_type)) *% 0x100000001b3;
        for (&pid.value) |b| {
            h = (h ^ b) *% 0x100000001b3;
        }
        return h;
    }
};

pub const KeyId = struct {
    key_id: u64,
    key_type: u8,

    pub fn new(id: u64, kt: u8) KeyId {
        return .{ .key_id = id, .key_type = kt };
    }
};

pub const Counterparty = struct {
    identity_key: [33]u8,
    encryption_key: ?[33]u8 = null,

    pub fn eql(self: Counterparty, other: Counterparty) bool {
        if (!std.mem.eql(u8, &self.identity_key, &other.identity_key)) return false;
        if (self.encryption_key) |ek| {
            if (other.encryption_key) |ok| {
                return std.mem.eql(u8, &ek, &ok);
            }
            return false;
        }
        return other.encryption_key == null;
    }
};

pub const SecurityLevel = struct {
    protocol_id: ProtocolId,
    counterparty: ?Counterparty,
    key_id: KeyId,

    pub fn init(protocol_id: ProtocolId, key_id: KeyId, counterparty: ?Counterparty) SecurityLevel {
        return .{ .protocol_id = protocol_id, .key_id = key_id, .counterparty = counterparty };
    }

    pub fn deriveInvoiceNo(self: SecurityLevel, sender_intent: u8, counter: u64) [34]u8 {
        var buf: [34]u8 = undefined;
        buf[0] = sender_intent;
        buf[1] = self.key_id.key_type;
        std.mem.writeInt(u64, buf[2..10], self.key_id.key_id, .little);
        std.mem.writeInt(u64, buf[10..18], counter, .little);
        @memset(buf[18..34], 0);
        return buf;
    }
};

test "protocol id self" {
    const pid = ProtocolId.self();
    try std.testing.expectEqual(@intFromEnum(ProtocolType.self), @intFromEnum(pid.protocol_type));
}

test "protocol id custom from slice" {
    const pid = ProtocolId.fromSlice("wallet");
    try std.testing.expectEqual(@intFromEnum(ProtocolType.custom), @intFromEnum(pid.protocol_type));
}

test "protocol id equality" {
    const a = ProtocolId.fromSlice("hello");
    const b = ProtocolId.fromSlice("hello");
    const c = ProtocolId.fromSlice("world");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "security level" {
    const pid = ProtocolId.default();
    const kid = KeyId.new(0, 0);
    const sl = SecurityLevel.init(pid, kid, null);
    const inv = sl.deriveInvoiceNo(0, 0);
    try std.testing.expectEqual(34, inv.len);
}

test "counterparty equality" {
    const key_a: [33]u8 = @splat(0xAA);
    const key_b: [33]u8 = @splat(0xBB);
    const cp1 = Counterparty{ .identity_key = key_a, .encryption_key = null };
    const cp2 = Counterparty{ .identity_key = key_a, .encryption_key = null };
    const cp3 = Counterparty{ .identity_key = key_b, .encryption_key = null };
    try std.testing.expect(cp1.eql(cp2));
    try std.testing.expect(!cp1.eql(cp3));
}
