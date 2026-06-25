const std = @import("std");
const builtin = @import("builtin");
const Slot = @import("slot.zig").Slot;
const Bitmap = @import("bitmap.zig").Bitmap;

pub const Error = error{
    OutOfSlots,
    SlotAlreadyOccupied,
    SlotNotFound,
    ScriptHeapFull,
    InvalidSlotIndex,
};

pub const UtxoStack = struct {
    slots: [*]Slot,
    slot_alloc: []u8,
    capacity: usize,
    count: usize,
    bitmap: Bitmap,
    bitmap_words: []u64,
    script_heap: []u8,
    script_offset: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_slots: usize, script_heap_size: usize) !UtxoStack {
        const alignment = 64;
        const slot_bytes = num_slots * @sizeOf(Slot);
        const slot_mem = try allocator.alignedAlloc(u8, alignment, slot_bytes);
        @memset(slot_mem, 0);

        const bitmap_words_len = (num_slots + 63) / 64;
        const bitmap_mem = try allocator.alloc(u64, bitmap_words_len);
        @memset(bitmap_mem, 0);

        const heap_mem = try allocator.alloc(u8, script_heap_size);

        return .{
            .slots = @ptrCast(slot_mem.ptr),
            .slot_alloc = slot_mem,
            .capacity = num_slots,
            .count = 0,
            .bitmap = Bitmap.init(bitmap_mem),
            .bitmap_words = bitmap_mem,
            .script_heap = heap_mem,
            .script_offset = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UtxoStack) void {
        self.allocator.free(self.slot_alloc);
        self.allocator.free(self.bitmap_words);
        self.allocator.free(self.script_heap);
    }

    pub fn insert(self: *UtxoStack, slot: Slot, script: []const u8) !usize {
        const idx = self.bitmap.findFree() orelse return Error.OutOfSlots;
        if (idx >= self.capacity) return Error.OutOfSlots;

        const script_off = self.pushScript(script) catch return Error.ScriptHeapFull;

        var dst = &self.slots[idx];
        dst.* = slot;
        dst.script_off = @as(u32, @intCast(script_off));
        dst.script_len = @as(u32, @intCast(script.len));

        self.bitmap.set(idx);
        self.count += 1;

        return idx;
    }

    pub fn get(self: *const UtxoStack, idx: usize) ?*const Slot {
        if (idx >= self.capacity) return null;
        if (!self.bitmap.isSet(idx)) return null;
        return &self.slots[idx];
    }

    pub fn getMut(self: *UtxoStack, idx: usize) ?*Slot {
        if (idx >= self.capacity) return null;
        if (!self.bitmap.isSet(idx)) return null;
        return &self.slots[idx];
    }

    pub fn spend(self: *UtxoStack, idx: usize) !void {
        const slot = self.getMut(idx) orelse return Error.SlotNotFound;
        slot.markSpent();
    }

    pub fn remove(self: *UtxoStack, idx: usize) !Slot {
        if (idx >= self.capacity) return Error.InvalidSlotIndex;
        if (!self.bitmap.isSet(idx)) return Error.SlotNotFound;

        const slot = self.slots[idx];
        self.slots[idx] = Slot.init([_]u8{0} ** 32, 0, 0, 0, .{});
        self.bitmap.unset(idx);
        self.count -= 1;
        return slot;
    }

    pub fn getScript(self: *const UtxoStack, slot: *const Slot) ?[]const u8 {
        if (slot.script_len == 0) return null;
        if (slot.script_off + slot.script_len > self.script_heap.len) return null;
        return self.script_heap[slot.script_off .. slot.script_off + slot.script_len];
    }

    pub fn findSlot(self: *const UtxoStack, txid: [32]u8, vout: u32) ?usize {
        var i: usize = 0;
        while (i < self.capacity) : (i += 1) {
            if (!self.bitmap.isSet(i)) continue;
            const slot = &self.slots[i];
            if (slot.vout == vout and std.mem.eql(u8, &slot.txid, &txid)) {
                return i;
            }
        }
        return null;
    }

    pub fn scanScript(self: *const UtxoStack, pattern: []const u8) UtxoScanner {
        return .{
            .stack = self,
            .pattern = pattern,
            .index = 0,
        };
    }

    fn pushScript(self: *UtxoStack, script: []const u8) !usize {
        if (self.script_offset + script.len > self.script_heap.len) {
            return Error.ScriptHeapFull;
        }
        const off = self.script_offset;
        @memcpy(self.script_heap[off..][0..script.len], script);
        self.script_offset += script.len;
        return off;
    }

    pub fn totalMemoryUsed(self: *const UtxoStack) usize {
        return (self.capacity * @sizeOf(Slot)) + (self.bitmap_words.len * 8) + self.script_offset;
    }

    pub fn utilization(self: *const UtxoStack) f64 {
        if (self.capacity == 0) return 0;
        return @as(f64, @floatFromInt(self.count)) / @as(f64, @floatFromInt(self.capacity));
    }
};

pub const UtxoScanner = struct {
    stack: *const UtxoStack,
    pattern: []const u8,
    index: usize,

    pub fn next(self: *UtxoScanner) ?struct { idx: usize, slot: *const Slot } {
        while (self.index < self.stack.capacity) : (self.index += 1) {
            if (!self.stack.bitmap.isSet(self.index)) {
                self.index += 1;
                continue;
            }
            const slot = &self.stack.slots[self.index];
            const script = self.stack.getScript(slot) orelse {
                self.index += 1;
                continue;
            };
            if (std.mem.indexOf(u8, script, self.pattern) != null) {
                defer self.index += 1;
                return .{ .idx = self.index, .slot = slot };
            }
            self.index += 1;
        }
        return null;
    }
};

test "init and basic ops" {
    const allocator = std.testing.allocator;
    var stack = try UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();

    try std.testing.expectEqual(1024, stack.capacity);
    try std.testing.expectEqual(0, stack.count);
}

test "insert and get slot" {
    const allocator = std.testing.allocator;
    var stack = try UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();

    const txid = [_]u8{0xAA} ** 32;
    const slot = Slot.init(txid, 0, 10000, 800000, .{});
    const idx = try stack.insert(slot, &.{0x76, 0xa9, 0x14, 0x88, 0xac});

    const retrieved = stack.get(idx).?;
    try std.testing.expectEqual(10000, retrieved.value);
    try std.testing.expectEqual(800000, retrieved.height);

    const script = stack.getScript(retrieved).?;
    try std.testing.expectEqualSlices(u8, &.{0x76, 0xa9, 0x14, 0x88, 0xac}, script);
}

test "spend slot" {
    const allocator = std.testing.allocator;
    var stack = try UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();

    const txid = [_]u8{0xBB} ** 32;
    const slot = Slot.init(txid, 1, 50000, 700000, .{});
    const idx = try stack.insert(slot, &.{});

    try stack.spend(idx);
    const retrieved = stack.get(idx).?;
    try std.testing.expect(retrieved.isSpent());
}

test "find slot by outpoint" {
    const allocator = std.testing.allocator;
    var stack = try UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();

    const txid = [_]u8{0xCC} ** 32;
    _ = try stack.insert(Slot.init(txid, 0, 1, 1, .{}), &.{});
    _ = try stack.insert(Slot.init(txid, 1, 2, 1, .{}), &.{});

    const found = stack.findSlot(txid, 1);
    try std.testing.expect(found != null);
    const fslot = stack.get(found.?).?;
    try std.testing.expectEqual(2, fslot.value);
}

test "remove slot" {
    const allocator = std.testing.allocator;
    var stack = try UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();

    const txid = [_]u8{0xDD} ** 32;
    const idx = try stack.insert(Slot.init(txid, 0, 999, 500000, .{}), &.{0x6a});
    try std.testing.expectEqual(1, stack.count);

    const removed = try stack.remove(idx);
    try std.testing.expectEqual(999, removed.value);
    try std.testing.expectEqual(0, stack.count);
}

test "out of slots" {
    const allocator = std.testing.allocator;
    var stack = try UtxoStack.init(allocator, 2, 1024);
    defer stack.deinit();

    const txid = [_]u8{0xEE} ** 32;
    _ = try stack.insert(Slot.init(txid, 0, 1, 1, .{}), &.{});
    _ = try stack.insert(Slot.init(txid, 1, 2, 1, .{}), &.{});
    try std.testing.expectError(Error.OutOfSlots, stack.insert(Slot.init(txid, 2, 3, 1, .{}), &.{}));
}

test "utilization" {
    const allocator = std.testing.allocator;
    var stack = try UtxoStack.init(allocator, 100, 1024);
    defer stack.deinit();

    try std.testing.expectEqual(0, stack.utilization());
    const txid = [_]u8{0xFF} ** 32;
    _ = try stack.insert(Slot.init(txid, 0, 1, 1, .{}), &.{});
    try std.testing.expectEqual(@as(f64, 0.01), stack.utilization());
}
