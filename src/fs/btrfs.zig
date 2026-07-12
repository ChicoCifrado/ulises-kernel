const std = @import("std");
const vfs = @import("vfs.zig");
const blockdev = @import("blockdev.zig");

const BTRFS_MAGIC: [8]u8 = .{ '_', 'B', 'H', 'R', 'f', 'S', '_', 'M' };
const BTRFS_SUPER_OFFSET: u64 = 0x10000;

const BTRFS_INODE_ITEM: u8 = 1;
const BTRFS_INODE_REF: u8 = 12;
const BTRFS_DIR_ITEM: u8 = 84;
const BTRFS_EXTENT_DATA: u8 = 108;
const BTRFS_CHUNK_ITEM: u8 = 228;
const BTRFS_ROOT_ITEM: u8 = 132;

const BTRFS_FS_TREE_OBJECTID: u64 = 5;
const BTRFS_FIRST_FREE_OBJECTID: u64 = 256;

const EXTENT_INLINE: u8 = 0;

fn rdU16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}
fn rdU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}
fn rdU64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

const Key = struct {
    objectid: u64,
    item_type: u8,
    offset: u64,
};

fn readKey(buf: []const u8, off: usize) Key {
    return .{
        .objectid = rdU64(buf, off),
        .item_type = buf[off + 8],
        .offset = rdU64(buf, off + 9),
    };
}

fn keyCmp(a: Key, b: Key) std.math.Order {
    if (a.objectid < b.objectid) return .lt;
    if (a.objectid > b.objectid) return .gt;
    if (a.item_type < b.item_type) return .lt;
    if (a.item_type > b.item_type) return .gt;
    if (a.offset < b.offset) return .lt;
    if (a.offset > b.offset) return .gt;
    return .eq;
}

const LeafItem = struct {
    key: Key,
    offset: u32,
    size: u32,
};

fn readLeafItem(buf: []const u8, off: usize) LeafItem {
    return .{
        .key = readKey(buf, off),
        .offset = rdU32(buf, off + 17),
        .size = rdU32(buf, off + 21),
    };
}

const KEY_SIZE = 17;
const LEAF_ITEM_SIZE = 25;
const KEY_PTR_SIZE = 33;
const HEADER_SIZE = 101;

const NodeHeader = struct {
    bytenr: u64,
    owner: u64,
    nritems: u32,
    level: u8,
};

fn readNodeHeader(buf: []const u8) NodeHeader {
    return .{
        .bytenr = rdU64(buf, 48),
        .owner = rdU64(buf, 88),
        .nritems = rdU32(buf, 96),
        .level = buf[100],
    };
}

pub const BtrfsFs = struct {
    dev: *blockdev.BlockDev,
    allocator: std.mem.Allocator,
    sectorsize: u32,
    nodesize: u32,
    chunk_mappings: []ChunkMapping,
    fs_tree_root_addr: u64,
    fs_tree_root_level: u8,
    root_tree_root_addr: u64,
    root_tree_root_level: u8,
    chunk_tree_root_addr: u64,
    chunk_tree_root_level: u8,

    const ChunkMapping = struct {
        logical: u64,
        length: u64,
        physical: u64,
    };

    pub fn init(dev: *blockdev.BlockDev, allocator: std.mem.Allocator) ?BtrfsFs {
        const log = @import("../hal/logger.zig");
        var sb_buf: [4096]u8 = undefined;
        const sb_lba = BTRFS_SUPER_OFFSET / dev.block_size;
        if (!dev.readExact(sb_lba, &sb_buf)) {
            log.write("[BTRFS] read SB FAIL\n");
            return null;
        }

        if (!std.mem.eql(u8, sb_buf[0x40..][0..8], &BTRFS_MAGIC)) {
            log.write("[BTRFS] bad magic\n");
            return null;
        }

        const sectorsize = rdU32(&sb_buf, 0x90);
        const nodesize = rdU32(&sb_buf, 0x94);
        const root_addr = rdU64(&sb_buf, 0x50);
        const root_level = sb_buf[0xCA];
        const chunk_root_addr = rdU64(&sb_buf, 0x58);
        const chunk_root_level = sb_buf[0xCB];

        const sys_chunk_array_size = rdU32(&sb_buf, 0xA4);

        var temp_chunks: [32]ChunkMapping = undefined;
        var chunk_count: usize = 0;

        // sys_chunk_array starts at superblock offset 0x190
        const SYS_CHUNK_ARRAY_OFF: usize = 0x190;
        var off = SYS_CHUNK_ARRAY_OFF;
        while (off + KEY_SIZE + 8 + 8 + @sizeOf(ChunkItemOnDisk) + @sizeOf(StripeOnDisk) <= SYS_CHUNK_ARRAY_OFF + sys_chunk_array_size and off + 8 + 8 + 64 + 32 + 32 <= sb_buf.len) {
            const key = readKey(&sb_buf, off);
            off += KEY_SIZE;
            off += 8; // blockptr (skip)
            off += 8; // generation (skip)
            if (key.item_type != BTRFS_CHUNK_ITEM) break;

            if (off + 48 > sb_buf.len) break;
            const chunk_len = rdU64(&sb_buf, off + 0);
            const num_stripes = rdU32(&sb_buf, off + 44);
            off += 48;

            if (num_stripes != 1) break;
            if (off + 32 > sb_buf.len) break;
            const stripe_devid = rdU64(&sb_buf, off + 0);
            const stripe_offset = rdU64(&sb_buf, off + 8);
            _ = stripe_devid;

            if (chunk_count < temp_chunks.len) {
                temp_chunks[chunk_count] = .{
                    .logical = key.offset,
                    .length = chunk_len,
                    .physical = stripe_offset,
                };
                chunk_count += 1;
            }
            off += 32;
        }

        const chunk_mappings = allocator.alloc(ChunkMapping, chunk_count) catch {
            log.write("[BTRFS] alloc chunks FAIL\n");
            return null;
        };
        @memcpy(chunk_mappings, temp_chunks[0..chunk_count]);
        log.writeFmt("[BTRFS] {d} chunks\n", .{chunk_count});

        var self = BtrfsFs{
            .dev = dev,
            .allocator = allocator,
            .sectorsize = sectorsize,
            .nodesize = nodesize,
            .chunk_mappings = chunk_mappings,
            .fs_tree_root_addr = 0,
            .fs_tree_root_level = 0,
            .root_tree_root_addr = root_addr,
            .root_tree_root_level = root_level,
            .chunk_tree_root_addr = chunk_root_addr,
            .chunk_tree_root_level = chunk_root_level,
        };

        if (chunk_root_addr != 0) {
            self.readChunkTree();
        }

        const fs_root_addr = self.findFsRoot() orelse {
            log.write("[BTRFS] findFsRoot FAIL\n");
            allocator.free(chunk_mappings);
            return null;
        };
        log.writeFmt("[BTRFS] FS root=0x{x}\n", .{fs_root_addr});
        self.fs_tree_root_addr = fs_root_addr;
        self.fs_tree_root_level = 0;

        return self;
    }

    pub fn deinit(self: *BtrfsFs) void {
        self.allocator.free(self.chunk_mappings);
    }

    fn logicalToPhysical(self: *const BtrfsFs, logical: u64) ?u64 {
        for (self.chunk_mappings) |m| {
            if (logical >= m.logical and logical < m.logical + m.length) {
                return m.physical + (logical - m.logical);
            }
        }
        return null;
    }

    fn readNodeAlloc(self: *const BtrfsFs, logical: u64) ?[]u8 {
        const phys = self.logicalToPhysical(logical) orelse return null;
        const buf = self.allocator.alloc(u8, self.nodesize) catch return null;
        const lba = phys / self.dev.block_size;
        if (!self.dev.readExact(lba, buf)) {
            self.allocator.free(buf);
            return null;
        }
        return buf;
    }

    const ChunkItemOnDisk = packed struct {
        length: u64,
        owner: u64,
        stripe_len: u64,
        block_type: u64,
        io_align: u32,
        io_width: u32,
        io_minimum: u32,
        num_stripes: u16,
        sub_stripes: u16,
    };

    const StripeOnDisk = extern struct {
        device_id: u64,
        offset: u64,
        device_uuid: [16]u8,
    };

    fn readChunkTree(self: *BtrfsFs) void {
        var buf: [4096]u8 = undefined;
        const node = self.readNode(self.chunk_tree_root_addr, &buf) orelse return;
        const hdr = readNodeHeader(node);
        if (hdr.level != 0) return;

        const max_items = (self.nodesize - HEADER_SIZE) / LEAF_ITEM_SIZE;
        const count = @min(@as(usize, hdr.nritems), max_items);

        for (0..count) |i| {
            const item = readLeafItem(node, HEADER_SIZE + i * LEAF_ITEM_SIZE);
            if (item.key.item_type != BTRFS_CHUNK_ITEM) continue;

            const data_off = @as(usize, item.offset);
            if (data_off + @sizeOf(ChunkItemOnDisk) > self.nodesize) continue;
            const ci = @as(*const ChunkItemOnDisk, @ptrCast(@alignCast(&node[data_off])));
            if (ci.num_stripes != 1) continue;

            const stripe_off = data_off + @sizeOf(ChunkItemOnDisk);
            if (stripe_off + @sizeOf(StripeOnDisk) > self.nodesize) continue;
            const stripe = @as(*const StripeOnDisk, @ptrCast(@alignCast(&node[stripe_off])));

            var new_mappings = self.allocator.alloc(ChunkMapping, self.chunk_mappings.len + 1) catch return;
            @memcpy(new_mappings[0..self.chunk_mappings.len], self.chunk_mappings);
            new_mappings[self.chunk_mappings.len] = .{
                .logical = item.key.offset,
                .length = ci.length,
                .physical = stripe.offset,
            };
            self.allocator.free(self.chunk_mappings);
            self.chunk_mappings = new_mappings;
        }
    }

    fn readNode(self: *const BtrfsFs, logical: u64, buf: []u8) ?[]u8 {
        if (buf.len < self.nodesize) return null;
        const phys = self.logicalToPhysical(logical) orelse return null;
        const lba = phys / self.dev.block_size;
        if (!self.dev.readExact(lba, buf[0..self.nodesize])) return null;
        return buf[0..self.nodesize];
    }

    fn findFsRoot(self: *const BtrfsFs) ?u64 {
        const log = @import("../hal/logger.zig");
        var node_buf: [4096]u8 = undefined;
        if (self.nodesize > node_buf.len) return null;

        var addr = self.root_tree_root_addr;
        var level = self.root_tree_root_level;

        while (level > 0) {
            const buf = self.readNode(addr, &node_buf) orelse return null;
            const hdr = readNodeHeader(buf);
            const nritems = @min(@as(usize, hdr.nritems), (self.nodesize - HEADER_SIZE) / KEY_PTR_SIZE);

            var best: ?usize = null;
            for (0..nritems) |i| {
                const k = readKey(buf, HEADER_SIZE + i * KEY_PTR_SIZE);
                const cmp = keyCmp(k, Key{ .objectid = BTRFS_FS_TREE_OBJECTID, .item_type = BTRFS_ROOT_ITEM, .offset = 0 });
                if (cmp != .gt) best = i;
            }
            const idx = best orelse return null;
            addr = rdU64(buf, HEADER_SIZE + idx * KEY_PTR_SIZE + KEY_SIZE);
            level = hdr.level - 1;
        }

        const buf = self.readNode(addr, &node_buf) orelse {
            log.write("[BTRFS] findFsRoot readNode FAIL\n");
            return null;
        };
        const hdr = readNodeHeader(buf);
        if (hdr.level != 0) {
            log.writeFmt("[BTRFS] findFsRoot bad level {d}\n", .{hdr.level});
            return null;
        }
        log.writeFmt("[BTRFS] findFsRoot nritems={d}\n", .{hdr.nritems});

        const max_items = (self.nodesize - HEADER_SIZE) / LEAF_ITEM_SIZE;
        const count = @min(@as(usize, hdr.nritems), max_items);

        for (0..count) |i| {
            const item = readLeafItem(buf, HEADER_SIZE + i * LEAF_ITEM_SIZE);
            log.writeFmt("[BTRFS] item={d} obj={d} type={d} off={d} size={d}\n", .{ i, item.key.objectid, item.key.item_type, item.offset, item.size });
            if (item.key.objectid == BTRFS_FS_TREE_OBJECTID and item.key.item_type == BTRFS_ROOT_ITEM) {
                const data_off = @as(usize, item.offset);
                log.writeFmt("[BTRFS] findFsRoot data_off={d}\n", .{data_off});
                if (data_off + 512 > self.nodesize) {
                    log.write("[BTRFS] findFsRoot data_off+512 overflow\n");
                    continue;
                }
                const bytenr = rdU64(buf, data_off + 0x70);
                log.writeFmt("[BTRFS] findFsRoot bytenr=0x{x}\n", .{bytenr});
                return bytenr;
            }
        }
        return null;
    }

    fn searchLeaf(self: *const BtrfsFs, leaf_buf: []const u8, target: Key) ?struct { idx: usize, item: LeafItem } {
        const hdr = readNodeHeader(leaf_buf);
        if (hdr.level != 0) return null;

        const max_items = (self.nodesize - HEADER_SIZE) / LEAF_ITEM_SIZE;
        const count = @min(@as(usize, hdr.nritems), max_items);

        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const item = readLeafItem(leaf_buf, HEADER_SIZE + mid * LEAF_ITEM_SIZE);
            const cmp = keyCmp(item.key, target);
            if (cmp == .eq) return .{ .idx = mid, .item = item };
            if (cmp == .lt) { lo = mid + 1; } else { hi = mid; }
        }
        return null;
    }

    fn readInode(self: *const BtrfsFs, inode_id: u64) ?InodeInfo {
        const target = Key{ .objectid = inode_id, .item_type = BTRFS_INODE_ITEM, .offset = 0 };
        const data = self.treeSearch(target) orelse return null;
        defer self.allocator.free(data);

        if (data.len < 0x48) return null;
        return InodeInfo{
            .size = rdU64(data, 0x10),
            .nlink = rdU32(data, 0x3C),
            .mode = rdU32(data, 0x44),
            .uid = rdU32(data, 0x40),
            .gid = rdU32(data, 0x38),
        };
    }

    const InodeInfo = struct {
        size: u64,
        nlink: u32,
        mode: u32,
        uid: u32,
        gid: u32,
    };

    fn treeSearch(self: *const BtrfsFs, target: Key) ?[]u8 {
        var node_buf: [4096]u8 = undefined;
        if (self.nodesize > node_buf.len) return null;

        var addr = self.fs_tree_root_addr;
        var level = self.fs_tree_root_level;

        while (level > 0) {
            const buf = self.readNode(addr, &node_buf) orelse return null;
            const hdr = readNodeHeader(buf);
            const nritems = @min(@as(usize, hdr.nritems), (self.nodesize - HEADER_SIZE) / KEY_PTR_SIZE);

            var best: ?usize = null;
            for (0..nritems) |i| {
                const k = readKey(buf, HEADER_SIZE + i * KEY_PTR_SIZE);
                if (keyCmp(k, target) != .gt) best = i;
            }
            const idx = best orelse return null;
            addr = rdU64(buf, HEADER_SIZE + idx * KEY_PTR_SIZE + KEY_SIZE);
            level = hdr.level - 1;
        }

        const buf = self.readNode(addr, &node_buf) orelse return null;
        const result = self.searchLeaf(buf, target) orelse return null;

        const data_off = @as(usize, result.item.offset);
        const data_size = @as(usize, result.item.size);
        if (data_off + data_size > buf.len) return null;

        const out = self.allocator.alloc(u8, data_size) catch return null;
        @memcpy(out, buf[data_off..][0..data_size]);
        return out;
    }

    fn scanDirRange(self: *const BtrfsFs, dir_id: u64, allocator: std.mem.Allocator) ?[][]const u8 {
        var names_buf = allocator.alloc([]const u8, 128) catch return null;
        var names_count: usize = 0;

        var node_buf: [4096]u8 = undefined;
        if (!self.scanDirRangeRecurse(self.fs_tree_root_addr, self.fs_tree_root_level, dir_id, &names_buf, &names_count, allocator, &node_buf)) {
            allocator.free(names_buf);
            return null;
        }

        const result = allocator.alloc([]const u8, names_count) catch return null;
        @memcpy(result, names_buf[0..names_count]);
        allocator.free(names_buf);
        return result;
    }

    fn scanDirRangeRecurse(self: *const BtrfsFs, addr: u64, level: u8, dir_id: u64, names_buf: *[][]const u8, names_count: *usize, allocator: std.mem.Allocator, node_buf: []u8) bool {
        if (self.nodesize > node_buf.len) return false;
        const buf = self.readNode(addr, node_buf) orelse return false;
        const hdr = readNodeHeader(buf);

        if (level > 0) {
            const nritems = @min(@as(usize, hdr.nritems), (self.nodesize - HEADER_SIZE) / KEY_PTR_SIZE);
            for (0..nritems) |i| {
                const k = readKey(buf, HEADER_SIZE + i * KEY_PTR_SIZE);
                if (k.objectid > dir_id) break;
                if (k.objectid == dir_id and k.item_type > BTRFS_DIR_ITEM) break;
                const child_addr = rdU64(buf, HEADER_SIZE + i * KEY_PTR_SIZE + KEY_SIZE);
                if (!self.scanDirRangeRecurse(child_addr, level - 1, dir_id, names_buf, names_count, allocator, node_buf)) return false;
            }
            return true;
        }

        const max_items = (self.nodesize - HEADER_SIZE) / LEAF_ITEM_SIZE;
        const count = @min(@as(usize, hdr.nritems), max_items);
        for (0..count) |i| {
            const item = readLeafItem(buf, HEADER_SIZE + i * LEAF_ITEM_SIZE);
            if (item.key.objectid != dir_id) continue;
            if (item.key.item_type != BTRFS_DIR_ITEM) continue;

            const data_off = @as(usize, item.offset);
            if (data_off + 8 > buf.len) continue;
            const name_len = rdU16(buf, data_off + 0x1B);
            if (data_off + @as(usize, 0x1E) + @as(usize, name_len) > buf.len) continue;

            if (names_count.* >= names_buf.len) {
                const new_buf = allocator.alloc([]const u8, names_buf.len * 2) catch return false;
                @memcpy(new_buf[0..names_buf.len], names_buf.*);
                allocator.free(names_buf.*);
                names_buf.* = new_buf;
            }

            const name = buf[data_off + 0x1E..][0..name_len];
            const stored = allocator.alloc(u8, name.len) catch return false;
            @memcpy(stored, name);
            names_buf.*[names_count.*] = stored;
            names_count.* += 1;
        }
        return true;
    }

    fn findInDir(self: *const BtrfsFs, dir_id: u64, name: []const u8) ?u64 {
        var node_buf: [4096]u8 = undefined;
        if (!self.findDirRecurse(self.fs_tree_root_addr, self.fs_tree_root_level, dir_id, name, &node_buf)) return null;

        // Search the key to get the actual result
        return self.findDirRecurse2(self.fs_tree_root_addr, self.fs_tree_root_level, dir_id, name, &node_buf);
    }

    fn findDirRecurse(self: *const BtrfsFs, addr: u64, level: u8, dir_id: u64, name: []const u8, node_buf: []u8) bool {
        if (self.nodesize > node_buf.len) return false;
        const buf = self.readNode(addr, node_buf) orelse return false;
        const hdr = readNodeHeader(buf);

        if (level > 0) {
            const nritems = @min(@as(usize, hdr.nritems), (self.nodesize - HEADER_SIZE) / KEY_PTR_SIZE);
            for (0..nritems) |i| {
                const k = readKey(buf, HEADER_SIZE + i * KEY_PTR_SIZE);
                if (k.objectid > dir_id) break;
                if (k.objectid == dir_id and k.item_type > BTRFS_DIR_ITEM) break;
                const child_addr = rdU64(buf, HEADER_SIZE + i * KEY_PTR_SIZE + KEY_SIZE);
                if (self.findDirRecurse(child_addr, level - 1, dir_id, name, node_buf)) return true;
            }
            return false;
        }

        const max_items = (self.nodesize - HEADER_SIZE) / LEAF_ITEM_SIZE;
        const count = @min(@as(usize, hdr.nritems), max_items);
        for (0..count) |i| {
            const item = readLeafItem(buf, HEADER_SIZE + i * LEAF_ITEM_SIZE);
            if (item.key.objectid != dir_id) continue;
            if (item.key.item_type != BTRFS_DIR_ITEM) continue;

            const data_off = @as(usize, item.offset);
            if (data_off + 8 > buf.len) continue;
            const name_len = rdU16(buf, data_off + 0x1B);
            if (data_off + @as(usize, 0x1E) + @as(usize, name_len) > buf.len) continue;
            if (name_len != name.len) continue;

            const entry_name = buf[data_off + 0x1E..][0..name_len];
            if (std.mem.eql(u8, entry_name, name)) {
                return true;
            }
        }
        return false;
    }

    fn findDirRecurse2(self: *const BtrfsFs, addr: u64, level: u8, dir_id: u64, name: []const u8, node_buf: []u8) ?u64 {
        if (self.nodesize > node_buf.len) return null;
        const buf = self.readNode(addr, node_buf) orelse return null;
        const hdr = readNodeHeader(buf);

        if (level > 0) {
            const nritems = @min(@as(usize, hdr.nritems), (self.nodesize - HEADER_SIZE) / KEY_PTR_SIZE);
            for (0..nritems) |i| {
                const k = readKey(buf, HEADER_SIZE + i * KEY_PTR_SIZE);
                if (k.objectid > dir_id) break;
                if (k.objectid == dir_id and k.item_type > BTRFS_DIR_ITEM) break;
                const child_addr = rdU64(buf, HEADER_SIZE + i * KEY_PTR_SIZE + KEY_SIZE);
                const result = self.findDirRecurse2(child_addr, level - 1, dir_id, name, node_buf);
                if (result != null) return result;
            }
            return null;
        }

        const max_items = (self.nodesize - HEADER_SIZE) / LEAF_ITEM_SIZE;
        const count = @min(@as(usize, hdr.nritems), max_items);
        for (0..count) |i| {
            const item = readLeafItem(buf, HEADER_SIZE + i * LEAF_ITEM_SIZE);
            if (item.key.objectid != dir_id) continue;
            if (item.key.item_type != BTRFS_DIR_ITEM) continue;

            const data_off = @as(usize, item.offset);
            if (data_off + 8 > buf.len) continue;
            const name_len = rdU16(buf, data_off + 0x1B);
            if (data_off + @as(usize, 0x1E) + @as(usize, name_len) > buf.len) continue;
            if (name_len != name.len) continue;

            const entry_name = buf[data_off + 0x1E..][0..name_len];
            if (std.mem.eql(u8, entry_name, name)) {
                return rdU64(buf, data_off + 0); // DirItem.location.objectid
            }
        }
        return null;
    }

    fn readFileData(self: *const BtrfsFs, inode_id: u64, file_size: usize) ?[]u8 {
        if (file_size == 0) return self.allocator.alloc(u8, 0) catch return null;
        const result = self.allocator.alloc(u8, file_size) catch return null;

        var node_buf: [4096]u8 = undefined;
        var bytes_read: usize = 0;
        var found = false;

        if (!self.readFileExtents(self.fs_tree_root_addr, self.fs_tree_root_level, inode_id, result, &bytes_read, &found, &node_buf)) {
            self.allocator.free(result);
            return null;
        }

        if (!found) {
            self.allocator.free(result);
            return null;
        }
        return result;
    }

    fn readFileExtents(self: *const BtrfsFs, addr: u64, level: u8, inode_id: u64, buffer: []u8, bytes_read: *usize, found: *bool, node_buf: []u8) bool {
        if (self.nodesize > node_buf.len) return false;
        const buf = self.readNode(addr, node_buf) orelse return false;
        const hdr = readNodeHeader(buf);

        if (level > 0) {
            const nritems = @min(@as(usize, hdr.nritems), (self.nodesize - HEADER_SIZE) / KEY_PTR_SIZE);
            for (0..nritems) |i| {
                const k = readKey(buf, HEADER_SIZE + i * KEY_PTR_SIZE);
                if (k.objectid > inode_id) break;
                if (k.objectid == inode_id and k.item_type > BTRFS_EXTENT_DATA) break;
                const child_addr = rdU64(buf, HEADER_SIZE + i * KEY_PTR_SIZE + KEY_SIZE);
                if (!self.readFileExtents(child_addr, level - 1, inode_id, buffer, bytes_read, found, node_buf)) return false;
            }
            return true;
        }

        const max_items = (self.nodesize - HEADER_SIZE) / LEAF_ITEM_SIZE;
        const count = @min(@as(usize, hdr.nritems), max_items);
        for (0..count) |i| {
            const item = readLeafItem(buf, HEADER_SIZE + i * LEAF_ITEM_SIZE);
            if (item.key.objectid != inode_id) continue;
            if (item.key.item_type != BTRFS_EXTENT_DATA) continue;

            const data_off = @as(usize, item.offset);
            const data_size = @as(usize, item.size);
            if (data_off + 0x1B > buf.len) continue;

            const compression = buf[data_off + 0x11];
            const enc_type = buf[data_off + 0x12];
            const item_type = buf[data_off + 0x14];

            // Skip compressed or encrypted extents
            if (compression != 0 or enc_type != 0) continue;

            if (item_type == EXTENT_INLINE) {
                const inline_off = data_off + 0x15;
                const inline_size = data_size - 0x15;
                const copy_size = @min(inline_size, buffer.len - bytes_read.*);
                if (inline_off + inline_size > buf.len) continue;
                @memcpy(buffer[bytes_read.*..][0..copy_size], buf[inline_off..][0..copy_size]);
                bytes_read.* += copy_size;
                found.* = true;
            } else {
                if (data_off + 0x2D > buf.len) continue;
                const disk_bytenr = rdU64(buf, data_off + 0x15);
                const extent_offset = rdU64(buf, data_off + 0x25);
                const num_bytes = rdU64(buf, data_off + 0x2D);

                if (disk_bytenr == 0) continue;

                const copy_size = @min(@as(usize, num_bytes), buffer.len - bytes_read.*);
                const phys = self.logicalToPhysical(disk_bytenr + extent_offset) orelse continue;
                const lba = phys / self.dev.block_size;

                var read_buf: [4096]u8 = undefined;
                const read_size = @min(copy_size, read_buf.len);
                if (!self.dev.readExact(lba, read_buf[0..read_size])) continue;
                @memcpy(buffer[bytes_read.*..][0..copy_size], read_buf[0..copy_size]);
                bytes_read.* += copy_size;
                found.* = true;
            }
        }
        return true;
    }

    fn resolvePath(self: *const BtrfsFs, path: []const u8) ?u64 {
        const trimmed = std.mem.trim(u8, path, "/");
        if (trimmed.len == 0) return BTRFS_FIRST_FREE_OBJECTID;

        var current_id: u64 = BTRFS_FIRST_FREE_OBJECTID;
        var it = std.mem.splitSequence(u8, trimmed, "/");
        while (it.next()) |component| {
            if (component.len == 0) continue;
            const child_id = self.findInDir(current_id, component) orelse return null;
            current_id = child_id;
        }
        return current_id;
    }

    pub fn fs(self: *BtrfsFs) vfs.Fs {
        return .{
            .ptr = self,
            .vtable = &.{
                .open = openFn,
                .close = closeFn,
                .stat = statFn,
                .list = listFn,
                .remove = removeFn,
            },
        };
    }
};

fn listFn(ctx: *anyopaque, path: []const u8, allocator: std.mem.Allocator) ?[][]const u8 {
    const self: *BtrfsFs = @ptrCast(@alignCast(ctx));
    const id = self.resolvePath(path) orelse return null;
    const inode = self.readInode(id) orelse return null;
    if (inode.mode & 0o40000 == 0) return null;
    return self.scanDirRange(id, allocator);
}

fn openFn(ctx: *anyopaque, path: []const u8, mode: vfs.OpenMode, uid: u32, gid: u32) ?vfs.File {
    const self: *BtrfsFs = @ptrCast(@alignCast(ctx));
    if (mode.create or mode.write) return null;

    const id = self.resolvePath(path) orelse return null;
    const inode = self.readInode(id) orelse return null;
    if (inode.mode & 0o40000 != 0) return null; // directories not openable

    const file_size = @as(usize, inode.size);
    const data = self.readFileData(id, file_size) orelse return null;

    return vfs.File{
        .fs = undefined,
        .pos = 0,
        .size = file_size,
        .data = data,
        .mode = mode,
        .uid = uid,
        .gid = gid,
        .perm = @as(u16, @truncate(inode.mode & 0o777)),
    };
}

fn closeFn(ctx: *anyopaque, file: *vfs.File) void {
    const self: *BtrfsFs = @ptrCast(@alignCast(ctx));
    self.allocator.free(file.data);
    @memset(std.mem.asBytes(&file.mode), 0);
    file.data = &.{};
    file.size = 0;
}

fn statFn(ctx: *anyopaque, path: []const u8) ?vfs.FileStat {
    const self: *BtrfsFs = @ptrCast(@alignCast(ctx));
    const id = self.resolvePath(path) orelse return null;
    const inode = self.readInode(id) orelse return null;
    return vfs.FileStat{
        .size = @as(usize, inode.size),
        .mode = .{ .read = true },
        .uid = inode.uid,
        .gid = inode.gid,
        .perm = @as(u16, @truncate(inode.mode & 0o777)),
    };
}

fn removeFn(ctx: *anyopaque, path: []const u8) bool {
    _ = ctx;
    _ = path;
    return false;
}
