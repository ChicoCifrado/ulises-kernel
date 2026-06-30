const std = @import("std");
const builtin = @import("builtin");
const pmm = @import("pmm.zig");

var base: [*]u8 = undefined;
var pos: usize = 0;
var size: usize = 0;
var initialized: bool = false;

fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    if (!initialized) return null;
    const align_bytes = alignment.toByteUnits();
    const aligned_pos = (pos + align_bytes - 1) & ~(align_bytes - 1);
    if (aligned_pos + len > size) return null;
    const p = base + aligned_pos;
    pos = aligned_pos + len;
    for (0..len) |i| p[i] = 0;
    return p;
}

fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false;
}

fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = ret_addr;
}

const vtable = std.mem.Allocator.VTable{
    .alloc = allocFn,
    .resize = resizeFn,
    .remap = remapFn,
    .free = freeFn,
};

const kernel_alloc = std.mem.Allocator{
    .ptr = @as(*anyopaque, @ptrCast(&base)),
    .vtable = &vtable,
};

pub fn get() std.mem.Allocator {
    if (builtin.target.os.tag == .freestanding) {
        return kernel_alloc;
    }
    return std.heap.page_allocator;
}

pub fn init(pmm_allocator: *pmm.PageAllocator, heap_size: usize) !void {
    const pages = (heap_size + 4095) / 4096;
    const first = pmm_allocator.allocPage() orelse return error.OutOfMemory;
    base = first;
    for (1..pages) |_| {
        _ = pmm_allocator.allocPage() orelse return error.OutOfMemory;
    }
    size = pages * 4096;
    pos = 0;
    initialized = true;
}
