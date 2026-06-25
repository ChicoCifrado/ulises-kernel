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
    bar1: u32,
    irq: u8,
};

fn inl(port: u16) u32 {
    var val: u32 = undefined;
    asm volatile ("inl %[port], %[val]"
        : [val] "={eax}" (val),
        : [port] "N{dx}" (port),
    );
    return val;
}

fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "N{dx}" (port),
    );
}

fn pciConfigRead(bus: u8, device: u8, func: u8, offset: u8) u32 {
    const addr = @as(u32, 0x80000000) |
        (@as(u32, bus) << 16) |
        (@as(u32, device) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
    outl(CONFIG_ADDR, addr);
    return inl(CONFIG_DATA);
}

pub fn enumerate(allocator: std.mem.Allocator) ![]PciDevice {
    var devices = std.ArrayList(PciDevice).init(allocator);
    errdefer devices.deinit();

    for (0..256) |bus| {
        for (0..32) |dev| {
            const vendor = pciConfigRead(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0);
            if (vendor == 0xFFFFFFFF) continue;

            const class_reg = pciConfigRead(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 8);
            const bar0 = pciConfigRead(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0x10);
            const irq_reg = pciConfigRead(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0x3C);

            try devices.append(.{
                .bus = @as(u8, @intCast(bus)),
                .device = @as(u8, @intCast(dev)),
                .func = 0,
                .vendor_id = @as(u16, @truncate(vendor)),
                .device_id = @as(u16, @truncate(vendor >> 16)),
                .class_code = @as(u8, @truncate(class_reg >> 24)),
                .subclass = @as(u8, @truncate(class_reg >> 16)),
                .prog_if = @as(u8, @truncate(class_reg >> 8)),
                .bar0 = bar0,
                .bar1 = pciConfigRead(@as(u8, @intCast(bus)), @as(u8, @intCast(dev)), 0, 0x14),
                .irq = @as(u8, @truncate(irq_reg)),
            });
        }
    }
    return devices.toOwnedSlice();
}

test "pci enum" {
    if (builtin.target.cpu.arch != .x86_64) return error.SkipZigTest;
    const devices = try enumerate(std.testing.allocator);
    defer std.testing.allocator.free(devices);
    try std.testing.expect(devices.len > 0);
}
