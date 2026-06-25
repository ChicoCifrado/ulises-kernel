const std = @import("std");
const builtin = @import("builtin");

pub const CacheLine = 64;

pub const HaltReason = enum(u8) {
    shutdown = 0,
    panic = 1,
    hcf = 2,
};

pub const Hal = struct {
    pub fn init() Hal {
        return .{};
    }

    pub fn halt(_: *Hal, reason: HaltReason) noreturn {
        _ = reason;
        while (true) {
            switch (builtin.target.cpu.arch) {
                .x86_64 => asm volatile ("cli; hlt"),
                .aarch64, .arm, .armeb => asm volatile ("wfi"),
                .riscv64 => asm volatile ("wfi"),
                .thumb, .thumbeb => asm volatile ("wfi"),
                else => {},
            }
        }
    }

    pub fn waitForInterrupt(_: *Hal) void {
        switch (builtin.target.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64, .arm, .armeb => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            .thumb, .thumbeb => asm volatile ("wfi"),
            else => {},
        }
    }

    pub fn readCycleCounter(_: *Hal) u64 {
        switch (builtin.target.cpu.arch) {
            .x86_64 => {
                var lo: u32 = undefined;
                var hi: u32 = undefined;
                asm volatile ("rdtsc" : [lo] "={eax}" (lo), [hi] "={edx}" (hi));
                return (@as(u64, hi) << 32) | lo;
            },
            .aarch64, .arm, .armeb => {
                var val: u64 = undefined;
                asm volatile ("mrs %[v], cntpct_el0" : [v] "=r" (val));
                return val;
            },
            .riscv64 => {
                var val: u64 = undefined;
                asm volatile ("rdcycle %[v]" : [v] "=r" (val));
                return val;
            },
            else => 0,
        }
    }

    pub fn spinHint(_: *Hal) void {
        switch (builtin.target.cpu.arch) {
            .x86_64 => asm volatile ("pause"),
            .aarch64, .arm, .armeb => asm volatile ("yield"),
            .riscv64 => asm volatile ("fence"),
            else => {},
        }
    }

    pub fn dataSync(_: *Hal) void {
        switch (builtin.target.cpu.arch) {
            .x86_64 => asm volatile ("mfence"),
            .aarch64, .arm, .armeb => asm volatile ("dsb sy"),
            .riscv64 => asm volatile ("fence iorw, iorw"),
            else => {},
        }
    }

    pub fn prefetch(_: *Hal, _: [*]const u8) void {
    }
};

test "hal init" {
    const h = Hal.init();
    _ = h;
}

test "cycle counter" {
    var h = Hal.init();
    const a = h.readCycleCounter();
    try std.testing.expect(a > 0);
}
