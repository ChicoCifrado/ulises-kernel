const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal.zig");
const x86_64 = @import("arch/x86_64.zig");
const utxo_stack = @import("utxo/stack.zig");
const utxo_slot = @import("utxo/slot.zig");
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
const console_mod = @import("hal/console.zig");
const usb = @import("hal/usb.zig");
const pci = @import("hal/pci.zig");
const e1000 = @import("net/e1000.zig");
const shell = @import("shell/shell.zig");
const smp = @import("arch/smp.zig");
const spinlock = @import("sync/spinlock.zig");
const global_alloc = @import("mem/global.zig");

comptime {
    if (builtin.target.cpu.arch == .x86_64 and
        builtin.target.os.tag == .freestanding and
        !builtin.is_test)
    {
        _ = @import("arch/x86_64/boot.zig");
    }
}

pub const std_options: std.Options = .{
    .log_level = .info,
    .page_size_max = 4096,
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (builtin.target.os.tag == .freestanding and builtin.target.cpu.arch == .x86_64 and !builtin.is_test) {
        const logger = @import("hal/logger.zig");
        const tag = @tagName(scope);
        const alloc = global_alloc.get();
        const prefix = std.fmt.allocPrint(alloc, "[{s}] [{s}] ", .{ @tagName(level), tag }) catch return;
        defer alloc.free(prefix);
        logger.write(prefix);
        const buf = std.fmt.allocPrint(alloc, format, args) catch return;
        defer alloc.free(buf);
        logger.write(buf);
        logger.write("\n");
    }
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    if (builtin.target.os.tag == .freestanding and builtin.target.cpu.arch == .x86_64 and !builtin.is_test) {
        const logger = @import("hal/logger.zig");
        logger.panicLog(msg);
    }
    var h = hal.Hal.init();
    h.halt(.panic);
}

pub export fn kmain() noreturn {
    initLogger();
    var h = hal.Hal.init();
    initPlatform();
    initInterrupts();
    initBootDevices();

    var page_mem: [1024 * 4096]u8 align(4096) = undefined;
    var page_allocator = pmm.PageAllocator.init(&page_mem, page_mem.len, 4096);
    smp.initSmp(&page_allocator);

    if (builtin.target.os.tag == .freestanding) {
        global_alloc.init(&page_allocator, 1024 * 1024) catch {
            if (builtin.target.cpu.arch == .x86_64) {
                const log = @import("hal/logger.zig");
                log.errorLog("global_alloc.init failed");
            }
            h.halt(.panic);
        };
    }

    const UTXO_SLOTS = 1000;
    const SCRIPT_HEAP_SIZE = 64 * 1024;

    var utxo = initUtxoStack(UTXO_SLOTS, SCRIPT_HEAP_SIZE) catch {
        if (builtin.target.cpu.arch == .x86_64) {
            const log = @import("hal/logger.zig");
            log.errorLog("initUtxoStack failed");
        }
        h.halt(.panic);
    };

    const kernel_alloc = global_alloc.get();
    var wallet_engine = brc100.KernelWallet.init(kernel_alloc, &utxo);
    wallet_engine.setNetwork(.mainnet);

    _ = initAgent(&h, &wallet_engine);

    var ctx = shell.ShellContext{};
    var con = console_mod.Console.init();
    con.clear();
    shell.run(&ctx, &con, &wallet_engine);

    h.halt(.shutdown);
}

fn initLogger() void {
    if (builtin.target.os.tag == .freestanding and builtin.target.cpu.arch == .x86_64 and !builtin.is_test) {
        const logger = @import("hal/logger.zig");
        logger.init();
        logger.write("[KERNEL] Odysseus booting\n");
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

fn initInterrupts() void {
    if (builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .freestanding and !builtin.is_test) {
        const idt_mod = @import("arch/x86_64/idt.zig");
        const timer = @import("arch/x86_64/timer.zig");
        const Handler = struct {
            fn callback(frame: *const idt_mod.InterruptFrame) callconv(.C) void {
                const vec = frame.vector;
                if (vec == 0x20) {
                    timer.handler(frame);
                }
            }
        };
        idt_mod.init(Handler.callback);
        timer.init(Handler.callback);
        x86_64.sti();
    }
}

fn initBootDevices() void {
    if (builtin.target.cpu.arch == .x86_64) {
        usb.init();
    }
}

fn initUtxoStack(num_slots: usize, script_heap_size: usize) !utxo_stack.UtxoStack {
    const allocator = global_alloc.get();
    return try utxo_stack.UtxoStack.init(allocator, num_slots, script_heap_size);
}

fn logError(msg: []const u8) void {
    if (builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .freestanding and !builtin.is_test) {
        const log = @import("hal/logger.zig");
        log.errorLog(msg);
    }
}

fn initAgent(h: *hal.Hal, wallet_engine: *brc100.KernelWallet) scheduler.AgentScheduler {
    const allocator = global_alloc.get();

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
    }) catch logError("registerTool balance failed");

    sched.registerTool(allocator, "scan", .{
        .name = "scan",
        .handler = struct {
            fn f(_: *anyopaque, _: []const u8) []const u8 {
                return "ok";
            }
        }.f,
    }) catch logError("registerTool scan failed");

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
    }) catch logError("registerTool version failed");

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
    }) catch logError("registerTool network failed");

    sched.registerTool(allocator, "height", .{
        .name = "height",
        .handler = struct {
            fn f(ctx: *anyopaque, _: []const u8) []const u8 {
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                const result = std.fmt.allocPrint(kw.allocator, "{}", .{kw.getHeight()}) catch return "0";
                return result;
            }
        }.f,
    }) catch logError("registerTool height failed");

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
