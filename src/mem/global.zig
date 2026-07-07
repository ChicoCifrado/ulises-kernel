const std = @import("std");
const builtin = @import("builtin");
const pmm = @import("pmm.zig");

var base: [*]u8 = undefined;
var pos: usize = 0;
var size: usize = 0;
var initialized: bool = false;

const MAX_FREE_SLOTS = 64;
var free_ptr: [MAX_FREE_SLOTS][*]u8 = undefined;
var free_len: [MAX_FREE_SLOTS]usize = undefined;
var free_count: usize = 0;

fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    if (!initialized) return null;
    const align_bytes = alignment.toByteUnits();

    // Check free stack LIFO for a suitable block (must match both size and alignment)
    var i: usize = free_count;
    while (i > 0) {
        i -= 1;
        const f_ptr = free_ptr[i];
        const f_len = free_len[i];
        if (f_len >= len and @intFromPtr(f_ptr) & (align_bytes - 1) == 0) {
            // Remove from free list
            if (i + 1 < free_count) {
                free_ptr[i] = free_ptr[free_count - 1];
                free_len[i] = free_len[free_count - 1];
            }
            free_count -= 1;
            @memset(f_ptr[0..len], 0);
            return f_ptr;
        }
    }

    // Bump allocate
    const unaligned = @intFromPtr(base + pos);
    const aligned = (unaligned + align_bytes - 1) & ~(align_bytes - 1);
    const aligned_pos = aligned - @intFromPtr(base);
    if (aligned_pos + len > size) return null;
    const p = base + aligned_pos;
    pos = aligned_pos + len;
    @memset(p[0..len], 0);
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
    _ = alignment;
    _ = ret_addr;

    // If the freed block is at the top of the bump, just rewind
    const block_end = @intFromPtr(memory.ptr) + memory.len;
    const bump_top = @intFromPtr(base) + pos;
    if (block_end == bump_top) {
        pos -= memory.len;
        return;
    }

    // Otherwise push to free stack (LIFO)
    if (free_count < MAX_FREE_SLOTS) {
        free_ptr[free_count] = memory.ptr;
        free_len[free_count] = memory.len;
        free_count += 1;
    }
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
