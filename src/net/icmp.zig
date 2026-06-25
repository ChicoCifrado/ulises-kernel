const std = @import("std");

pub const ICMP_HLEN = 8;

pub const Type = enum(u8) {
    echo_reply = 0,
    echo_request = 8,
    _,
};

pub const IcmpHeader = packed struct {
    type_: u8,
    code: u8,
    checksum: u16,
    rest: [4]u8,

    pub fn init(type_: u8, code: u8, id: u16, seq: u16) IcmpHeader {
        var hdr = IcmpHeader{
            .type_ = type_,
            .code = code,
            .checksum = 0,
            .rest = undefined,
        };
        std.mem.writeInt(u16, hdr.rest[0..2], id, .big);
        std.mem.writeInt(u16, hdr.rest[2..4], seq, .big);
        return hdr;
    }

    pub fn computeChecksum(hdr: *const IcmpHeader, payload: []const u8) u16 {
        var sum: u32 = 0;
        const words = @as(*const [4]u16, @ptrCast(hdr));
        for (words) |w| sum += @byteSwap(w);
        var i: usize = 0;
        while (i + 1 < payload.len) {
            sum += @as(u32, payload[i]) << 8 | payload[i + 1];
            i += 2;
        }
        if (i < payload.len) sum += @as(u32, payload[i]) << 8;
        sum = (sum >> 16) + (sum & 0xFFFF);
        sum = (sum >> 16) + (sum & 0xFFFF);
        return @as(u16, ~@as(u16, @truncate(sum)));
    }

    pub fn echoReply(hdr: *const IcmpHeader, payload: []const u8) IcmpHeader {
        var reply = IcmpHeader{
            .type_ = @intFromEnum(Type.echo_reply),
            .code = 0,
            .checksum = 0,
            .rest = hdr.rest,
        };
        reply.checksum = reply.computeChecksum(payload);
        return reply;
    }
};
