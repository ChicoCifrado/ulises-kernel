const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal.zig");
const x86_64 = @import("arch/x86_64.zig");
const utxo_stack = @import("utxo/stack.zig");
const utxo_slot = @import("utxo/slot.zig");
const arena = @import("mem/arena.zig");
const pmm = @import("mem/pmm.zig");
const primitives = @import("bsv/primitives.zig");
const bsv_hash = @import("bsv/hash.zig");
const scheduler = @import("agent/scheduler.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = addr;
    var h = hal.Hal.init();
    h.halt(.panic);
}

pub fn main() noreturn {
    var h = hal.Hal.init();

    initPlatform();

    const UTXO_SLOTS = 1_000_000;
    const SCRIPT_HEAP_SIZE = 64 * 1024 * 1024;

    var utxo = initUtxoStack(UTXO_SLOTS, SCRIPT_HEAP_SIZE) catch {
        h.halt(.panic);
    };

    var agent = initAgent(&utxo, &h);

    while (true) {
        if (agent.pendingCount() > 0) {
            agent.processN(64);
            h.dataSync();
        }
        h.waitForInterrupt();
    }
}

fn initPlatform() void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            x86_64.initCpu();
        },
        .aarch64, .arm => {},
        .riscv64 => {},
        else => {},
    }
}

fn initUtxoStack(num_slots: usize, script_heap_size: usize) !utxo_stack.UtxoStack {
    const allocator = std.heap.page_allocator;
    return try utxo_stack.UtxoStack.init(allocator, num_slots, script_heap_size);
}

fn initAgent(_: *utxo_stack.UtxoStack, h: *hal.Hal) scheduler.AgentScheduler {
    const allocator = std.heap.page_allocator;
    var sched = scheduler.AgentScheduler.init(allocator, @as(*anyopaque, @ptrCast(h)), @as(*const anyopaque, @ptrCast(h)));

    sched.registerTool(allocator, "balance", .{
        .name = "balance",
        .handler = struct {
            fn f(_: *anyopaque, _: []const u8) []const u8 {
                return "0";
            }
        }.f,
    }) catch {};

    sched.registerTool(allocator, "scan", .{
        .name = "scan",
        .handler = struct {
            fn f(_: *anyopaque, _: []const u8) []const u8 {
                return "ok";
            }
        }.f,
    }) catch {};

    return sched;
}

comptime {
    std.debug.assert(@sizeOf(utxo_slot.Slot) == 64);
    std.debug.assert(@sizeOf(primitives.OutPoint) == 36);
}

test "kernel integrity" {
    try std.testing.expectEqual(64, @sizeOf(utxo_slot.Slot));
    try std.testing.expectEqual(36, @sizeOf(primitives.OutPoint));
}

test "crypto works" {
    const hash = bsv_hash.doubleSha256("odysseus");
    try std.testing.expectEqual(32, hash.len);
}
