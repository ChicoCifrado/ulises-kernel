const std = @import("std");
const UtxoStack = @import("stack.zig").UtxoStack;
const Slot = @import("slot.zig").Slot;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("UTXO Stack Benchmark\n", .{});
    try stdout.print("====================\n\n", .{});

    try benchInsert(allocator, stdout);
    try benchFind(allocator, stdout);
    try benchScan(allocator, stdout);
    try benchMemory(allocator, stdout);
}

fn benchInsert(allocator: std.mem.Allocator, stdout: anytype) !void {
    const N = 100_000;
    var stack = try UtxoStack.init(allocator, N, 10_485_760);
    defer stack.deinit();

    var timer = try std.time.Timer.start();
    for (0..N) |i| {
        var txid: [32]u8 = undefined;
        std.mem.writeInt(u64, txid[0..8], @intCast(i), .little);
        const slot = Slot.init(txid, 0, @intCast(i), 800000, .{});
        _ = try stack.insert(slot, &.{0x76, 0xa9, 0x14, 0x88, 0xac});
    }
    const elapsed = timer.lap();

    try stdout.print("Insert {d} slots: {d} ms ({d} ops/sec)\n", .{
        N,
        elapsed / 1_000_000,
        @divTrunc(N * 1_000_000_000, elapsed),
    });
}

fn benchFind(allocator: std.mem.Allocator, stdout: anytype) !void {
    const N = 10_000;
    var stack = try UtxoStack.init(allocator, N, 1_048_576);
    defer stack.deinit();

    for (0..N) |i| {
        var txid: [32]u8 = undefined;
        std.mem.writeInt(u64, txid[0..8], @intCast(i), .little);
        _ = try stack.insert(Slot.init(txid, 0, @intCast(i), 800000, .{}), &.{});
    }

    var timer = try std.time.Timer.start();
    for (0..N) |i| {
        var txid: [32]u8 = undefined;
        std.mem.writeInt(u64, txid[0..8], @intCast(i), .little);
        _ = stack.findSlot(txid, 0);
    }
    const elapsed = timer.lap();

    try stdout.print("Find {d} slots: {d} ms ({d} ops/sec)\n", .{
        N,
        elapsed / 1_000_000,
        @divTrunc(N * 1_000_000_000, elapsed),
    });
}

fn benchScan(allocator: std.mem.Allocator, stdout: anytype) !void {
    const N = 10_000;
    var stack = try UtxoStack.init(allocator, N, 1_048_576);
    defer stack.deinit();

    for (0..N) |i| {
        var txid: [32]u8 = undefined;
        std.mem.writeInt(u64, txid[0..8], @intCast(i), .little);
        const script = if (i % 2 == 0) &[_]u8{0x6a, 0x03, 0x41, 0x42, 0x43} else &[_]u8{0x76, 0xa9, 0x14, 0x88, 0xac};
        _ = try stack.insert(Slot.init(txid, 0, @intCast(i), 800000, .{}), script);
    }

    var timer = try std.time.Timer.start();
    var found: usize = 0;
    var scanner = stack.scanScript(&[_]u8{0x6a});
    while (scanner.next()) |_| {
        found += 1;
    }
    const elapsed = timer.lap();

    try stdout.print("Scan {d} slots for OP_RETURN: found {d} in {d} ms\n", .{
        N,
        found,
        elapsed / 1_000_000,
    });
}

fn benchMemory(allocator: std.mem.Allocator, stdout: anytype) !void {
    const N = 1_000_000;
    var stack = try UtxoStack.init(allocator, N, 104_857_600);
    defer stack.deinit();

    for (0..N) |i| {
        var txid: [32]u8 = undefined;
        std.mem.writeInt(u64, txid[0..8], @intCast(i), .little);
        _ = try stack.insert(Slot.init(txid, @intCast(i % 256), @intCast(i), 800000, .{}), &.{0x6a});
    }

    const slot_mb = @as(f64, @floatFromInt(N * @sizeOf(Slot))) / (1024 * 1024);
    const total_mb = @as(f64, @floatFromInt(stack.totalMemoryUsed())) / (1024 * 1024);

    try stdout.print("\nMemory for {d} slots:\n", .{N});
    try stdout.print("  Slot array: {d:.1} MB\n", .{slot_mb});
    try stdout.print("  Total used: {d:.1} MB\n", .{total_mb});
    try stdout.print("  Utilization: {d:.2}%\n", .{stack.utilization() * 100});
}
