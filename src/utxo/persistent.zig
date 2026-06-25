const std = @import("std");
const builtin = @import("builtin");
const Slot = @import("slot.zig").Slot;
const utxo_stack = @import("stack.zig");

pub const PersistentError = error{
    MapFailed,
    SyncFailed,
    InvalidFile,
    VersionMismatch,
    HeaderCorrupt,
};

const MAGIC: u32 = 0x5554584F;
const VERSION: u32 = 1;

const Header = extern struct {
    magic: u32,
    version: u32,
    num_slots: u64,
    script_heap_size: u64,
    slot_count: u64,
    script_offset: u64,
    checksum: u32,
};

pub const PersistentUtxo = struct {
    allocator: std.mem.Allocator,
    fd: std.fs.File,
    map: []align(4096) u8,
    header: *volatile Header,
    slots: [*]Slot,
    bitmap_words: []u64,
    script_heap: []u8,
    capacity: usize,
    count: usize,
    script_offset: usize,
    dirty: bool,

    pub fn open(path: []const u8, num_slots: usize, script_heap_size: usize, allocator: std.mem.Allocator) !PersistentUtxo {
        const file = try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close();

        const header_size = @sizeOf(Header);
        const aligned_header = memAlignUp(header_size, 4096);
        const slot_bytes = num_slots * @sizeOf(Slot);
        const bitmap_bytes = ((num_slots + 63) / 64) * 8;
        const total = aligned_header + slot_bytes + bitmap_bytes + script_heap_size;

        const actual = try file.getEndPos();
        if (actual == 0) {
            try file.setEndPos(total);
        } else if (actual < total) {
            try file.setEndPos(total);
        }

        const map = try std.posix.mmap(
            null,
            total,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            std.posix.MAP.SHARED,
            file.handle,
            0,
        );
        errdefer std.posix.munmap(map);

        const header_ptr: *Header = @ptrCast(@alignCast(map.ptr));
        if (actual > 0 and header_ptr.magic == MAGIC) {
            if (header_ptr.version != VERSION) return error.VersionMismatch;
            if (header_ptr.num_slots != num_slots) return error.InvalidFile;
        } else {
            header_ptr.* = .{
                .magic = MAGIC,
                .version = VERSION,
                .num_slots = num_slots,
                .script_heap_size = script_heap_size,
                .slot_count = 0,
                .script_offset = 0,
                .checksum = 0,
            };
        }

        const slot_off = aligned_header;
        const bitmap_off = slot_off + slot_bytes;
        const heap_off = bitmap_off + bitmap_bytes;

        const bitmap_words_len = (num_slots + 63) / 64;

        return .{
            .allocator = allocator,
            .fd = file,
            .map = map,
            .header = header_ptr,
            .slots = @ptrCast(@alignCast(map.ptr + slot_off)),
            .bitmap_words = @ptrCast(@alignCast(map.ptr + bitmap_off)),
            .script_heap = map.ptr + heap_off,
            .capacity = num_slots,
            .count = @intCast(header_ptr.slot_count),
            .script_offset = @intCast(header_ptr.script_offset),
            .dirty = false,
        };
    }

    pub fn close(self: *PersistentUtxo) void {
        if (self.dirty) self.sync() catch {};
        std.posix.munmap(self.map);
        self.fd.close();
    }

    pub fn sync(self: *PersistentUtxo) !void {
        self.header.slot_count = @intCast(self.count);
        self.header.script_offset = @intCast(self.script_offset);
        std.posix.msync(self.map, std.posix.MSF.SYNC) catch return error.SyncFailed;
        self.dirty = false;
    }

    pub fn insert(self: *PersistentUtxo, slot: Slot, script: []const u8) !usize {
        if (self.count >= self.capacity) return utxo_stack.Error.OutOfSlots;
        const idx = self.findFreeSlot() orelse return utxo_stack.Error.OutOfSlots;
        if (self.script_offset + script.len > self.script_heap.len) return utxo_stack.Error.ScriptHeapFull;

        self.slots[idx] = slot;
        self.slots[idx].script_off = @intCast(self.script_offset);
        self.slots[idx].script_len = @intCast(script.len);
        @memcpy(self.script_heap[self.script_offset..][0..script.len], script);
        self.script_offset += script.len;
        self.setBitmap(idx);
        self.count += 1;
        self.dirty = true;
        return idx;
    }

    pub fn get(self: *const PersistentUtxo, idx: usize) ?*const Slot {
        if (idx >= self.capacity) return null;
        if (!self.isBitmapSet(idx)) return null;
        return &self.slots[idx];
    }

    pub fn spend(self: *PersistentUtxo, idx: usize) !void {
        const slot = self.getMut(idx) orelse return utxo_stack.Error.SlotNotFound;
        slot.markSpent();
        self.dirty = true;
    }

    pub fn getMut(self: *PersistentUtxo, idx: usize) ?*Slot {
        if (idx >= self.capacity) return null;
        if (!self.isBitmapSet(idx)) return null;
        return &self.slots[idx];
    }

    pub fn getScript(self: *const PersistentUtxo, slot: *const Slot) ?[]const u8 {
        if (slot.script_len == 0) return null;
        if (slot.script_off + slot.script_len > self.script_heap.len) return null;
        return self.script_heap[slot.script_off .. slot.script_off + slot.script_len];
    }

    fn findFreeSlot(self: *const PersistentUtxo) ?usize {
        const words = self.bitmap_words;
        const num_words = (self.capacity + 63) / 64;
        for (0..num_words) |i| {
            if (words[i] != ~@as(u64, 0)) {
                const free = @ctz(~words[i]);
                const idx = i * 64 + free;
                if (idx < self.capacity) return idx;
            }
        }
        return null;
    }

    fn setBitmap(self: *PersistentUtxo, idx: usize) void {
        const word = idx / 64;
        const bit = idx % 64;
        self.bitmap_words[word] |= (@as(u64, 1) << @intCast(bit));
    }

    fn isBitmapSet(self: *const PersistentUtxo, idx: usize) bool {
        const word = idx / 64;
        const bit = idx % 64;
        return (self.bitmap_words[word] & (@as(u64, 1) << @intCast(bit))) != 0;
    }
};

fn memAlignUp(addr: usize, alignment: usize) usize {
    return (addr + alignment - 1) & ~(alignment - 1);
}

test "persistent utxo header size" {
    try std.testing.expectEqual(48, @sizeOf(Header));
}

test "persistent utxo open and insert" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/test_utxo_persist.bin";
    _ = std.fs.cwd().deleteFile(tmp_path) catch {};

    var p = try PersistentUtxo.open(tmp_path, 1024, 65536, allocator);
    defer p.close();

    const txid = [_]u8{0xAA} ** 32;
    const slot = Slot.init(txid, 0, 100000, 800000, .{});
    const idx = try p.insert(slot, &.{0x76, 0xa9, 0x14, 0x88, 0xac});
    try std.testing.expectEqual(@as(usize, 0), idx);

    const retrieved = p.get(idx).?;
    try std.testing.expectEqual(@as(u64, 100000), retrieved.value);
}
