const std = @import("std");
const blockdev = @import("blockdev.zig");
const x86 = @import("../arch/x86_64.zig");

fn inw(port: u16) u16 {
    var val: u16 = undefined;
    asm volatile ("inw %[port], %[val]"
        : [val] "={ax}" (val)
        : [port] "{dx}" (port)
    );
    return val;
}

const ATA_PRIMARY_IO: u16 = 0x1F0;
const ATA_PRIMARY_CTRL: u16 = 0x3F6;

const ATA_REG_DATA: u16 = 0;
const ATA_REG_ERROR: u16 = 1;
const ATA_REG_SECCOUNT: u16 = 2;
const ATA_REG_LBA0: u16 = 3;
const ATA_REG_LBA1: u16 = 4;
const ATA_REG_LBA2: u16 = 5;
const ATA_REG_DRIVE: u16 = 6;
const ATA_REG_CMD: u16 = 7;
const ATA_REG_STATUS: u16 = 7;

const ATA_CMD_READ_PIO = 0x20;
const ATA_CMD_READ_PIO_EXT = 0x24;
const ATA_CMD_IDENTIFY = 0xEC;

const STATUS_BSY: u8 = 0x80;
const STATUS_DRDY: u8 = 0x40;
const STATUS_DRQ: u8 = 0x08;
const STATUS_ERR: u8 = 0x01;

fn waitBsy(io_base: u16) bool {
    var timeout: u32 = 1000000;
    while (x86.inb(io_base + ATA_REG_STATUS) & STATUS_BSY != 0) {
        timeout -= 1;
        if (timeout == 0) return false;
    }
    return true;
}

fn waitDrq(io_base: u16) bool {
    var timeout: u32 = 1000000;
    while (true) {
        const st = x86.inb(io_base + ATA_REG_STATUS);
        if (st & STATUS_ERR != 0) return false;
        if (st & STATUS_DRQ != 0) return true;
        timeout -= 1;
        if (timeout == 0) return false;
    }
}

pub const AtaBlockDev = struct {
    io_base: u16,
    ctrl_base: u16,
    slave: bool,
    block_size: usize = 512,
    total_blocks: usize = 0,
    lba48: bool = true,

    pub fn detect(io_base: u16, ctrl_base: u16, slave: bool) ?AtaBlockDev {
        const drive_val: u8 = if (slave) 0xB0 else 0xA0;
        x86.outb(io_base + ATA_REG_DRIVE, drive_val);

        if (!waitBsy(io_base)) return null;
        x86.outb(io_base + ATA_REG_CMD, ATA_CMD_IDENTIFY);
        if (x86.inb(io_base + ATA_REG_STATUS) == 0) return null;

        if (!waitBsy(io_base)) return null;
        if (!waitDrq(io_base)) return null;

        var data: [256]u16 = undefined;
        for (&data) |*word| {
            word.* = inw(io_base + ATA_REG_DATA);
        }

        const lba48_support = (data[83] & (1 << 10)) != 0;

        const total = if (lba48_support)
            @as(u64, data[100]) | (@as(u64, data[101]) << 16) | (@as(u64, data[102]) << 32) | (@as(u64, data[103]) << 48)
        else
            @as(u64, data[60]) | (@as(u64, data[61]) << 16);

        return AtaBlockDev{
            .io_base = io_base,
            .ctrl_base = ctrl_base,
            .slave = slave,
            .total_blocks = @as(usize, @intCast(total)),
            .lba48 = lba48_support,
        };
    }

    pub fn blockDev(self: *AtaBlockDev) blockdev.BlockDev {
        return .{
            .ptr = self,
            .vtable = &.{ .read = readFn },
            .block_size = self.block_size,
            .total_blocks = self.total_blocks,
        };
    }
};

fn readFn(ctx: *anyopaque, lba: u64, buffer: []u8) bool {
    const self: *AtaBlockDev = @ptrCast(@alignCast(ctx));
    if (buffer.len < 512) return false;

    if (!waitBsy(self.io_base)) return false;

    const drive_val: u8 = if (self.slave) 0xB0 else 0xA0;

    if (self.lba48) {
        x86.outb(self.io_base + ATA_REG_DRIVE, drive_val | 0x40);
        x86.outb(self.io_base + ATA_REG_SECCOUNT, 0);
        x86.outb(self.io_base + ATA_REG_LBA0, @as(u8, @truncate(lba >> 24)));
        x86.outb(self.io_base + ATA_REG_LBA1, @as(u8, @truncate(lba >> 32)));
        x86.outb(self.io_base + ATA_REG_LBA2, @as(u8, @truncate(lba >> 40)));
        x86.outb(self.io_base + ATA_REG_SECCOUNT, 1);
        x86.outb(self.io_base + ATA_REG_LBA0, @as(u8, @truncate(lba)));
        x86.outb(self.io_base + ATA_REG_LBA1, @as(u8, @truncate(lba >> 8)));
        x86.outb(self.io_base + ATA_REG_LBA2, @as(u8, @truncate(lba >> 16)));
        x86.outb(self.io_base + ATA_REG_CMD, ATA_CMD_READ_PIO_EXT);
    } else {
        x86.outb(self.io_base + ATA_REG_DRIVE, drive_val | @as(u8, @truncate((lba >> 24) & 0x0F)));
        x86.outb(self.io_base + ATA_REG_SECCOUNT, 1);
        x86.outb(self.io_base + ATA_REG_LBA0, @as(u8, @truncate(lba)));
        x86.outb(self.io_base + ATA_REG_LBA1, @as(u8, @truncate(lba >> 8)));
        x86.outb(self.io_base + ATA_REG_LBA2, @as(u8, @truncate(lba >> 16)));
        x86.outb(self.io_base + ATA_REG_CMD, ATA_CMD_READ_PIO);
    }

    if (!waitDrq(self.io_base)) return false;

    for (0..256) |i| {
        const word = inw(self.io_base + ATA_REG_DATA);
        buffer[i * 2] = @as(u8, @truncate(word));
        buffer[i * 2 + 1] = @as(u8, @truncate(word >> 8));
    }

    return true;
}
