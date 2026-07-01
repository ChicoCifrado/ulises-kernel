const std = @import("std");

pub const IPV4_HLEN = 20;

pub const Protocol = enum(u8) {
    icmp = 1,
    tcp = 6,
    udp = 17,
    _,
};

pub const Ipv4Header = extern struct {
    ver_ihl: u8,
    dscp_ecn: u8,
    total_len: u16,
    id: u16,
    flags_frag: u16,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src: [4]u8,
    dst: [4]u8,

    pub fn init(src: [4]u8, dst: [4]u8, protocol: u8, payload_len: usize) Ipv4Header {
        var hdr = Ipv4Header{
            .ver_ihl = (4 << 4) | 5,
            .dscp_ecn = 0,
            .total_len = @byteSwap(@as(u16, @intCast(IPV4_HLEN + payload_len))),
            .id = 0,
            .flags_frag = 0x40 << 8,
            .ttl = 64,
            .protocol = protocol,
            .checksum = 0,
            .src = src,
            .dst = dst,
        };
        hdr.checksum = hdr.computeChecksum();
        return hdr;
    }

    pub fn computeChecksum(self: *const Ipv4Header) u16 {
        var sum: u32 = 0;
        const bytes = std.mem.asBytes(self);
        var i: usize = 0;
        while (i + 1 < bytes.len) {
            sum += @as(u32, bytes[i]) << 8 | bytes[i + 1];
            i += 2;
        }
        sum = (sum >> 16) + (sum & 0xFFFF);
        sum = (sum >> 16) + (sum & 0xFFFF);
        return @as(u16, ~@as(u16, @truncate(sum)));
    }

    pub fn verifyChecksum(self: *const Ipv4Header) bool {
        return self.computeChecksum() == 0;
    }

    pub fn headerLength(self: *const Ipv4Header) usize {
        return (self.ver_ihl & 0x0F) * 4;
    }

    pub fn totalLength(self: *const Ipv4Header) usize {
        return @byteSwap(self.total_len);
    }

    pub fn isBroadcast(self: *const Ipv4Header) bool {
        for (self.dst) |b| if (b != 0xFF) return false;
        return true;
    }

    pub fn isForUs(self: *const Ipv4Header, our_ip: [4]u8) bool {
        return std.mem.eql(u8, &self.dst, &our_ip) or self.isBroadcast();
    }
};
