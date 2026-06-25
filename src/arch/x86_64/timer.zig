const std = @import("std");
const x86_64 = @import("../x86_64.zig");
const idt_mod = @import("idt.zig");
const smp = @import("../smp.zig");

const PIT_BASE_FREQ = 1_193_182;
const TICK_HZ = 100;

export var timer_ticks: u64 = 0;

pub fn init(callback: *const fn (*const idt_mod.InterruptFrame) callconv(.C) void) void {
    _ = callback;
    const divisor: u16 = @intCast(PIT_BASE_FREQ / TICK_HZ);
    x86_64.outb(0x43, 0x34);
    x86_64.outb(0x40, @as(u8, @truncate(divisor)));
    x86_64.outb(0x40, @as(u8, @truncate(divisor >> 8)));
    smp.ioapicRedirectIrq(0, 0x20, 0);
}

pub fn eoi() void {
    const LAPIC_EOI: u32 = 0xB0;
    const lapic_base = smp.getLapicBase();
    @as([*]volatile u32, @ptrFromInt(lapic_base + LAPIC_EOI))[0] = 0;
}

pub fn handler(frame: *const idt_mod.InterruptFrame) callconv(.C) void {
    _ = frame;
    timer_ticks += 1;
    eoi();
}

pub fn getTicks() u64 {
    return timer_ticks;
}
