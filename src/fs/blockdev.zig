const std = @import("std");

pub const BlockDev = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    block_size: usize,
    total_blocks: usize,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, lba: u64, buffer: []u8) bool,
        write: *const fn (ctx: *anyopaque, lba: u64, buffer: []const u8) bool,
    };

    pub fn read(self: *BlockDev, lba: u64, buffer: []u8) bool {
        if (buffer.len < self.block_size) return false;
        return self.vtable.read(self.ptr, lba, buffer);
    }

    pub fn write(self: *BlockDev, lba: u64, buffer: []const u8) bool {
        if (buffer.len < self.block_size) return false;
        return self.vtable.write(self.ptr, lba, buffer);
    }

    pub fn readExact(self: *BlockDev, lba: u64, buffer: []u8) bool {
        const blocks = (buffer.len + self.block_size - 1) / self.block_size;
        var offset: usize = 0;
        var current_lba = lba;
        for (0..blocks) |_| {
            if (!self.read(current_lba, buffer[offset..][0..self.block_size])) return false;
            offset += self.block_size;
            current_lba += 1;
        }
        return true;
    }

    pub fn writeExact(self: *BlockDev, lba: u64, buffer: []const u8) bool {
        const blocks = (buffer.len + self.block_size - 1) / self.block_size;
        var offset: usize = 0;
        var current_lba = lba;
        for (0..blocks) |_| {
            if (!self.write(current_lba, buffer[offset..][0..self.block_size])) return false;
            offset += self.block_size;
            current_lba += 1;
        }
        return true;
    }
};

pub const MemBlockDev = struct {
    data: []u8,
    block_size: usize,

    pub fn init(data: []u8, block_size: usize) MemBlockDev {
        return .{ .data = data, .block_size = block_size };
    }

    pub fn blockDev(self: *MemBlockDev) BlockDev {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readFn,
                .write = writeFn,
            },
            .block_size = self.block_size,
            .total_blocks = self.data.len / self.block_size,
        };
    }

    fn readFn(ctx: *anyopaque, lba: u64, buffer: []u8) bool {
        const self: *MemBlockDev = @ptrCast(@alignCast(ctx));
        const byte_off = lba * self.block_size;
        if (byte_off + self.block_size > self.data.len) return false;
        @memcpy(buffer[0..self.block_size], self.data[byte_off..][0..self.block_size]);
        return true;
    }

    fn writeFn(ctx: *anyopaque, lba: u64, buffer: []const u8) bool {
        const self: *MemBlockDev = @ptrCast(@alignCast(ctx));
        const byte_off = lba * self.block_size;
        if (byte_off + self.block_size > self.data.len) return false;
        @memcpy(self.data[byte_off..][0..self.block_size], buffer[0..self.block_size]);
        return true;
    }
};

pub const SubBlockDev = struct {
    parent: *BlockDev,
    start_lba: u64,

    pub fn init(parent: *BlockDev, start_lba: u64) SubBlockDev {
        return .{ .parent = parent, .start_lba = start_lba };
    }

    pub fn blockDev(self: *SubBlockDev) BlockDev {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readFn,
                .write = writeFn,
            },
            .block_size = self.parent.block_size,
            .total_blocks = self.parent.total_blocks - self.start_lba,
        };
    }

    fn readFn(ctx: *anyopaque, lba: u64, buffer: []u8) bool {
        const self: *SubBlockDev = @ptrCast(@alignCast(ctx));
        return self.parent.read(self.start_lba + lba, buffer);
    }

    fn writeFn(ctx: *anyopaque, lba: u64, buffer: []const u8) bool {
        const self: *SubBlockDev = @ptrCast(@alignCast(ctx));
        return self.parent.write(self.start_lba + lba, buffer);
    }
};
