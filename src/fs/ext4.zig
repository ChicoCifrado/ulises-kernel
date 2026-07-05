const std = @import("std");
const vfs = @import("vfs.zig");
const blockdev = @import("blockdev.zig");

const EXT4_SUPER_MAGIC = 0xEF53;
const EXT4_GOOD_OLD_REV = 0;
const EXT4_DYNAMIC_REV = 1;

const EXT4_FT_UNKNOWN = 0;
const EXT4_FT_REG_FILE = 1;
const EXT4_FT_DIR = 2;
const EXT4_FT_CHRDEV = 3;
const EXT4_FT_BLKDEV = 4;
const EXT4_FT_FIFO = 5;
const EXT4_FT_SOCK = 6;
const EXT4_FT_SYMLINK = 7;

const EXT4_INODE_MODE_REG = 0o100000;
const EXT4_INODE_MODE_DIR = 0o40000;
const EXT4_INODE_MODE_LNK = 0o120000;

const EXTENT_MAGIC = 0xF30A;

const EXT4_ROOT_INO = 2;

const SuperBlock = extern struct {
    inodes_count: u32,
    blocks_count_lo: u32,
    r_blocks_count_lo: u32,
    free_blocks_count_lo: u32,
    free_inodes_count_lo: u32,
    first_data_block: u32,
    log_block_size: u32,
    log_cluster_size: u32,
    blocks_per_group: u32,
    clusters_per_group: u32,
    inodes_per_group: u32,
    mount_time: u32,
    write_time: u32,
    mount_count: u16,
    max_mount_count: u16,
    magic: u16,
    state: u16,
    errors: u16,
    minor_rev_level: u16,
    lastcheck_time: u32,
    check_interval: u32,
    creator_os: u32,
    rev_level: u32,
    def_uid: u16,
    def_gid: u16,
    first_ino: u32,
    inode_size: u16,
    block_group_nr: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    uuid: [16]u8,
    volume_name: [16]u8,
    last_mounted: [64]u8,
    algorithm_usage_bitmap: u32,
    prealloc_blocks: u8,
    prealloc_dir_blocks: u8,
    reserved_gdt_blocks: u16,
    journal_uuid: [16]u8,
    journal_inum: u32,
    journal_dev: u32,
    last_orphan: u32,
    hash_seed: [4]u32,
    def_hash_version: u8,
    jnl_backup_type: u8,
    desc_size: u16,
    default_mount_opts: u32,
    first_meta_bg: u32,
    mkfs_time: u32,
    jnl_blocks: [17]u32,
    blocks_count_hi: u32,
    r_blocks_count_hi: u32,
    free_blocks_count_hi: u32,
    min_extra_isize: u16,
    wanted_extra_isize: u16,
    flags: u32,
    raid_stride: u16,
    mmp_interval: u16,
    mmp_block: u64,
    raid_stripe_width: u32,
    log_groups_per_flex: u8,
    checksum_type: u8,
    reserved_pad: u16,
    kbytes_written: u64,
    snapshot_inum: u32,
    snapshot_id: u32,
    snapshot_r_blocks: u64,
    snapshot_list: u32,
    error_count: u32,
    first_error_time: u32,
    first_error_ino: u32,
    first_error_block: u64,
    first_error_func: [32]u8,
    first_error_line: u32,
    last_error_time: u32,
    last_error_ino: u32,
    last_error_line: u32,
    last_error_block: u64,
    last_error_func: [32]u8,
    mount_opts: [64]u8,
    usr_quota_inum: u32,
    grp_quota_inum: u32,
    overhead_blocks: u32,
    backbks_timestamp: [4]u32,
    encrypt_algos: [4]u8,
    encrypt_pw_salt: [16]u8,
    lpf_ino: u32,
    prj_quota_inum: u32,
    checksum_seed: u32,
    reserved: [98]u8,
};

const BlockGroupDesc = extern struct {
    block_bitmap_lo: u32,
    inode_bitmap_lo: u32,
    inode_table_lo: u32,
    free_blocks_count_lo: u16,
    free_inodes_count_lo: u16,
    used_dirs_count_lo: u16,
    flags: u16,
    exclude_bitmap_lo: u32,
    block_bitmap_csum: u16,
    inode_bitmap_csum: u16,
    itable_unused_lo: u16,
    checksum: u16,
};

const Inode = extern struct {
    mode: u16,
    uid_lo: u16,
    size_lo: u32,
    atime: u32,
    ctime: u32,
    mtime: u32,
    dtime: u32,
    gid_lo: u16,
    links_count: u16,
    blocks_lo: u32,
    flags: u32,
    osd1: u32,
    block: [15]u32,
    generation: u32,
    file_acl_lo: u32,
    size_hi: u32,
    obso_faddr: u32,
    osd2: [12]u8,
    extra_isize: u16,
    checksum_hi: u16,
    ctime_extra: u32,
    mtime_extra: u32,
    atime_extra: u32,
    crtime: u32,
    crtime_extra: u32,
    version_hi: u32,
    projid: u32,
};

const ExtentHeader = extern struct {
    magic: u16,
    entries: u16,
    max: u16,
    depth: u16,
    generation: u32,
};

const Extent = extern struct {
    block: u32,
    len: u16,
    start_hi: u16,
    start_lo: u32,
};

const ExtentIdx = extern struct {
    block: u32,
    leaf_lo: u32,
    leaf_hi: u16,
    unused: u16,
};

const DirEntry2 = extern struct {
    inode: u32,
    rec_len: u16,
    name_len: u8,
    file_type: u8,
};

pub const Ext4Fs = struct {
    dev: *blockdev.BlockDev,
    allocator: std.mem.Allocator,
    sb: SuperBlock,
    block_size: usize,
    inode_size: usize,
    bgd_block: u64,
    bgd_len: usize,
    bgds: []u8,

    pub fn init(dev: *blockdev.BlockDev, allocator: std.mem.Allocator) ?Ext4Fs {
        var buf: [4096]u8 align(@alignOf(SuperBlock)) = undefined;
        const sb_lba = 1024 / dev.block_size;
        const sb_offset = 1024 % dev.block_size;
        if (!dev.readExact(sb_lba, buf[0..4096])) return null;
        const sb = @as(*const SuperBlock, @ptrCast(@alignCast(&buf[sb_offset])));
        if (sb.magic != EXT4_SUPER_MAGIC) return null;

        const block_size: u32 = @as(u32, 1024) << @as(u5, @intCast(sb.log_block_size & 0x1F));
        const inode_size = if (sb.rev_level == EXT4_DYNAMIC_REV) @as(usize, sb.inode_size) else 128;

        const num_bgs = (sb.inodes_count + sb.inodes_per_group - 1) / sb.inodes_per_group;
        const desc_size = if (sb.desc_size != 0) @as(usize, sb.desc_size) else @sizeOf(BlockGroupDesc);

        const bgd_block_no = if (block_size == 1024) @as(u64, 2) else 1;
        const bgd_bytes = num_bgs * desc_size;
        const bgd_blocks = (bgd_bytes + block_size - 1) / block_size;

        const bgd = allocator.alloc(u8, bgd_blocks * block_size) catch return null;

        var off: u64 = 0;
        var blk = bgd_block_no;
        while (off < bgd_bytes) {
            const lba = blk * (block_size / dev.block_size);
            if (!dev.readExact(lba, bgd[off..][0..block_size])) {
                allocator.free(bgd);
                return null;
            }
            off += block_size;
            blk += 1;
        }

        return Ext4Fs{
            .dev = dev,
            .allocator = allocator,
            .sb = sb.*,
            .block_size = block_size,
            .inode_size = inode_size,
            .bgd_block = bgd_block_no,
            .bgd_len = bgd_blocks * block_size,
            .bgds = bgd,
        };
    }

    pub fn deinit(self: *Ext4Fs) void {
        self.allocator.free(self.bgds);
    }

    fn blockGroupOfInode(self: *const Ext4Fs, inode_no: u32) struct { group: u32, index: u32 } {
        const group = (inode_no - 1) / self.sb.inodes_per_group;
        const index = (inode_no - 1) % self.sb.inodes_per_group;
        return .{ .group = group, .index = index };
    }

    fn readBlock(self: *const Ext4Fs, block_no: u64, buffer: []u8) bool {
        // Translate ext4 block_no to device LBA.
        const scale = self.block_size / self.dev.block_size;
        return self.dev.readExact(block_no * scale, buffer);
    }

    fn getBgd(self: *const Ext4Fs, index: usize) ?BlockGroupDesc {
        const dsz = if (self.sb.desc_size != 0) @as(usize, self.sb.desc_size) else @sizeOf(BlockGroupDesc);
        const off = index * dsz;
        if (off + @sizeOf(BlockGroupDesc) > self.bgds.len) return null;
        var bg: BlockGroupDesc = undefined;
        @memcpy(std.mem.asBytes(&bg), self.bgds[off..][0..@sizeOf(BlockGroupDesc)]);
        return bg;
    }

    fn readInode(self: *const Ext4Fs, inode_no: u32) ?Inode {
        const gi = self.blockGroupOfInode(inode_no);
        const bg = self.getBgd(gi.group) orelse return null;
        const table_block = bg.inode_table_lo;
        const byte_offset = gi.index * self.inode_size;

        const block_no = table_block + byte_offset / self.block_size;
        const in_block_off = byte_offset % self.block_size;

        var buf: [4096]u8 align(@alignOf(Inode)) = undefined;
        if (buf.len < self.block_size) return null;
        if (!self.readBlock(block_no, buf[0..self.block_size])) return null;

        const inode_bytes = buf[in_block_off..][0..@min(self.inode_size, @sizeOf(Inode))];
        var inode: Inode = undefined;
        @memcpy(std.mem.asBytes(&inode)[0..inode_bytes.len], inode_bytes);
        return inode;
    }

    fn readExtentBlocks(self: *const Ext4Fs, inode: *const Inode, file_size: usize) ?[]u8 {
        const full_blocks = (file_size + self.block_size - 1) / self.block_size;
        const alloc_size = full_blocks * self.block_size;
        const data = self.allocator.alloc(u8, alloc_size) catch return null;

        var buf: [4096]u8 align(@alignOf(ExtentIdx)) = undefined;
        const buf_size = @min(buf.len, self.block_size);

        const eh = @as(*const ExtentHeader, @ptrCast(@alignCast(&inode.block[0])));
        if (eh.magic != EXTENT_MAGIC) {
            self.allocator.free(data);
            return null;
        }

        var remaining = file_size;
        var dest_off: usize = 0;
        var logical_block: u32 = 0;

        if (eh.depth == 0) {
            const extents = @as([*]const Extent, @ptrCast(&inode.block[3]));
            const count = @min(@as(usize, eh.entries), (60 - @sizeOf(ExtentHeader)) / @sizeOf(Extent));
            for (0..count) |i| {
                if (remaining == 0) break;
                const ex = extents[i];
                const ext_len = @as(usize, if (ex.len & 0x8000 != 0) 0x8000 else ex.len);
                const ext_start = (@as(u64, ex.start_hi) << 32) | ex.start_lo;
                const ext_bytes = ext_len * self.block_size;
                const to_read = @min(ext_bytes, remaining);
                const blocks_needed = (to_read + self.block_size - 1) / self.block_size;

                for (0..blocks_needed) |b| {
                    if (!self.readBlock(ext_start + b, data[dest_off..][0..self.block_size])) {
                        self.allocator.free(data);
                        return null;
                    }
                    dest_off += self.block_size;
                }
                remaining -|= to_read;
                logical_block += @as(u32, @intCast(ext_len));
            }
        } else {
            var depth = eh.depth;
            const max_inline_idx = (60 - @sizeOf(ExtentHeader)) / @sizeOf(ExtentIdx);
            var idx_table = @as([*]const ExtentIdx, @ptrCast(@alignCast(&inode.block[3])));
            var idx_count: usize = if (@as(usize, eh.entries) < max_inline_idx) @as(usize, eh.entries) else max_inline_idx;
            var idx_block_no: u64 = 0;

            while (depth > 0) {
                var best_idx: usize = 0;
                for (0..idx_count) |j| {
                    if (idx_table[j].block <= logical_block) {
                        best_idx = j;
                    }
                }
                const idx = idx_table[best_idx];
                const leaf_phys = (@as(u64, idx.leaf_hi) << 32) | idx.leaf_lo;

                if (depth == 1) {
                    idx_block_no = leaf_phys;
                    break;
                }

                if (!self.readBlock(leaf_phys, buf[0..buf_size])) {
                    self.allocator.free(data);
                    return null;
                }
                const child_eh = @as(*const ExtentHeader, @ptrCast(@alignCast(&buf[0])));
                if (child_eh.magic != EXTENT_MAGIC) {
                    self.allocator.free(data);
                    return null;
                }
                idx_table = @as([*]const ExtentIdx, @ptrCast(@alignCast(&buf[@sizeOf(ExtentHeader)])));
                const max_idx_per_block = (@as(usize, self.block_size) - @sizeOf(ExtentHeader)) / @sizeOf(ExtentIdx);
                idx_count = if (@as(usize, child_eh.entries) < max_idx_per_block) @as(usize, child_eh.entries) else max_idx_per_block;
                depth = child_eh.depth;
            }

            if (idx_block_no != 0) {
                if (!self.readBlock(idx_block_no, buf[0..buf_size])) {
                    self.allocator.free(data);
                    return null;
                }
                const leaf_eh = @as(*const ExtentHeader, @ptrCast(@alignCast(&buf[0])));
                if (leaf_eh.magic != EXTENT_MAGIC) {
                    self.allocator.free(data);
                    return null;
                }
                const extents = @as([*]const Extent, @ptrCast(@alignCast(&buf[@sizeOf(ExtentHeader)])));
                const max_ext_per_block = (@as(usize, self.block_size) - @sizeOf(ExtentHeader)) / @sizeOf(Extent);
                const count = if (@as(usize, leaf_eh.entries) < max_ext_per_block) @as(usize, leaf_eh.entries) else max_ext_per_block;
                for (0..count) |i| {
                    if (remaining == 0) break;
                    const ex = extents[i];
                    if (ex.block > logical_block) continue;
                    const ext_len = @as(usize, if (ex.len & 0x8000 != 0) 0x8000 else ex.len);
                    const ext_start = (@as(u64, ex.start_hi) << 32) | ex.start_lo;
                    const ext_bytes = ext_len * self.block_size;
                    const to_read = @min(ext_bytes, remaining);
                    const blocks_needed = (to_read + self.block_size - 1) / self.block_size;
                    for (0..blocks_needed) |b| {
                        if (!self.readBlock(ext_start + b, data[dest_off..][0..self.block_size])) {
                            self.allocator.free(data);
                            return null;
                        }
                        dest_off += self.block_size;
                    }
                    remaining -|= to_read;
                logical_block += @as(u32, @intCast(ext_len));
                }
            }
        }

        return data[0..file_size];
    }

    fn findInDir(self: *const Ext4Fs, dir_ino: u32, name: []const u8) ?u32 {
        const inode = self.readInode(dir_ino) orelse return null;
        if (inode.mode & EXT4_INODE_MODE_DIR == 0) return null;

        const file_size: usize = (@as(u64, inode.size_hi) << 32) | inode.size_lo;
        const data = self.readExtentBlocks(&inode, file_size) orelse return null;
        defer self.allocator.free(data);

        var off: usize = 0;
        while (off + @sizeOf(DirEntry2) <= data.len) {
            var de: DirEntry2 = undefined;
            @memcpy(std.mem.asBytes(&de)[0..@sizeOf(DirEntry2)], data[off..][0..@sizeOf(DirEntry2)]);
            if (de.inode != 0 and de.name_len == name.len) {
                const entry_name = data[off + @sizeOf(DirEntry2) .. off + @sizeOf(DirEntry2) + de.name_len];
                if (std.mem.eql(u8, entry_name, name)) {
                    return de.inode;
                }
            }
            if (de.rec_len == 0) break;
            off += de.rec_len;
        }
        return null;
    }

    fn resolvePath(self: *const Ext4Fs, path: []const u8) ?u32 {
        if (path.len == 0) return null;
        var ino: u32 = EXT4_ROOT_INO;

        var trimmed = path;
        while (trimmed.len > 0 and trimmed[0] == '/') {
            trimmed = trimmed[1..];
        }
        if (trimmed.len == 0) return ino;

        var it = std.mem.splitScalar(u8, trimmed, '/');
        while (it.next()) |component| {
            if (component.len == 0) continue;
            ino = self.findInDir(ino, component) orelse return null;
        }
        return ino;
    }

    fn readFile(self: *const Ext4Fs, ino: u32) ?struct { data: []u8, size: usize } {
        const inode = self.readInode(ino) orelse return null;
        const file_size: usize = (@as(u64, inode.size_hi) << 32) | inode.size_lo;
        const data = self.readExtentBlocks(&inode, file_size) orelse return null;
        return .{ .data = data, .size = file_size };
    }

    pub fn fs(self: *Ext4Fs) vfs.Fs {
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

fn openFn(ctx: *anyopaque, path: []const u8, mode: vfs.OpenMode, uid: u32, gid: u32) ?vfs.File {
    _ = uid;
    _ = gid;
    const self: *Ext4Fs = @ptrCast(@alignCast(ctx));
    if (mode.write or mode.create or mode.truncate) return null;
    const ino = self.resolvePath(path) orelse return null;
    const inode = self.readInode(ino) orelse return null;
    if (inode.mode & EXT4_INODE_MODE_DIR != 0) return null;

    const fr = self.readFile(ino) orelse return null;
    return vfs.File{
        .fs = undefined,
        .pos = 0,
        .size = fr.size,
        .data = fr.data,
        .mode = mode,
        .uid = 0,
        .gid = 0,
        .perm = 0o444,
    };
}

fn closeFn(ctx: *anyopaque, file: *vfs.File) void {
    _ = ctx;
    const allocator = @import("../mem/global.zig").get();
    allocator.free(file.data);
}

fn statFn(ctx: *anyopaque, path: []const u8) ?vfs.FileStat {
    const self: *Ext4Fs = @ptrCast(@alignCast(ctx));
    const ino = self.resolvePath(path) orelse return null;
    const inode = self.readInode(ino) orelse return null;
    const file_size: usize = (@as(u64, inode.size_hi) << 32) | inode.size_lo;
    return vfs.FileStat{
        .size = file_size,
        .mode = .{ .read = true },
        .uid = inode.uid_lo,
        .gid = inode.gid_lo,
        .perm = @as(u16, @truncate(inode.mode & 0x1FF)),
    };
}

fn listFn(ctx: *anyopaque, path: []const u8, allocator: std.mem.Allocator) ?[][]const u8 {
    const self: *Ext4Fs = @ptrCast(@alignCast(ctx));
    const ino = self.resolvePath(path) orelse return null;
    const inode = self.readInode(ino) orelse return null;
    if (inode.mode & EXT4_INODE_MODE_DIR == 0) return null;

    const file_size: usize = (@as(u64, inode.size_hi) << 32) | inode.size_lo;
    const data = self.readExtentBlocks(&inode, file_size) orelse return null;
    defer self.allocator.free(data);

    var name_buf = allocator.alloc([]const u8, 256) catch return null;
    var name_count: usize = 0;

    var off: usize = 0;
    while (off + @sizeOf(DirEntry2) <= data.len and name_count < name_buf.len) {
        var de: DirEntry2 = undefined;
        @memcpy(std.mem.asBytes(&de)[0..@sizeOf(DirEntry2)], data[off..][0..@sizeOf(DirEntry2)]);
        if (de.inode != 0 and de.name_len > 0) {
            const name = data[off + @sizeOf(DirEntry2) .. off + @sizeOf(DirEntry2) + de.name_len];
            const dup = allocator.alloc(u8, name.len) catch {
                for (0..name_count) |j| allocator.free(name_buf[j]);
                allocator.free(name_buf);
                return null;
            };
            @memcpy(dup, name);
            name_buf[name_count] = dup;
            name_count += 1;
        }
        if (de.rec_len == 0) break;
        off += de.rec_len;
    }
    return name_buf[0..name_count];
}

fn removeFn(ctx: *anyopaque, path: []const u8) bool {
    _ = ctx;
    _ = path;
    return false;
}
