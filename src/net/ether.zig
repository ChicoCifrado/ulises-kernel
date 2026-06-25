const std = @import("std");

pub const ETH_ALEN = 6;
pub const ETH_HLEN = 14;

pub const EtherType = enum(u16) {
    ipv4 = 0x0800,
    arp = 0x0806,
    ipv6 = 0x86DD,
    _,
};

pub const EtherHeader = packed struct {
    dst: [6]u8,
    src: [6]u8,
    ether_type: u16,

    pub fn init(dst: [6]u8, src: [6]u8, ether_type: u16) EtherHeader {
        return .{
            .dst = dst,
            .src = src,
            .ether_type = @byteSwap(ether_type),
        };
    }
};

pub fn isBroadcast(mac: [6]u8) bool {
    for (mac) |b| if (b != 0xFF) return false;
    return true;
}

pub fn isMulticast(mac: [6]u8) bool {
    return mac[0] & 1 != 0;
}

pub fn macEqual(a: [6]u8, b: [6]u8) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

const BROADCAST: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
const ZERO: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };

pub fn broadcastMac() *const [6]u8 { return &BROADCAST; }
pub fn zeroMac() *const [6]u8 { return &ZERO; }

pub fn formatMac(mac: [6]u8, buf: *[18]u8) []const u8 {
    _ = std.fmt.bufPrint(buf, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    }) catch {
        buf[0] = 0;
        return buf[0..1];
    };
    return buf;
}
