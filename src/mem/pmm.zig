const std = @import("std");
const builtin = @import("builtin");

pub const PageAllocator = struct {
    base: [*]u8,
    total_pages: usize,
    free_stack: []usize,
    free_count: usize,
    page_size: usize,

    pub fn init(base: [*]u8, total_bytes: usize, page_size: usize) PageAllocator {
        const total_pages = total_bytes / page_size;
        const stack_size = total_pages * @sizeOf(usize);
        const stack_base = @as([*]u8, @ptrCast(base))[total_bytes - stack_size ..][0..stack_size];
        const free_stack: []usize = @ptrCast(stack_base);

        const pa = PageAllocator{
            .base = base,
            .total_pages = total_pages,
            .free_stack = free_stack,
            .free_count = total_pages,
            .page_size = page_size,
        };

        for (0..total_pages) |i| {
            free_stack[total_pages - 1 - i] = i;
        }

        return pa;
    }

    pub fn allocPage(self: *PageAllocator) ?[*]u8 {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const page_idx = self.free_stack[self.free_count];
        return self.base + (page_idx * self.page_size);
    }

    pub fn freePage(self: *PageAllocator, page: [*]u8) void {
        const offset = @intFromPtr(page) - @intFromPtr(self.base);
        const page_idx = offset / self.page_size;
        self.free_stack[self.free_count] = page_idx;
        self.free_count += 1;
    }

    pub fn available(self: *const PageAllocator) usize {
        return self.free_count;
    }

    pub fn used(self: *const PageAllocator) usize {
        return self.total_pages - self.free_count;
    }
};

test "page allocator basic" {
    var mem: [4096 * 64]u8 = undefined;
    var pa = PageAllocator.init(&mem, mem.len, 4096);

    try std.testing.expectEqual(64, pa.available());
    const p1 = pa.allocPage().?;
    try std.testing.expectEqual(63, pa.available());
    pa.freePage(p1);
    try std.testing.expectEqual(64, pa.available());
}

test "page allocator exhaustion" {
    var mem: [4096 * 4]u8 = undefined;
    var pa = PageAllocator.init(&mem, mem.len, 4096);

    for (0..4) |_| {
        try std.testing.expect(pa.allocPage() != null);
    }
    try std.testing.expectEqual(pa.allocPage(), null);
}
