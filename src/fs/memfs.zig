const std = @import("std");
const vfs = @import("vfs.zig");

const MAX_FILES = 64;
const DEFAULT_PERM: u16 = 0o644; // rw-r--r--

pub const MemFs = struct {
    files: [MAX_FILES]?DirEntry = @splat(null),
    count: usize = 0,
    allocator: std.mem.Allocator,

    const DirEntry = struct {
        name: []const u8,
        data: []u8,
        size: usize,
        uid: u32,
        gid: u32,
        perm: u16,
    };

    pub fn init(allocator: std.mem.Allocator) MemFs {
        return .{ .allocator = allocator };
    }

    pub fn fs(self: *MemFs) vfs.Fs {
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

    fn find(self: *const MemFs, path: []const u8) ?usize {
        for (0..self.count) |i| {
            if (self.files[i]) |entry| {
                if (std.mem.eql(u8, entry.name, path)) return i;
            }
        }
        return null;
    }

    fn addEntry(self: *MemFs, path: []const u8, size: usize, uid: u32, gid: u32) ?usize {
        if (self.count >= MAX_FILES) return null;
        const idx = self.count;
        self.count += 1;
        const name_dup = self.allocator.alloc(u8, path.len) catch return null;
        @memcpy(name_dup, path);
        const data = self.allocator.alloc(u8, size) catch return null;
        self.files[idx] = DirEntry{
            .name = name_dup,
            .data = data,
            .size = 0,
            .uid = uid,
            .gid = gid,
            .perm = DEFAULT_PERM,
        };
        return idx;
    }
};

fn openFn(ctx: *anyopaque, path: []const u8, mode: vfs.OpenMode, uid: u32, gid: u32) ?vfs.File {
    const self: *MemFs = @ptrCast(@alignCast(ctx));
    const idx = self.find(path);

    if (mode.create) {
        if (idx) |i| {
            if (self.files[i]) |*entry| {
                if (!vfs.hasPerm(entry.perm, true, uid, entry.uid, gid, entry.gid) and
                    !vfs.hasPerm(entry.perm, false, uid, entry.uid, gid, entry.gid))
                {
                    return null;
                }
                if (mode.truncate) {
                    @memset(entry.data, 0);
                    entry.size = 0;
                }
                return vfs.File{
                    .fs = undefined,
                    .pos = 0,
                    .size = entry.size,
                    .data = entry.data,
                    .mode = mode,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .perm = entry.perm,
                };
            }
        } else {
            const new_idx = self.addEntry(path, 4096, uid, gid) orelse return null;
            if (self.files[new_idx]) |*entry| {
                return vfs.File{
                    .fs = undefined,
                    .pos = 0,
                    .size = 0,
                    .data = entry.data,
                    .mode = mode,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .perm = entry.perm,
                };
            }
        }
        return null;
    }

    const i = idx orelse return null;
    if (self.files[i]) |entry| {
        if (mode.truncate) return null;
        if (mode.read and !vfs.hasPerm(entry.perm, false, uid, entry.uid, gid, entry.gid)) return null;
        if (mode.write and !vfs.hasPerm(entry.perm, true, uid, entry.uid, gid, entry.gid)) return null;
        return vfs.File{
            .fs = undefined,
            .pos = 0,
            .size = entry.size,
            .data = entry.data,
            .mode = mode,
            .uid = entry.uid,
            .gid = entry.gid,
            .perm = entry.perm,
        };
    }
    return null;
}

fn closeFn(ctx: *anyopaque, file: *vfs.File) void {
    _ = ctx;
    _ = file;
}

fn statFn(ctx: *anyopaque, path: []const u8) ?vfs.FileStat {
    const self: *MemFs = @ptrCast(@alignCast(ctx));
    const i = self.find(path) orelse return null;
    if (self.files[i]) |entry| {
        return vfs.FileStat{
            .size = entry.size,
            .mode = .{ .read = true, .write = true },
            .uid = entry.uid,
            .gid = entry.gid,
            .perm = entry.perm,
        };
    }
    return null;
}

fn listFn(ctx: *anyopaque, path: []const u8, allocator: std.mem.Allocator) ?[][]const u8 {
    _ = path;
    const self: *MemFs = @ptrCast(@alignCast(ctx));
    const names = allocator.alloc([]const u8, self.count) catch return null;
    var written: usize = 0;
    for (0..self.count) |i| {
        if (self.files[i]) |entry| {
            names[written] = entry.name;
            written += 1;
        }
    }
    return names[0..written];
}

fn removeFn(ctx: *anyopaque, path: []const u8) bool {
    const self: *MemFs = @ptrCast(@alignCast(ctx));
    const i = self.find(path) orelse return false;
    self.files[i] = null;
    return true;
}
