const std = @import("std");

pub const UDP_HLEN = 8;

pub const UdpHeader = extern struct {
    src_port: u16,
    dst_port: u16,
    length: u16,
    checksum: u16,
};

pub fn computeChecksum(src_ip: [4]u8, dst_ip: [4]u8, udp_hdr: *const UdpHeader, payload: []const u8) u16 {
    var sum: u32 = 0;

    // Pseudo-header: src IP, dst IP, zero, protocol=17, UDP length
    inline for (0..2) |i| sum += @as(u32, src_ip[i * 2]) << 8 | src_ip[i * 2 + 1];
    inline for (0..2) |i| sum += @as(u32, dst_ip[i * 2]) << 8 | dst_ip[i * 2 + 1];
    sum += @as(u32, 0) << 8 | 17;
    const udp_len = @byteSwap(udp_hdr.length);
    sum += udp_len;

    // UDP header + payload (padded to even length)
    const hdr_bytes = std.mem.asBytes(udp_hdr);
    var i: usize = 0;
    while (i + 1 < hdr_bytes.len) {
        sum += @as(u32, hdr_bytes[i]) << 8 | hdr_bytes[i + 1];
        i += 2;
    }
    i = 0;
    while (i + 1 < payload.len) {
        sum += @as(u32, payload[i]) << 8 | payload[i + 1];
        i += 2;
    }
    if (i < payload.len) sum += @as(u32, payload[i]) << 8;

    sum = (sum >> 16) + (sum & 0xFFFF);
    sum = (sum >> 16) + (sum & 0xFFFF);
    return @as(u16, ~@as(u16, @truncate(sum)));
}
