const std = @import("std");
const builtin = @import("builtin");

const E1000_NUM_RX_DESC = 32;
const E1000_NUM_TX_DESC = 32;

const Regs = struct {
    pub const CTRL = 0x0000;
    pub const STATUS = 0x0008;
    pub const RCTRL = 0x0100;
    pub const RDBAL = 0x2800;
    pub const RDBAH = 0x2804;
    pub const RDLEN = 0x2808;
    pub const RDH = 0x2810;
    pub const RDT = 0x2818;
    pub const TCTRL = 0x0400;
    pub const TDBAL = 0x3800;
    pub const TDBAH = 0x3804;
    pub const TDLEN = 0x3808;
    pub const TDH = 0x3810;
    pub const TDT = 0x3818;
    pub const MTA = 0x5200;
    pub const RA = 0x5400;
};

pub const E1000 = struct {
    mmio_base: [*]volatile u32,
    rx_desc: []RxDesc,
    tx_desc: []TxDesc,
    rx_bufs: [][]u8,
    tx_bufs: [][]u8,
    rx_cur: usize,
    tx_cur: usize,
    allocator: std.mem.Allocator,

    const RxDesc = extern struct {
        addr: u64,
        length: u16,
        checksum: u16,
        status: u8,
        errors: u8,
        special: u16,
    };

    const TxDesc = extern struct {
        addr: u64,
        length: u16,
        cso: u8,
        cmd: u8,
        status: u8,
        css: u8,
        special: u16,
    };

    pub fn init(allocator: std.mem.Allocator, mmio_base: [*]volatile u32) !E1000 {
        var e1000 = E1000{
            .mmio_base = mmio_base,
            .rx_desc = try allocator.alloc(RxDesc, E1000_NUM_RX_DESC),
            .tx_desc = try allocator.alloc(TxDesc, E1000_NUM_TX_DESC),
            .rx_bufs = try allocator.alloc([]u8, E1000_NUM_RX_DESC),
            .tx_bufs = try allocator.alloc([]u8, E1000_NUM_TX_DESC),
            .rx_cur = 0,
            .tx_cur = 0,
            .allocator = allocator,
        };

        for (0..E1000_NUM_RX_DESC) |i| {
            e1000.rx_bufs[i] = try allocator.alloc(u8, 2048);
            @memset(e1000.rx_bufs[i], 0);
            e1000.rx_desc[i] = .{
                .addr = @intFromPtr(e1000.rx_bufs[i].ptr),
                .length = 0,
                .checksum = 0,
                .status = 0,
                .errors = 0,
                .special = 0,
            };
        }
        for (0..E1000_NUM_TX_DESC) |i| {
            e1000.tx_bufs[i] = try allocator.alloc(u8, 2048);
            @memset(e1000.tx_bufs[i], 0);
            e1000.tx_desc[i] = .{
                .addr = @intFromPtr(e1000.tx_bufs[i].ptr),
                .length = 0,
                .cso = 0,
                .cmd = 0,
                .status = 0,
                .css = 0,
                .special = 0,
            };
        }

        e1000.reset();
        return e1000;
    }

    fn readReg(self: *E1000, reg: u16) u32 {
        return self.mmio_base[reg / 4];
    }

    fn writeReg(self: *E1000, reg: u16, val: u32) void {
        self.mmio_base[reg / 4] = val;
    }

    pub fn reset(self: *E1000) void {
        self.writeReg(Regs.CTRL, self.readReg(Regs.CTRL) | (1 << 26));

        var i: u32 = 0;
        while (i < 10000) {
            if (self.readReg(Regs.CTRL) & (1 << 26) == 0) break;
            i += 1;
        }

        self.writeReg(Regs.CTRL, 0);

        self.writeReg(Regs.RCTRL, 0);

        self.writeReg(Regs.TCTRL, 0);

        self.writeReg(Regs.RDBAL, @as(u32, @truncate(@intFromPtr(self.rx_desc.ptr))));
        self.writeReg(Regs.RDBAH, @as(u32, @truncate(@intFromPtr(self.rx_desc.ptr) >> 32)));
        self.writeReg(Regs.RDLEN, E1000_NUM_RX_DESC * @sizeOf(RxDesc));
        self.writeReg(Regs.RDH, 0);
        self.writeReg(Regs.RDT, E1000_NUM_RX_DESC - 1);

        self.writeReg(Regs.TDBAL, @as(u32, @truncate(@intFromPtr(self.tx_desc.ptr))));
        self.writeReg(Regs.TDBAH, @as(u32, @truncate(@intFromPtr(self.tx_desc.ptr) >> 32)));
        self.writeReg(Regs.TDLEN, E1000_NUM_TX_DESC * @sizeOf(TxDesc));
        self.writeReg(Regs.TDH, 0);
        self.writeReg(Regs.TDT, 0);

        self.writeReg(Regs.RCTRL, (1 << 1) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 15));
        self.writeReg(Regs.TCTRL, (1 << 1) | (1 << 3) | (1 << 5) | (1 << 10) | (1 << 11));

        self.writeReg(Regs.RA, 0);
        self.writeReg(Regs.RA + 4, 0);

        self.writeReg(Regs.RCTRL, self.readReg(Regs.RCTRL) | 1);
        self.writeReg(Regs.TCTRL, self.readReg(Regs.TCTRL) | 1);
    }

    pub fn macAddress(self: *E1000) [6]u8 {
        var mac: [6]u8 = undefined;
        const lo = self.readReg(Regs.RA);
        const hi = self.readReg(Regs.RA + 4);
        std.mem.writeInt(u32, mac[0..4], lo, .little);
        std.mem.writeInt(u16, mac[4..6], @as(u16, @truncate(hi)), .little);
        return mac;
    }

    pub fn send(self: *E1000, data: []const u8) bool {
        if (data.len > 2048) return false;
        const idx = self.tx_cur % E1000_NUM_TX_DESC;
        @memcpy(self.tx_bufs[idx][0..data.len], data);
        self.tx_desc[idx].length = @as(u16, @intCast(data.len));
        self.tx_desc[idx].cmd = 0x0B;
        self.tx_desc[idx].status = 0;
        self.tx_cur += 1;
        self.writeReg(Regs.TDT, @as(u32, @intCast(self.tx_cur % E1000_NUM_TX_DESC)));
        return true;
    }

    pub fn receive(self: *E1000) ?[]u8 {
        const idx = self.rx_cur % E1000_NUM_RX_DESC;
        if (self.rx_desc[idx].status & 1 == 0) return null;
        const len = self.rx_desc[idx].length;
        self.rx_desc[idx].status = 0;
        self.rx_cur += 1;
        self.writeReg(Regs.RDT, @as(u32, @intCast((self.rx_cur - 1) % E1000_NUM_RX_DESC)));
        return self.rx_bufs[idx][0..len];
    }
};

test "e1000 init" {
    if (builtin.target.cpu.arch != .x86_64) return error.SkipZigTest;
    _ = E1000;
}
