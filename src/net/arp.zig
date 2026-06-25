const std = @import("std");
const ether = @import("ether.zig");

pub const ARP_HTYPE_ETH = 1;
pub const ARP_PTYPE_IPV4 = 0x0800;
pub const ARP_HLEN = 6;
pub const ARP_PLEN = 4;

pub const Opcode = enum(u16) {
    request = 1,
    reply = 2,
    _,
};

pub const ArpPacket = packed struct {
    htype: u16,
    ptype: u16,
    hlen: u8,
    plen: u8,
    oper: u16,
    sha: [6]u8,
    spa: [4]u8,
    tha: [6]u8,
    tpa: [4]u8,

    pub fn initRequest(sender_mac: [6]u8, sender_ip: [4]u8, target_ip: [4]u8) ArpPacket {
        return .{
            .htype = @byteSwap(@as(u16, ARP_HTYPE_ETH)),
            .ptype = @byteSwap(@as(u16, ARP_PTYPE_IPV4)),
            .hlen = ARP_HLEN,
            .plen = ARP_PLEN,
            .oper = @byteSwap(@as(u16, @intFromEnum(Opcode.request))),
            .sha = sender_mac,
            .spa = sender_ip,
            .tha = ether.zeroMac().*,
            .tpa = target_ip,
        };
    }

    pub fn initReply(sender_mac: [6]u8, sender_ip: [4]u8, target_mac: [6]u8, target_ip: [4]u8) ArpPacket {
        return .{
            .htype = @byteSwap(@as(u16, ARP_HTYPE_ETH)),
            .ptype = @byteSwap(@as(u16, ARP_PTYPE_IPV4)),
            .hlen = ARP_HLEN,
            .plen = ARP_PLEN,
            .oper = @byteSwap(@as(u16, @intFromEnum(Opcode.reply))),
            .sha = sender_mac,
            .spa = sender_ip,
            .tha = target_mac,
            .tpa = target_ip,
        };
    }

    pub fn opcode(self: *const ArpPacket) Opcode {
        return @enumFromInt(@byteSwap(self.oper));
    }

    pub fn isIpv4Eth(self: *const ArpPacket) bool {
        return @byteSwap(self.htype) == ARP_HTYPE_ETH and
            @byteSwap(self.ptype) == ARP_PTYPE_IPV4 and
            self.hlen == ARP_HLEN and
            self.plen == ARP_PLEN;
    }
};

pub const ArpCache = struct {
    entries: [16]ArpEntry,
    count: usize,

    pub const ArpEntry = struct {
        ip: [4]u8,
        mac: [6]u8,
    };

    pub fn init() ArpCache {
        return .{ .entries = undefined, .count = 0 };
    }

    pub fn lookup(self: *const ArpCache, ip: [4]u8) ?[6]u8 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, &self.entries[i].ip, &ip)) {
                return self.entries[i].mac;
            }
        }
        return null;
    }

    pub fn update(self: *ArpCache, ip: [4]u8, mac: [6]u8) void {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, &self.entries[i].ip, &ip)) {
                self.entries[i].mac = mac;
                return;
            }
        }
        if (self.count < self.entries.len) {
            self.entries[self.count] = .{ .ip = ip, .mac = mac };
            self.count += 1;
        }
    }
};
