const std = @import("std");
const builtin = @import("builtin");

pub const Arena = struct {
    base: [*]u8,
    size: usize,
    offset: usize,
    allocator: std.mem.Allocator,
    hugepages_fd: ?std.os.fd_t = null,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Arena {
        const page_size = if (builtin.target.cpu.arch == .x86_64) 2 * 1024 * 1024 else 2 * 1024 * 1024;
        const aligned_size = std.math.alignUp(size, page_size);

        var arena = Arena{
            .base = undefined,
            .size = aligned_size,
            .offset = 0,
            .allocator = allocator,
        };

        const flags = std.c.MAP_PRIVATE | std.c.MAP_ANONYMOUS | std.c.MAP_HUGETLB | std.c.MAP_POPULATE;
        const ptr = std.c.mmap(null, aligned_size, std.c.PROT_READ | std.c.PROT_WRITE, flags, -1, 0);
        if (ptr == std.c.MAP_FAILED) {
            return error.OutOfMemory;
        }
        arena.base = @ptrCast([*]u8, ptr);

        if (builtin.target.cpu.arch == .x86_64) {
            _ = std.c.madvise(ptr, aligned_size, std.c.MADV_HUGEPAGE);
        }

        return arena;
    }

    pub fn deinit(self: *Arena) void {
        if (self.base != undefined) {
            _ = std.c.munmap(self.base, self.size);
            self.base = undefined;
        }
    }

    pub fn alloc(self: *Arena, size: usize, align: usize) ![]u8 {
        const aligned_offset = std.math.alignUp(self.offset, align);
        if (aligned_offset + size > self.size) return error.OutOfMemory;
        const ptr = self.base[aligned_offset..][0..size];
        self.offset = aligned_offset + size;
        return ptr;
    }

    pub fn allocBytes(self: *Arena, size: usize) ![]u8 {
        return try self.alloc(size, 64);
    }

    pub fn reset(self: *Arena) void {
        self.offset = 0;
    }

    pub fn remaining(self: Arena) usize {
        return self.size - self.offset;
    }

    pub fn prefetch(self: Arena, offset: usize, size: usize) void {
        const ptr = self.base[offset..][0..size].ptr;
        if (builtin.target.cpu.arch == .x86_64) {
            _ = std.c.__builtin_prefetch(ptr, 0, 3);
        } else {
            _ = std.c.__builtin_prefetch(ptr, 0, 3);
        }
    }

    pub fn clflush(self: Arena, offset: usize, size: usize) void {
        const ptr = self.base[offset..][0..size].ptr;
        if (builtin.target.cpu.arch == .x86_64) {
            inline for (0..(size + 63) / 64) |i| {
                std.asm.volatile("clflushopt %0" : : "m" (ptr[i * 64]) : "memory");
            }
        } else {
            inline for (0..(size + 63) / 64) |i| {
                std.asm.volatile("dc cvau, %0" : : "r" (ptr + i * 64) : "memory");
            }
        }
    }
};