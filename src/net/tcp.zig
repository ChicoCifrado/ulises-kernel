const std = @import("std");

pub const TCP_HLEN = 20;

pub const State = enum(u8) {
    closed,
    syn_sent,
    established,
    fin_wait_1,
    fin_wait_2,
    closing,
    time_wait,
    last_ack,
};

pub const TcpHeader = packed struct {
    src_port: u16,
    dst_port: u16,
    seq_num: u32,
    ack_num: u32,
    data_offset_reserved: u8,
    flags: u8,
    window: u16,
    checksum: u16,
    urgent: u16,

    pub fn init(src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, window: u16) TcpHeader {
        return .{
            .src_port = @byteSwap(src_port),
            .dst_port = @byteSwap(dst_port),
            .seq_num = @byteSwap(seq),
            .ack_num = @byteSwap(ack),
            .data_offset_reserved = (5 << 4),
            .flags = flags,
            .window = @byteSwap(window),
            .checksum = 0,
            .urgent = 0,
        };
    }

    pub fn computeChecksum(hdr: *const TcpHeader, src_ip: [4]u8, dst_ip: [4]u8, payload: []const u8) u16 {
        var sum: u32 = 0;
        const pseudo = PseudoHeader{
            .src = src_ip,
            .dst = dst_ip,
            .zero = 0,
            .protocol = 6,
            .tcp_len = @byteSwap(@as(u16, @intCast(TCP_HLEN + payload.len))),
        };
        const pseudo_words = @as(*const [6]u16, @ptrCast(&pseudo));
        for (pseudo_words) |w| sum += @byteSwap(w);
        const tcp_words = @as(*const [10]u16, @ptrCast(hdr));
        for (tcp_words) |w| sum += @byteSwap(w);
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
};

const PseudoHeader = packed struct {
    src: [4]u8,
    dst: [4]u8,
    zero: u8,
    protocol: u8,
    tcp_len: u16,
};

pub const Connection = struct {
    state: State,
    src_port: u16,
    dst_port: u16,
    dst_ip: [4]u8,
    seq: u32,
    ack: u32,
    rcv_buf: [4096]u8,
    rcv_len: usize,
    rcv_mss: u16,

    pub fn init(src_port: u16, dst_ip: [4]u8, dst_port: u16) Connection {
        return .{
            .state = .closed,
            .src_port = src_port,
            .dst_port = dst_port,
            .dst_ip = dst_ip,
            .seq = 0,
            .ack = 0,
            .rcv_buf = undefined,
            .rcv_len = 0,
            .rcv_mss = 1460,
        };
    }

    pub fn buildSegment(self: *const Connection, flags: u8, payload: []const u8, src_ip: [4]u8, buf: []u8) ?usize {
        const total = TCP_HLEN + payload.len;
        if (buf.len < total) return null;
        const hdr = TcpHeader.init(self.src_port, self.dst_port, self.seq, self.ack, flags, 65535);
        @memcpy(buf[0..TCP_HLEN], std.mem.asBytes(&hdr));
        if (payload.len > 0) @memcpy(buf[TCP_HLEN..][0..payload.len], payload);
        var mutable_hdr = @as(*TcpHeader, @ptrCast(buf.ptr));
        mutable_hdr.checksum = TcpHeader.computeChecksum(mutable_hdr, src_ip, self.dst_ip, payload);
        return total;
    }

    pub fn parseSegment(self: *Connection, data: []const u8) void {
        if (data.len < TCP_HLEN) return;
        const hdr = @as(*const TcpHeader, @ptrCast(data.ptr));
        const flags = hdr.flags;
        const hdr_len = (@as(usize, hdr.data_offset_reserved) >> 4) * 4;
        if (data.len < hdr_len) return;
        const payload = data[hdr_len..];
        self.ack = @byteSwap(hdr.seq_num) + @as(u32, @intCast(payload.len));
        if (flags & 0x02 != 0 and self.state == .syn_sent) {
            self.ack += 1;
            self.state = .established;
        }
        if (payload.len > 0 and self.state == .established) {
            const copy_len = @min(payload.len, self.rcv_buf.len - self.rcv_len);
            @memcpy(self.rcv_buf[self.rcv_len..][0..copy_len], payload);
            self.rcv_len += copy_len;
        }
        if (flags & 0x01 != 0 and self.state == .established) {
            self.state = .closed;
        }
    }
};

pub fn synFlags() u8 { return 0x02; }
pub fn ackFlags() u8 { return 0x10; }
pub fn synAckFlags() u8 { return 0x12; }
pub fn finFlags() u8 { return 0x01; }
pub fn finAckFlags() u8 { return 0x11; }
pub fn pshAckFlags() u8 { return 0x18; }
