const std = @import("std");
const builtin = @import("builtin");

export var mboot_info: u64 = 0;

export var kernel_stack: [32768]u8 align(16) = undefined;

pub export var pml4: [512]u64 align(4096) linksection(".early.data") = @splat(0);
export var pdpt: [512]u64 align(4096) linksection(".early.data") = @splat(0);
export var pd: [512]u64 align(4096) linksection(".early.data") = @splat(0);
pub export var pd_mmio: [512]u64 align(4096) linksection(".early.data") = @splat(0);

export var boot_gdt: [24]u8 align(8) = @splat(0);
export var boot_gdt_desc: [6]u8 = @splat(0);

pub const FramebufferInfo = struct {
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    type: u8, // 0=indexed, 1=RGB, 2=EGA text
};

pub fn getFramebufferInfo() ?FramebufferInfo {
    if (mboot_info == 0) return null;

    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(mboot_info)));
    // Multiboot2 info: total_size at offset 0, reserved at offset 4, then tags
    const total_size = @as(*const u32, @ptrFromInt(@intFromPtr(ptr))).*;
    var off: u32 = 8;

    while (off < total_size) {
        const tag_type = @as(*const u16, @ptrFromInt(@intFromPtr(ptr) + off + 0)).*;
        const tag_size = @as(*const u32, @ptrFromInt(@intFromPtr(ptr) + off + 4)).*;

        if (tag_type == 5) {
            // Framebuffer tag
            const addr = @as(*const u64, @ptrFromInt(@intFromPtr(ptr) + off + 8)).*;
            const pitch = @as(*const u32, @ptrFromInt(@intFromPtr(ptr) + off + 16)).*;
            const width = @as(*const u32, @ptrFromInt(@intFromPtr(ptr) + off + 20)).*;
            const height = @as(*const u32, @ptrFromInt(@intFromPtr(ptr) + off + 24)).*;
            const bpp = @as(*const u8, @ptrFromInt(@intFromPtr(ptr) + off + 28)).*;
            const fb_type = @as(*const u8, @ptrFromInt(@intFromPtr(ptr) + off + 29)).*;
            return FramebufferInfo{
                .addr = addr,
                .pitch = pitch,
                .width = width,
                .height = height,
                .bpp = bpp,
                .type = fb_type,
            };
        }

        if (tag_type == 0) break; // end tag
        off += tag_size;
        off = (off + 7) & ~@as(u32, 7); // align to 8 bytes
    }

    return null;
}
