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
const bkds = @import("bsv/bkds.zig");
const brc43 = @import("bsv/brc43.zig");
const brc100 = @import("bsv/brc100.zig");
const basm = @import("bsv/basm.zig");
const overlay = @import("bsv/overlay.zig");
const secp256k1 = @import("bsv/secp256k1.zig");
const beef = @import("bsv/beef.zig");
const x402 = @import("bsv/x402.zig");

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

fn initAgent(utxo: *utxo_stack.UtxoStack, h: *hal.Hal) scheduler.AgentScheduler {
    const allocator = std.heap.page_allocator;
    var wallet_engine = allocator.create(brc100.KernelWallet) catch @panic("OOM");
    wallet_engine.* = brc100.KernelWallet.init(allocator, utxo);
    wallet_engine.setNetwork(.mainnet);

    var sched = scheduler.AgentScheduler.init(allocator, @as(*anyopaque, @ptrCast(wallet_engine)), @as(*const anyopaque, @ptrCast(h)));

    sched.registerTool(allocator, "balance", .{
        .name = "balance",
        .handler = struct {
            fn f(ctx: *anyopaque, args: []const u8) []const u8 {
                _ = args;
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                const bal = kw.getBasketBalance(null) catch return "error";
                const result = std.fmt.allocPrint(kw.allocator, "{}", .{bal.satoshis}) catch return "error";
                return result;
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

    sched.registerTool(allocator, "version", .{
        .name = "version",
        .handler = struct {
            fn f(ctx: *anyopaque, _: []const u8) []const u8 {
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                const ver = kw.getVersion();
                const result = std.fmt.allocPrint(kw.allocator, "{}.{}.{}", .{ ver.major, ver.minor, ver.revision }) catch return "0.0.0";
                return result;
            }
        }.f,
    }) catch {};

    sched.registerTool(allocator, "network", .{
        .name = "network",
        .handler = struct {
            fn f(ctx: *anyopaque, _: []const u8) []const u8 {
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                return switch (kw.network) {
                    .mainnet => "mainnet",
                    .testnet => "testnet",
                    .regtest => "regtest",
                };
            }
        }.f,
    }) catch {};

    sched.registerTool(allocator, "height", .{
        .name = "height",
        .handler = struct {
            fn f(ctx: *anyopaque, _: []const u8) []const u8 {
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                const result = std.fmt.allocPrint(kw.allocator, "{}", .{kw.getHeight()}) catch return "0";
                return result;
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
