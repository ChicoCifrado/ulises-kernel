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
