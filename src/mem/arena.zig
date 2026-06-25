const std = @import("std");
const builtin = @import("builtin");

pub const Arena = struct {
    base: [*]u8,
    size: usize,
    offset: usize,

    pub fn init(size: usize) !Arena {
        const page_size = 2 * 1024 * 1024;
        const aligned_size = std.mem.alignForward(u64, size, page_size);

        var arena = Arena{
            .base = undefined,
            .size = aligned_size,
            .offset = 0,
        };

        const ptr = std.c.mmap(
            null,
            aligned_size,
            std.c.PROT.READ | std.c.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        if (std.c.toInt(ptr) == -1) return error.ArenaInitFailed;
        arena.base = @ptrCast(ptr);
        return arena;
    }

    pub fn deinit(self: *Arena) void {
        if (self.base != undefined) {
            _ = std.c.munmap(self.base, self.size);
            self.base = undefined;
        }
    }

    pub fn alloc(self: *Arena, size: usize, alignment: usize) ![]u8 {
        const aligned_offset = std.mem.alignForward(u64, self.offset, alignment);
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

    pub fn remaining(self: *const Arena) usize {
        return self.size - self.offset;
    }

    pub fn slice(self: *const Arena) []u8 {
        return self.base[0..self.size];
    }
};

test "arena basic allocation" {
    var arena = try Arena.init(2 * 1024 * 1024);
    defer arena.deinit();

    const a = try arena.alloc(64, 64);
    try std.testing.expectEqual(64, a.len);
    try std.testing.expect(@intFromPtr(a.ptr) % 64 == 0);

    const b = try arena.alloc(128, 64);
    try std.testing.expectEqual(128, b.len);
}

test "arena remaining" {
    var arena = try Arena.init(2 * 1024 * 1024);
    defer arena.deinit();

    const initial = arena.remaining();
    _ = try arena.alloc(1024, 64);
    try std.testing.expect(arena.remaining() < initial);
}

test "arena reset" {
    var arena = try Arena.init(2 * 1024 * 1024);
    defer arena.deinit();

    _ = try arena.alloc(1024, 64);
    arena.reset();
    try std.testing.expectEqual(arena.remaining(), 2 * 1024 * 1024);
}
