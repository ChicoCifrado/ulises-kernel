const std = @import("std");
const builtin = @import("builtin");
const blockdev = @import("blockdev.zig");
const pci = @import("../hal/pci.zig");
const pmm = @import("../mem/pmm.zig");

const ATA_CMD_IDENTIFY: u8 = 0xEC;
const ATA_CMD_READ_DMA_EXT: u8 = 0x25;

const PORT_CMD_ST: u32 = 1 << 0;
const PORT_CMD_SUD: u32 = 1 << 1;
const PORT_CMD_POD: u32 = 1 << 2;
const PORT_CMD_FRE: u32 = 1 << 4;
const PORT_CMD_CR: u32 = 1 << 15;
const PORT_CMD_FR: u32 = 1 << 14;

const PORT_IS_DHRS: u32 = 1 << 0;

const SSTS_DET_MASK: u32 = 0x0F;
const SSTS_DET_ESTABLISHED: u32 = 0x03;

const GHC_HR: u32 = 1 << 0;
const GHC_AE: u32 = 1 << 31;

const PORT_SIG_ATA: u32 = 0x00000101;
const MAX_PORTS: usize = 32;

pub const AhciBlockDev = struct {
    abar: usize,
    port: usize,
    page_alloc: *pmm.PageAllocator,
    clb_phys: u32,
    ct_phys: u32,
    clb_page: [*]u8,
    ct_page: [*]u8,
    block_size: usize = 512,
    total_blocks: usize = 0,

    pub fn detect(allocator: *pmm.PageAllocator) ?AhciBlockDev {
        var found_bus: u8 = 0;
        var found_dev: u8 = 0;
        var found_abar: u64 = 0;
        var found = false;

        for (0..256) |bus| {
            for (0..32) |d| {
                const b: u8 = @truncate(bus);
                const vendor = pci.pciConfigReadC(b, @as(u8, @truncate(d)), 0, 0);
                if (vendor == 0xFFFFFFFF) continue;
                const class_reg = pci.pciConfigReadC(b, @as(u8, @truncate(d)), 0, 8);
                const cc = @as(u8, @truncate(class_reg >> 24));
                const sc = @as(u8, @truncate(class_reg >> 16));
                const pi = @as(u8, @truncate(class_reg >> 8));
                if (cc == 0x01 and sc == 0x06 and pi == 0x01) {
                    const low = pci.pciConfigReadC(b, @as(u8, @truncate(d)), 0, 0x24);
                    const high = pci.pciConfigReadC(b, @as(u8, @truncate(d)), 0, 0x28);
                    const abar_val = @as(u64, low & 0xFFFFFFF0) | (@as(u64, high) << 32);
                    if (abar_val != 0) {
                        found_bus = b;
                        found_dev = @as(u8, @truncate(d));
                        found_abar = abar_val;
                        found = true;
                        break;
                    }
                }
            }
            if (found) break;
        }
        if (!found) return null;

        const cmd_reg = pci.pciConfigReadC(found_bus, found_dev, 0, 0x04);
        pci.pciConfigWriteC(found_bus, found_dev, 0, 0x04, cmd_reg | 0x06);

        const abar: usize = @intCast(found_abar);
        {
            const ghc = mmioRead32(abar + 0x04);
            if (ghc & GHC_HR != 0) {
                if (!waitClear(abar + 0x04, GHC_HR, 1000000)) return null;
            }
            mmioWrite32(abar + 0x04, ghc | GHC_AE);
        }

        const pi_val = mmioRead32(abar + 0x0C);
        var port: usize = 0;
        var found_port = false;
        while (port < MAX_PORTS) : (port += 1) {
            if (pi_val & (@as(u32, 1) << @intCast(port)) == 0) continue;
            const ssts = mmioRead32(abar + 0x100 + port * 0x80 + 0x28);
            if (ssts & SSTS_DET_MASK != SSTS_DET_ESTABLISHED) continue;
            const sig = mmioRead32(abar + 0x100 + port * 0x80 + 0x24);
            if (sig != PORT_SIG_ATA) continue;
            found_port = true;
            break;
        }
        if (!found_port) return null;

        {
            const cmd = mmioRead32(abar + 0x100 + port * 0x80 + 0x18);
            if (cmd & PORT_CMD_CR != 0) {
                mmioWrite32(abar + 0x100 + port * 0x80 + 0x18, cmd & ~PORT_CMD_ST);
                if (!waitClear(abar + 0x100 + port * 0x80 + 0x18, PORT_CMD_CR, 1000000)) return null;
            }
        }

        {
            const cmd = mmioRead32(abar + 0x100 + port * 0x80 + 0x18);
            if (cmd & PORT_CMD_FR != 0) {
                mmioWrite32(abar + 0x100 + port * 0x80 + 0x18, cmd & ~PORT_CMD_FRE);
                if (!waitClear(abar + 0x100 + port * 0x80 + 0x18, PORT_CMD_FR, 1000000)) return null;
            }
        }

        const clb_page = allocator.allocPage() orelse return null;
        const ct_page = allocator.allocPage() orelse return null;

        @memset(clb_page[0..4096], 0);
        @memset(ct_page[0..4096], 0);

        const clb_phys = @as(u32, @intCast(@intFromPtr(clb_page)));
        const fis_phys = @as(u32, @intCast(@intFromPtr(ct_page) + 2048));
        const ct_phys = @as(u32, @intCast(@intFromPtr(ct_page)));

        mmioWrite32(abar + 0x100 + port * 0x80 + 0x00, clb_phys);
        mmioWrite32(abar + 0x100 + port * 0x80 + 0x04, 0);
        mmioWrite32(abar + 0x100 + port * 0x80 + 0x08, fis_phys);
        mmioWrite32(abar + 0x100 + port * 0x80 + 0x0C, 0);

        mmioWrite32(abar + 0x100 + port * 0x80 + 0x14, 0);
        mmioWrite32(abar + 0x100 + port * 0x80 + 0x30, mmioRead32(abar + 0x100 + port * 0x80 + 0x30));

        mmioWrite32(abar + 0x100 + port * 0x80 + 0x18, PORT_CMD_SUD | PORT_CMD_POD);
        for (0..100000) |_| {
            if (mmioRead32(abar + 0x100 + port * 0x80 + 0x28) & SSTS_DET_MASK == SSTS_DET_ESTABLISHED) break;
        }

        mmioWrite32(abar + 0x100 + port * 0x80 + 0x18, PORT_CMD_SUD | PORT_CMD_POD | PORT_CMD_FRE | PORT_CMD_ST);
        if (!waitSet(abar + 0x100 + port * 0x80 + 0x18, PORT_CMD_CR, 1000000)) return null;

        var dev = AhciBlockDev{
            .abar = abar,
            .port = port,
            .page_alloc = allocator,
            .clb_phys = clb_phys,
            .ct_phys = ct_phys,
            .clb_page = clb_page,
            .ct_page = ct_page,
        };

        if (!dev.identify()) return null;
        return dev;
    }

    fn portReg(self: *AhciBlockDev, offset: usize) *volatile u32 {
        return @as(*volatile u32, @ptrFromInt(self.abar + 0x100 + self.port * 0x80 + offset));
    }

    fn identify(self: *AhciBlockDev) bool {
        var data_buf: [512]u8 align(2) = undefined;
        @memset(&data_buf, 0);

        @memset(self.ct_page[0..256], 0);

        physWrite32(@intFromPtr(self.ct_page) + 0, @as(u32, 0x27) | (@as(u32, 0x80) << 8) | (@as(u32, ATA_CMD_IDENTIFY) << 16));
        physWrite32(@intFromPtr(self.ct_page) + 4, 0x40 << 24);
        physWrite32(@intFromPtr(self.ct_page) + 12, 0);

        physWrite32(@intFromPtr(self.ct_page) + 0x80 + 0, @as(u32, @intCast(@intFromPtr(&data_buf))));
        physWrite32(@intFromPtr(self.ct_page) + 0x80 + 4, 0);
        physWrite32(@intFromPtr(self.ct_page) + 0x80 + 8, 0);
        physWrite32(@intFromPtr(self.ct_page) + 0x80 + 12, (512 - 1) | (1 << 31));

        physWrite32(@intFromPtr(self.clb_page) + 0, 0 | (1 << 21) | (5 << 27));
        physWrite32(@intFromPtr(self.clb_page) + 4, 0);
        physWrite32(@intFromPtr(self.clb_page) + 8, self.ct_phys);
        physWrite32(@intFromPtr(self.clb_page) + 12, 0);

        if (!self.issueCommand()) return false;

        const data = @as(*const [256]u16, @ptrCast(@alignCast(&data_buf)));
        const lba48 = (data[83] & (1 << 10)) != 0;
        self.total_blocks = if (lba48)
            @as(usize, @intCast(@as(u64, data[100]) | (@as(u64, data[101]) << 16) | (@as(u64, data[102]) << 32) | (@as(u64, data[103]) << 48)))
        else
            @as(usize, @intCast(@as(u64, data[60]) | (@as(u64, data[61]) << 16)));
        return true;
    }

    fn issueCommand(self: *AhciBlockDev) bool {
        self.portReg(0x38).* = 1;
        if (!waitClear(@intFromPtr(self.portReg(0x38)), 1, 10000000)) return false;
        const is_val = self.portReg(0x10).*;
        self.portReg(0x10).* = is_val;
        if (is_val & PORT_IS_DHRS == 0) return false;
        return self.portReg(0x20).* & 0x01 == 0;
    }

    pub fn blockDev(self: *AhciBlockDev) blockdev.BlockDev {
        return .{
            .ptr = self,
            .vtable = &.{ .read = readFn },
            .block_size = self.block_size,
            .total_blocks = self.total_blocks,
        };
    }
};

fn mmioRead32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn mmioWrite32(addr: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

fn physWrite32(addr: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

fn waitClear(addr: usize, mask: u32, timeout: u32) bool {
    var t = timeout;
    while (mmioRead32(addr) & mask != 0) {
        t -|= 1;
        if (t == 0) return false;
    }
    return true;
}

fn waitSet(addr: usize, mask: u32, timeout: u32) bool {
    var t = timeout;
    while (mmioRead32(addr) & mask == 0) {
        t -|= 1;
        if (t == 0) return false;
    }
    return true;
}

fn readFn(ctx: *anyopaque, lba: u64, buffer: []u8) bool {
    const self: *AhciBlockDev = @ptrCast(@alignCast(ctx));
    if (buffer.len < 512) return false;

    const buf_phys = @as(u32, @intCast(@intFromPtr(buffer.ptr)));

    @memset(self.ct_page[0..256], 0);

    physWrite32(@intFromPtr(self.ct_page) + 0, @as(u32, 0x27) | (@as(u32, 0x80) << 8) | (@as(u32, ATA_CMD_READ_DMA_EXT) << 16));
    physWrite32(@intFromPtr(self.ct_page) + 4, @as(u32, @truncate(lba)) | (@as(u32, @truncate(lba >> 8)) << 8) | (@as(u32, @truncate(lba >> 16)) << 16) | (@as(u32, 0x40) << 24));
    physWrite32(@intFromPtr(self.ct_page) + 8, (@as(u32, @truncate(lba >> 24))) | (@as(u32, @truncate(lba >> 32)) << 8) | (@as(u32, @truncate(lba >> 40)) << 16));
    physWrite32(@intFromPtr(self.ct_page) + 12, 1);

    physWrite32(@intFromPtr(self.ct_page) + 0x80 + 0, buf_phys);
    physWrite32(@intFromPtr(self.ct_page) + 0x80 + 4, 0);
    physWrite32(@intFromPtr(self.ct_page) + 0x80 + 8, 0);
    physWrite32(@intFromPtr(self.ct_page) + 0x80 + 12, (512 - 1) | (1 << 31));

    physWrite32(@intFromPtr(self.clb_page) + 0, 0 | (1 << 21) | (5 << 27));
    physWrite32(@intFromPtr(self.clb_page) + 4, 0);
    physWrite32(@intFromPtr(self.clb_page) + 8, self.ct_phys);
    physWrite32(@intFromPtr(self.clb_page) + 12, 0);

    return self.issueCommand();
}
