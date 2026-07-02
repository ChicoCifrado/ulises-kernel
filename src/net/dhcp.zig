const std = @import("std");
const ether = @import("ether.zig");
const ipv4_mod = @import("ipv4.zig");
const udp_mod = @import("udp.zig");
const e1000_mod = @import("e1000.zig");

pub const DHCP_SERVER_PORT = 67;
pub const DHCP_CLIENT_PORT = 68;
const MAGIC_COOKIE: [4]u8 = .{ 99, 130, 83, 99 };

pub const MsgType = enum(u8) {
    discover = 1,
    offer = 2,
    request = 3,
    ack = 5,
    nak = 6,
    _,
};

const OptionTag = enum(u8) {
    subnet_mask = 1,
    router = 3,
    dns = 6,
    hostname = 12,
    requested_ip = 50,
    lease_time = 51,
    msg_type = 53,
    server_id = 54,
    param_req = 55,
    end = 255,
};

pub const DhcpMessage = extern struct {
    op: u8,
    htype: u8,
    hlen: u8,
    hops: u8,
    xid: u32,
    secs: u16,
    flags: u16,
    ciaddr: [4]u8,
    yiaddr: [4]u8,
    siaddr: [4]u8,
    giaddr: [4]u8,
    chaddr: [16]u8,
    sname: [64]u8,
    file: [128]u8,
    cookie: [4]u8,

    fn init(xid: u32, mac: [6]u8) DhcpMessage {
        var msg = std.mem.zeroes(DhcpMessage);
        msg.op = 1; // request
        msg.htype = 1; // Ethernet
        msg.hlen = 6;
        msg.xid = xid;
        msg.flags = 0x8000; // broadcast
        @memcpy(msg.chaddr[0..6], &mac);
        msg.cookie = MAGIC_COOKIE;
        return msg;
    }
};

pub const DhcpClient = struct {
    state: enum { idle, selecting, requesting, bound } = .idle,
    xid: u32 = 0,
    server_ip: [4]u8 = .{ 0, 0, 0, 0 },
    our_ip: [4]u8 = .{ 0, 0, 0, 0 },
    subnet_mask: [4]u8 = .{ 0, 0, 0, 0 },
    gateway: [4]u8 = .{ 0, 0, 0, 0 },
    dns: [4]u8 = .{ 0, 0, 0, 0 },
    lease_time: u32 = 0,
    tries: usize = 0,
    tick: usize = 0,

    pub fn start(self: *DhcpClient) void {
        self.state = .selecting;
        // Generate xid from pointer value as a simple unique id
        self.xid = @truncate(@as(u64, @bitCast(@intFromPtr(self))));
        self.tries = 0;
        self.tick = 0;
    }

    pub fn tickPoll(self: *DhcpClient, mac: [6]u8, nic: *e1000_mod.E1000) void {
        self.tick += 1;
        if (self.state == .selecting and self.tries < 5 and self.tick % 50 == 0) {
            self.tries += 1;
            self.sendDiscover(mac, nic);
        }
    }

    pub fn sendDiscover(self: *DhcpClient, mac: [6]u8, nic: *e1000_mod.E1000) void {
        const msg = DhcpMessage.init(self.xid, mac);
        var buf: [@sizeOf(DhcpMessage) + 16]u8 = undefined;
        @memcpy(buf[0..@sizeOf(DhcpMessage)], std.mem.asBytes(&msg));
        var off: usize = @sizeOf(DhcpMessage);
        const msg_type_buf = [_]u8{@intFromEnum(MsgType.discover)};
        off = appendOption(buf[0..], off, .msg_type, &msg_type_buf);
        const param_req_buf = [_]u8{ @intFromEnum(OptionTag.subnet_mask), @intFromEnum(OptionTag.router), @intFromEnum(OptionTag.dns) };
        off = appendOption(buf[0..], off, .param_req, &param_req_buf);
        off = appendEnd(buf[0..], off);

        const bcast: [4]u8 = .{ 255, 255, 255, 255 };
        sendDhcpUdp(nic, bcast, DHCP_SERVER_PORT, DHCP_CLIENT_PORT, buf[0..off]);
    }

    pub fn sendRequest(self: *DhcpClient, mac: [6]u8, nic: *e1000_mod.E1000) void {
        var msg = DhcpMessage.init(self.xid, mac);
        @memcpy(&msg.ciaddr, &self.our_ip);
        var buf: [@sizeOf(DhcpMessage) + 32]u8 = undefined;
        @memcpy(buf[0..@sizeOf(DhcpMessage)], std.mem.asBytes(&msg));
        var off: usize = @sizeOf(DhcpMessage);
        const req_type = [_]u8{@intFromEnum(MsgType.request)};
        off = appendOption(buf[0..], off, .msg_type, &req_type);
        off = appendOption(buf[0..], off, .server_id, &self.server_ip);
        off = appendOption(buf[0..], off, .requested_ip, &self.our_ip);
        off = appendEnd(buf[0..], off);

        const bcast: [4]u8 = .{ 255, 255, 255, 255 };
        sendDhcpUdp(nic, bcast, DHCP_SERVER_PORT, DHCP_CLIENT_PORT, buf[0..off]);
    }

    pub fn handleReply(self: *DhcpClient, msg: *const DhcpMessage, options: []const u8) void {
        const msg_type_val = findOption(options, .msg_type) orelse return;
        if (msg_type_val.len < 1) return;
        const msg_type: MsgType = @enumFromInt(msg_type_val[0]);

        switch (msg_type) {
            .offer => {
                if (self.state != .selecting) return;
                self.our_ip = msg.yiaddr;
                self.server_ip = msg.siaddr;
                parseOptions(self, options);
                self.state = .requesting;
            },
            .ack => {
                if (self.state != .requesting) return;
                parseOptions(self, options);
                self.state = .bound;
            },
            .nak => {
                self.state = .idle;
            },
            else => {},
        }
    }

    fn parseOptions(self: *DhcpClient, options: []const u8) void {
        var i: usize = 0;
        while (i < options.len) {
            const tag = options[i];
            if (tag == @intFromEnum(OptionTag.end)) break;
            if (tag == 0) { i += 1; continue; }
            if (i + 1 >= options.len) break;
            const len = options[i + 1];
            if (i + 1 + len > options.len) break;
            const val = options[i + 2 .. i + 2 + len];
            switch (tag) {
                @intFromEnum(OptionTag.subnet_mask) => { if (len >= 4) @memcpy(&self.subnet_mask, val[0..4]); },
                @intFromEnum(OptionTag.router) => { if (len >= 4) @memcpy(&self.gateway, val[0..4]); },
                @intFromEnum(OptionTag.dns) => { if (len >= 4) @memcpy(&self.dns, val[0..4]); },
                @intFromEnum(OptionTag.lease_time) => { if (len >= 4) self.lease_time = std.mem.readInt(u32, val[0..4], .big); },
                else => {},
            }
            i += 2 + len;
        }
    }
};

fn findOption(options: []const u8, tag: OptionTag) ?[]const u8 {
    var i: usize = 0;
    while (i < options.len) {
        if (options[i] == @intFromEnum(OptionTag.end)) break;
        if (options[i] == 0) { i += 1; continue; }
        if (i + 1 >= options.len) break;
        const len = options[i + 1];
        if (i + 1 + len > options.len) break;
        if (options[i] == @intFromEnum(tag))
            return options[i + 2 .. i + 2 + len];
        i += 2 + len;
    }
    return null;
}

fn appendOption(buf: []u8, off: usize, tag: OptionTag, val: []const u8) usize {
    buf[off] = @intFromEnum(tag);
    buf[off + 1] = @intCast(val.len);
    @memcpy(buf[off + 2 ..][0..val.len], val);
    return off + 2 + val.len;
}

fn appendEnd(buf: []u8, off: usize) usize {
    buf[off] = @intFromEnum(OptionTag.end);
    return off + 1;
}

fn sendDhcpUdp(nic: *e1000_mod.E1000, dst_ip: [4]u8, dst_port: u16, src_port: u16, data: []const u8) void {
    const udp_len = udp_mod.UDP_HLEN + data.len;
    const total = ether.ETH_HLEN + ipv4_mod.IPV4_HLEN + udp_len;
    if (total > 1514) return;

    var buf: [ether.ETH_HLEN + ipv4_mod.IPV4_HLEN + udp_mod.UDP_HLEN + 300]u8 = undefined;

    const eth = @as(*ether.EtherHeader, @alignCast(@ptrCast(&buf)));
    eth.* = ether.EtherHeader.init(ether.broadcastMac().*, nic.macAddress(), @intFromEnum(ether.EtherType.ipv4));

    const zero_ip: [4]u8 = .{ 0, 0, 0, 0 };
    const ip = ipv4_mod.Ipv4Header.init(zero_ip, dst_ip, @intFromEnum(ipv4_mod.Protocol.udp), udp_len);
    @memcpy(buf[ether.ETH_HLEN..][0..@sizeOf(ipv4_mod.Ipv4Header)], std.mem.asBytes(&ip));

    const udp = @as(*udp_mod.UdpHeader, @alignCast(@ptrCast(&buf[ether.ETH_HLEN + ipv4_mod.IPV4_HLEN])));
    udp.* = .{
        .src_port = @byteSwap(src_port),
        .dst_port = @byteSwap(dst_port),
        .length = @byteSwap(@as(u16, @intCast(udp_len))),
        .checksum = 0,
    };
    @memcpy(buf[ether.ETH_HLEN + ipv4_mod.IPV4_HLEN + udp_mod.UDP_HLEN ..][0..data.len], data);

    _ = nic.send(buf[0..total]);
}
