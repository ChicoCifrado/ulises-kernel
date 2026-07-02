const std = @import("std");

pub const OpenMode = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    _padding: u4 = 0,
};

pub const FileStat = struct {
    size: usize,
    mode: OpenMode,
    uid: u32,
    gid: u32,
    perm: u16,
};

pub const File = struct {
    fs: *Fs,
    pos: usize,
    size: usize,
    data: []u8,
    mode: OpenMode,
    uid: u32,
    gid: u32,
    perm: u16,
};

pub const Fs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    current_uid: u32 = 0,
    current_gid: u32 = 0,

    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, path: []const u8, mode: OpenMode, uid: u32, gid: u32) ?File,
        close: *const fn (ctx: *anyopaque, file: *File) void,
        stat: *const fn (ctx: *anyopaque, path: []const u8) ?FileStat,
        list: *const fn (ctx: *anyopaque, path: []const u8, allocator: std.mem.Allocator) ?[][]const u8,
        remove: *const fn (ctx: *anyopaque, path: []const u8) bool,
    };

    pub fn open(self: *Fs, path: []const u8, mode: OpenMode) ?File {
        return self.vtable.open(self.ptr, path, mode, self.current_uid, self.current_gid);
    }

    pub fn close(self: *Fs, file: *File) void {
        self.vtable.close(self.ptr, file);
    }

    pub fn stat(self: *Fs, path: []const u8) ?FileStat {
        return self.vtable.stat(self.ptr, path);
    }

    pub fn list(self: *Fs, path: []const u8, allocator: std.mem.Allocator) ?[][]const u8 {
        return self.vtable.list(self.ptr, path, allocator);
    }

    pub fn remove(self: *Fs, path: []const u8) bool {
        return self.vtable.remove(self.ptr, path);
    }

    pub fn read(self: *File, buf: []u8) usize {
        const available = self.size - self.pos;
        const to_copy = @min(buf.len, available);
        @memcpy(buf[0..to_copy], self.data[self.pos..][0..to_copy]);
        self.pos += to_copy;
        return to_copy;
    }

    pub fn write(self: *File, buf: []const u8) usize {
        const available = self.data.len - self.pos;
        const to_copy = @min(buf.len, available);
        @memcpy(self.data[self.pos..][0..to_copy], buf[0..to_copy]);
        self.pos += to_copy;
        if (self.pos > self.size) self.size = self.pos;
        return to_copy;
    }
};

/// Check unix-style permission bits.
/// perm layout: bits 8-6 = owner, 5-3 = group, 2-0 = other.
/// each triplet: bit 2 = read, bit 1 = write, bit 0 = execute.
pub fn hasPerm(perm: u16, want_write: bool, caller_uid: u32, file_uid: u32, caller_gid: u32, file_gid: u32) bool {
    const shift: u3 = if (caller_uid == file_uid) 6 else if (caller_gid == file_gid) 3 else 0;
    const bits = @as(u3, @truncate(perm >> shift));
    if (want_write) return (bits & 0b010) != 0;
    return (bits & 0b100) != 0;
}

test "OpenMode flags" {
    const rw = OpenMode{ .read = true, .write = true };
    try std.testing.expect(rw.read);
    try std.testing.expect(rw.write);
    try std.testing.expect(!rw.create);
}
