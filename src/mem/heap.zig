const std = @import("std");
const builtin = @import("builtin");
const pmm = @import("pmm.zig");

pub const HeapAllocator = struct {
    base: [*]u8,
    pos: usize,
    size: usize,

    pub fn init(base: [*]u8, size: usize) HeapAllocator {
        return .{ .base = base, .pos = 0, .size = size };
    }

    pub fn allocator(self: *HeapAllocator) std.mem.Allocator {
        const vtable = std.mem.Allocator.VTable{
            .alloc = allocFn,
            .resize = resizeFn,
            .free = freeFn,
        };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const align_val = @as(usize, 1) << @as(usize, @intCast(ptr_align));
        const aligned_pos = (self.pos + align_val - 1) & ~(align_val - 1);
        if (aligned_pos + len > self.size) return null;
        const ptr = self.base + aligned_pos;
        self.pos = aligned_pos + len;
        return ptr;
    }

    fn resizeFn(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn freeFn(_: *anyopaque, _: []u8, _: u8, _: usize) void {}

    pub fn reset(self: *HeapAllocator) void {
        self.pos = 0;
    }
};

pub fn bootstrap(pmm_allocator: *pmm.PageAllocator, heap_size: usize) !HeapAllocator {
    const pages = (heap_size + 4095) / 4096;
    const base = pmm_allocator.allocPage() orelse return error.OutOfMemory;
    for (1..pages) |_| {
        _ = pmm_allocator.allocPage() orelse return error.OutOfMemory;
    }
    return HeapAllocator.init(base, pages * 4096);
}
