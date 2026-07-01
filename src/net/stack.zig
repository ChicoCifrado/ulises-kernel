const std = @import("std");
const builtin = @import("builtin");
const ether = @import("ether.zig");
const arp = @import("arp.zig");
const ipv4_mod = @import("ipv4.zig");
const icmp_mod = @import("icmp.zig");
const e1000_mod = @import("e1000.zig");

pub const Stack = struct {
    nic: *e1000_mod.E1000,
    arp_cache: arp.ArpCache,
    our_mac: [6]u8,
    our_ip: [4]u8,
    our_netmask: [4]u8,
    our_gateway: [4]u8,

    pub fn init(nic: *e1000_mod.E1000, ip: [4]u8, netmask: [4]u8, gateway: [4]u8) Stack {
        return .{
            .nic = nic,
            .arp_cache = arp.ArpCache.init(),
            .our_mac = nic.macAddress(),
            .our_ip = ip,
            .our_netmask = netmask,
            .our_gateway = gateway,
        };
    }

    pub fn poll(self: *Stack) void {
        while (self.nic.receive()) |pkt| {
            if (pkt.len < ether.ETH_HLEN) continue;
            const eth_hdr = @as(*const ether.EtherHeader, @alignCast(@ptrCast(pkt.ptr)));
            const eth_type = @byteSwap(eth_hdr.ether_type);

            if (eth_type == @intFromEnum(ether.EtherType.arp)) {
                self.handleArp(pkt);
            } else if (eth_type == @intFromEnum(ether.EtherType.ipv4)) {
                self.handleIpv4(pkt);
            }
        }
    }

    fn handleArp(self: *Stack, pkt: []const u8) void {
        if (pkt.len < ether.ETH_HLEN + @sizeOf(arp.ArpPacket)) return;
        const arp_pkt = @as(*const arp.ArpPacket, @alignCast(@ptrCast(pkt.ptr + ether.ETH_HLEN)));
        if (!arp_pkt.isIpv4Eth()) return;

        self.arp_cache.update(arp_pkt.spa, arp_pkt.sha);

        if (arp_pkt.opcode() == .request and
            std.mem.eql(u8, &arp_pkt.tpa, &self.our_ip))
        {
            self.sendArpReply(arp_pkt);
        }
    }

    fn sendArpReply(self: *Stack, req: *const arp.ArpPacket) void {
        var buf: [ether.ETH_HLEN + @sizeOf(arp.ArpPacket)]u8 = undefined;

        const eth_hdr = @as(*ether.EtherHeader, @alignCast(@ptrCast(&buf)));
        eth_hdr.* = ether.EtherHeader.init(req.sha, self.our_mac, @intFromEnum(ether.EtherType.arp));

        const arp_reply = arp.ArpPacket.initReply(self.our_mac, self.our_ip, req.sha, req.spa);
        @memcpy(buf[ether.ETH_HLEN..][0..@sizeOf(arp.ArpPacket)], std.mem.asBytes(&arp_reply));

        _ = self.nic.send(&buf);
    }

    fn handleIpv4(self: *Stack, pkt: []const u8) void {
        if (pkt.len < ether.ETH_HLEN + ipv4_mod.IPV4_HLEN) return;
        const ip_hdr = @as(*const ipv4_mod.Ipv4Header, @alignCast(@ptrCast(pkt.ptr + ether.ETH_HLEN)));
        if (!ip_hdr.isForUs(self.our_ip)) return;
        if (!ip_hdr.verifyChecksum()) return;

        const hlen = ip_hdr.headerLength();
        const total_len = ip_hdr.totalLength();
        if (pkt.len < ether.ETH_HLEN + total_len) return;
        const payload = pkt[ether.ETH_HLEN + hlen .. ether.ETH_HLEN + total_len];

        switch (ip_hdr.protocol) {
            @intFromEnum(ipv4_mod.Protocol.icmp) => self.handleIcmp(ip_hdr, payload),
            else => {},
        }
    }

    fn handleIcmp(self: *Stack, ip_hdr: *const ipv4_mod.Ipv4Header, payload: []const u8) void {
        if (payload.len < icmp_mod.ICMP_HLEN) return;
        const icmp_hdr = @as(*const icmp_mod.IcmpHeader, @alignCast(@ptrCast(payload.ptr)));
        if (icmp_hdr.type_ == @intFromEnum(icmp_mod.Type.echo_request)) {
            self.sendIcmpReply(ip_hdr, icmp_hdr, payload[icmp_mod.ICMP_HLEN..]);
        }
    }

    fn sendIcmpReply(self: *Stack, ip_hdr: *const ipv4_mod.Ipv4Header, icmp_hdr: *const icmp_mod.IcmpHeader, icmp_data: []const u8) void {
        const reply_icmp = icmp_hdr.echoReply(icmp_data);
        const payload_len = icmp_mod.ICMP_HLEN + icmp_data.len;
        const total_len = ipv4_mod.IPV4_HLEN + payload_len;
        var buf: [ether.ETH_HLEN + ipv4_mod.IPV4_HLEN + icmp_mod.ICMP_HLEN + 256]u8 = undefined;
        const total = ether.ETH_HLEN + total_len;
        if (total > buf.len) return;

        const dst_mac = self.resolveMac(ip_hdr.src) orelse return;

        const eth_hdr = @as(*ether.EtherHeader, @alignCast(@ptrCast(&buf)));
        eth_hdr.* = ether.EtherHeader.init(dst_mac, self.our_mac, @intFromEnum(ether.EtherType.ipv4));

        const reply_ip = ipv4_mod.Ipv4Header.init(self.our_ip, ip_hdr.src, @intFromEnum(ipv4_mod.Protocol.icmp), payload_len);
        @memcpy(buf[ether.ETH_HLEN..][0..@sizeOf(ipv4_mod.Ipv4Header)], std.mem.asBytes(&reply_ip));

        @memcpy(buf[ether.ETH_HLEN + ipv4_mod.IPV4_HLEN ..][0..@sizeOf(icmp_mod.IcmpHeader)], std.mem.asBytes(&reply_icmp));
        if (icmp_data.len > 0) {
            @memcpy(buf[ether.ETH_HLEN + ipv4_mod.IPV4_HLEN + icmp_mod.ICMP_HLEN ..][0..icmp_data.len], icmp_data);
        }

        _ = self.nic.send(buf[0..total]);
    }

    fn resolveMac(self: *Stack, ip: [4]u8) ?[6]u8 {
        if (std.mem.eql(u8, &ip, &self.our_ip)) return self.our_mac;
        return self.arp_cache.lookup(ip);
    }

    pub fn sendIpv4(self: *Stack, dst_ip: [4]u8, protocol: u8, payload: []const u8) void {
        const dst_mac = self.resolveMac(dst_ip) orelse return;
        const total_len = ipv4_mod.IPV4_HLEN + payload.len;
        var buf: [ether.ETH_HLEN + ipv4_mod.IPV4_HLEN + 1500]u8 = undefined;
        const total = ether.ETH_HLEN + total_len;
        if (total > buf.len) return;

        const eth_hdr = @as(*ether.EtherHeader, @alignCast(@ptrCast(&buf)));
        eth_hdr.* = ether.EtherHeader.init(dst_mac, self.our_mac, @intFromEnum(ether.EtherType.ipv4));

        const ip_hdr = ipv4_mod.Ipv4Header.init(self.our_ip, dst_ip, protocol, payload.len);
        @memcpy(buf[ether.ETH_HLEN..][0..@sizeOf(ipv4_mod.Ipv4Header)], std.mem.asBytes(&ip_hdr));

        @memcpy(buf[ether.ETH_HLEN + ipv4_mod.IPV4_HLEN ..][0..payload.len], payload);

        _ = self.nic.send(buf[0..total]);
    }

    pub fn sendArpRequest(self: *Stack, target_ip: [4]u8) void {
        var buf: [ether.ETH_HLEN + @sizeOf(arp.ArpPacket)]u8 = undefined;

        const eth_hdr = @as(*ether.EtherHeader, @alignCast(@ptrCast(&buf)));
        eth_hdr.* = ether.EtherHeader.init(ether.broadcastMac().*, self.our_mac, @intFromEnum(ether.EtherType.arp));

        const arp_req = arp.ArpPacket.initRequest(self.our_mac, self.our_ip, target_ip);
        @memcpy(buf[ether.ETH_HLEN..][0..@sizeOf(arp.ArpPacket)], std.mem.asBytes(&arp_req));

        _ = self.nic.send(&buf);
    }

    pub fn setIp(self: *Stack, ip: [4]u8) void {
        self.our_ip = ip;
    }

    pub fn setNetmask(self: *Stack, netmask: [4]u8) void {
        self.our_netmask = netmask;
    }

    pub fn setGateway(self: *Stack, gateway: [4]u8) void {
        self.our_gateway = gateway;
    }
};
