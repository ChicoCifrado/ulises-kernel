const std = @import("std");
const builtin = @import("builtin");

const CONFIG_ADDR: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

pub const PciDevice = struct {
    bus: u8,
    device: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    bar0: u32,
    bar0_upper: u32,
    bar1: u32,
    bar1_upper: u32,
    irq: u8,
    bar0_is_64bit: bool,
};

extern fn pciConfigReadC(bus: u8, device: u8, func: u8, offset: u8) u32;

const log = @import("logger.zig");

pub const mapMmioBars = if (builtin.target.cpu.arch == .x86_64) struct {
    pub fn f(page_alloc: anytype) void {
        const x86_64 = @import("../arch/x86_64.zig");
        x86_64.cli();
        defer x86_64.sti();
        for (0..256) |bus| {
            for (0..32) |dev| {
                const b: u8 = @truncate(bus);
                const d: u8 = @truncate(dev);
                const vendor = pciConfigReadC(b, d, 0, 0);
                if (vendor == 0xFFFFFFFF) continue;
                var bar_offs: u32 = 0x10;
                while (bar_offs <= 0x24) {
                    const bar = pciConfigReadC(b, d, 0, @as(u8, @truncate(bar_offs)));
                    const is_mmio = bar & 1 == 0 and bar != 0;
                    const is_64bit = (bar >> 1) & 0x03 == 2;
                    if (is_mmio) {
                        var phys: u64 = bar & 0xFFFFFFF0;
                        if (is_64bit) {
                            const upper = pciConfigReadC(b, d, 0, @as(u8, @truncate(bar_offs + 4)));
                            phys |= @as(u64, upper) << 32;
                        }
                        if (phys >= 0xC0000000) {
                            x86_64.mapMmioRegion(phys, 4096, page_alloc);
                        }
                    }
                    bar_offs += 4;
                    if (is_64bit) bar_offs += 4;
                }
            }
        }
    }
}.f else struct {
    pub fn f(_: anytype) void {}
}.f;

pub const enumerate = if (builtin.target.cpu.arch == .x86_64) struct {
    pub fn f(allocator: std.mem.Allocator) ![]PciDevice {
        const x86_64 = @import("../arch/x86_64.zig");
        var devices: std.ArrayList(PciDevice) = .empty;
        errdefer devices.deinit(allocator);
        x86_64.cli();
        defer x86_64.sti();

        for (0..256) |bus| {
            for (0..32) |dev| {
                const vendor = pciConfigReadC(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0);
                if (vendor == 0xFFFFFFFF) continue;

                const class_reg = pciConfigReadC(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 8);
                const bar0_raw = pciConfigReadC(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0x10);
                const bar0_is_64bit = bar0_raw != 0 and (bar0_raw >> 1) & 0x03 == 2;
                const bar0_upper = if (bar0_is_64bit)
                    pciConfigReadC(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0x14)
                else
                    0;
                const irq_reg = pciConfigReadC(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0x3C);

                try devices.append(allocator, .{
                    .bus = @as(u8, @intCast(bus)),
                    .device = @as(u8, @intCast(dev)),
                    .func = 0,
                    .vendor_id = @as(u16, @truncate(vendor)),
                    .device_id = @as(u16, @truncate(vendor >> 16)),
                    .class_code = @as(u8, @truncate(class_reg >> 24)),
                    .subclass = @as(u8, @truncate(class_reg >> 16)),
                    .prog_if = @as(u8, @truncate(class_reg >> 8)),
                    .bar0 = bar0_raw,
                    .bar0_upper = bar0_upper,
                    .bar1 = if (bar0_is_64bit) 0 else pciConfigReadC(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0x14),
                    .bar1_upper = 0,
                    .irq = @as(u8, @truncate(irq_reg)),
                    .bar0_is_64bit = bar0_is_64bit,
                });
            }
        }
        return devices.toOwnedSlice(allocator);
    }
}.f else struct {
    pub fn f(_: std.mem.Allocator) ![]PciDevice {
        return &[0]PciDevice{};
    }
}.f;

test "pci enum" {
    if (builtin.target.cpu.arch != .x86_64) return error.SkipZigTest;
    const devices = try enumerate(std.testing.allocator);
    defer std.testing.allocator.free(devices);
    try std.testing.expect(devices.len > 0);
}
