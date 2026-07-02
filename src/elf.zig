const std = @import("std");

pub const ELF_MAGIC: [4]u8 = .{ 0x7F, 'E', 'L', 'F' };

pub const Class = enum(u8) {
    _32 = 1,
    _64 = 2,
};

pub const Endian = enum(u8) {
    little = 1,
    big = 2,
};

pub const Machine = enum(u16) {
    x86_64 = 0x3E,
    aarch64 = 0xB7,
    _,
};

pub const SegmentType = enum(u32) {
    null = 0,
    load = 1,
    dynamic = 2,
    interp = 3,
    note = 4,
    _,
};

pub const SegmentFlag = enum(u32) {
    execute = 1,
    write = 2,
    read = 4,
};

pub const ElfHeader = extern struct {
    ident: [16]u8,
    type_: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,

    pub fn isValid(self: *const ElfHeader) bool {
        if (!std.mem.eql(u8, self.ident[0..4], &ELF_MAGIC)) return false;
        if (self.ident[4] != @intFromEnum(Class._64)) return false;
        if (self.ident[5] != @intFromEnum(Endian.little)) return false;
        if (self.ident[6] != 1) return false;
        return true;
    }

    pub fn isExecutable(self: *const ElfHeader) bool {
        return self.type_ == 2;
    }

    pub fn getPhdr(self: *const ElfHeader, bytes: []const u8, index: usize) ?*const ProgramHeader {
        const off = self.phoff + index * self.phentsize;
        if (off + @sizeOf(ProgramHeader) > bytes.len) return null;
        return @as(*const ProgramHeader, @alignCast(@ptrCast(bytes.ptr + off)));
    }
};

pub const ProgramHeader = extern struct {
    type_: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    align_: u64,

    pub fn isLoad(self: *const ProgramHeader) bool {
        return self.type_ == @intFromEnum(SegmentType.load);
    }

    pub fn isReadable(self: *const ProgramHeader) bool {
        return self.flags & @intFromEnum(SegmentFlag.read) != 0;
    }

    pub fn isWritable(self: *const ProgramHeader) bool {
        return self.flags & @intFromEnum(SegmentFlag.write) != 0;
    }

    pub fn isExecutable(self: *const ProgramHeader) bool {
        return self.flags & @intFromEnum(SegmentFlag.execute) != 0;
    }
};

pub const LoadedSegment = struct {
    vaddr: u64,
    memsz: u64,
    filesz: u64,
    file_off: u64,
    flags: u32,
};

pub const LoadInfo = struct {
    entry: u64,
    segments: []const LoadedSegment,
};

pub fn parseElf(bytes: []const u8, segments_out: []LoadedSegment) ?LoadInfo {
    if (bytes.len < @sizeOf(ElfHeader)) return null;
    const hdr = @as(*const ElfHeader, @alignCast(@ptrCast(bytes.ptr)));
    if (!hdr.isValid()) return null;

    const phnum = hdr.phnum;
    var count: usize = 0;
    var i: usize = 0;
    while (i < phnum and count < segments_out.len) {
        const phdr = hdr.getPhdr(bytes, i) orelse return null;
        if (phdr.isLoad()) {
            segments_out[count] = .{
                .vaddr = phdr.vaddr,
                .memsz = phdr.memsz,
                .filesz = phdr.filesz,
                .file_off = phdr.offset,
                .flags = phdr.flags,
            };
            count += 1;
        }
        i += 1;
    }

    return LoadInfo{
        .entry = hdr.entry,
        .segments = segments_out[0..count],
    };
}
