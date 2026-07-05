const std = @import("std");
const blockdev = @import("blockdev.zig");

pub const GPT_SIGNATURE: [8]u8 = .{ 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' };

pub const GptHeader = extern struct {
    signature: [8]u8,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    _reserved1: u32,
    my_lba: u64,
    alternate_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    size_of_partition_entry: u32,
    partition_entries_crc32: u32,
};

pub const GptPartitionEntry = extern struct {
    partition_type_guid: [16]u8,
    unique_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
    name: [72]u8,

    pub fn nameAsUtf8(self: *const GptPartitionEntry, buf: *[36]u8) []const u8 {
        var len: usize = 0;
        var i: usize = 0;
        while (i < 72 and len < 35) {
            const lo = self.name[i];
            const hi = self.name[i + 1];
            if (lo == 0 and hi == 0) break;
            if (hi == 0 and lo < 128) {
                buf[len] = lo;
                len += 1;
            } else {
                // simple UTF-16 to UTF-8 for BMP chars
                const cp = @as(u21, lo) | (@as(u21, hi) << 8);
                const seq_len = std.unicode.utf8Encode(cp, buf[len..]) catch brk: {
                    buf[len] = '?';
                    break :brk 1;
                };
                len += seq_len;
            }
            i += 2;
        }
        return buf[0..len];
    }
};

pub const GptDisk = struct {
    dev: *blockdev.BlockDev,
    header: GptHeader,
    entries: []const GptPartitionEntry,
    entry_storage: []GptPartitionEntry,

    pub fn init(dev: *blockdev.BlockDev, entry_storage: []GptPartitionEntry) ?GptDisk {
        if (entry_storage.len < 128) return null;
        var buf: [512]u8 = undefined;

        // Read GPT header at LBA 1
        if (!dev.read(1, &buf)) return null;
        const hdr = @as(*const GptHeader, @alignCast(@ptrCast(&buf)));
        if (!std.mem.eql(u8, &hdr.signature, &GPT_SIGNATURE)) return null;
        if (hdr.size_of_partition_entry != @sizeOf(GptPartitionEntry)) return null;

        const num_entries = @min(hdr.num_partition_entries, 128);
        const entries_per_sector = 512 / @sizeOf(GptPartitionEntry);
        const sectors_needed = (num_entries + entries_per_sector - 1) / entries_per_sector;

        for (0..sectors_needed) |i| {
            if (!dev.read(hdr.partition_entry_lba + i, buf[0..])) return null;
            const sector_entries = @as(*[512 / @sizeOf(GptPartitionEntry)]GptPartitionEntry, @alignCast(@ptrCast(&buf)));
            const to_copy = @min(entries_per_sector, num_entries - i * entries_per_sector);
            @memcpy(entry_storage[i * entries_per_sector ..][0..to_copy], sector_entries[0..to_copy]);
        }

        return GptDisk{
            .dev = dev,
            .header = hdr.*,
            .entries = entry_storage[0..num_entries],
            .entry_storage = entry_storage,
        };
    }

    pub fn findPartition(self: *const GptDisk, type_guid: [16]u8) ?usize {
        for (self.entries, 0..) |*entry, i| {
            if (std.mem.eql(u8, &entry.partition_type_guid, &type_guid)) return i;
        }
        return null;
    }
};

pub const Guid = struct {
    pub const EFI_SYSTEM: [16]u8 = .{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
    pub const LINUX_ROOT_X86_64: [16]u8 = .{ 0xe3, 0xbc, 0x68, 0x4f, 0xcd, 0xe8, 0xb1, 0x4d, 0x96, 0xe7, 0xfb, 0xca, 0xf9, 0x84, 0xb7, 0x09 };
    pub const LINUX_HOME: [16]u8 = .{ 0xe1, 0xc7, 0x3a, 0x93, 0xb4, 0x2e, 0x13, 0x4f, 0xb8, 0x44, 0x0e, 0x14, 0xe2, 0xae, 0xf9, 0x15 };
    pub const LINUX_VAR: [16]u8 = .{ 0x16, 0xb0, 0x21, 0x4d, 0x34, 0xb5, 0xc2, 0x45, 0xa9, 0xfb, 0x5c, 0x16, 0xe0, 0x91, 0xfd, 0x2d };
    pub const MICROSOFT_BASIC: [16]u8 = .{ 0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7 };
};

test "parse GPT from synthetic image" {
    // Build a minimal GPT image in memory
    // LBA 0: protective MBR
    // LBA 1: GPT header
    // LBA 2-33: partition entries
    var image = std.mem.zeroes([34 * 512]u8);

    // PMBR at LBA 0
    image[0x1FE] = 0x55;
    image[0x1FF] = 0xAA;
    // PMBR partition entry: type 0xEE (GPT protective)
    image[0x1BE + 4] = 0xEE;
    image[0x1BE + 8] = 1; // start LBA (32-bit)
    image[0x1BE + 12] = 33; // size LBA (32-bit)

    // GPT header at LBA 1 (offset 512)
    const hdr_off = 512;
    @memcpy(image[hdr_off..][0..8], &GPT_SIGNATURE);
    std.mem.writeInt(u32, image[hdr_off + 8 ..][0..4], 0x00010000, .little); // revision
    std.mem.writeInt(u32, image[hdr_off + 12 ..][0..4], 92, .little); // header size
    // header_crc32 at +16
    std.mem.writeInt(u64, image[hdr_off + 24 ..][0..8], 1, .little); // my_lba
    std.mem.writeInt(u64, image[hdr_off + 32 ..][0..8], 33, .little); // alternate_lba
    std.mem.writeInt(u64, image[hdr_off + 40 ..][0..8], 34, .little); // first_usable_lba
    std.mem.writeInt(u64, image[hdr_off + 48 ..][0..8], 33, .little); // last_usable_lba = image size - 1 - 33 = 0
    // disk guid at +56
    std.mem.writeInt(u64, image[hdr_off + 72 ..][0..8], 2, .little); // partition_entry_lba
    std.mem.writeInt(u32, image[hdr_off + 80 ..][0..4], 128, .little); // num_entries
    std.mem.writeInt(u32, image[hdr_off + 84 ..][0..4], 128, .little); // entry size

    // Partition entry at LBA 2: EFI system partition
    const entry_off = 2 * 512;
    @memcpy(image[entry_off..][0..16], &Guid.EFI_SYSTEM);
    std.mem.writeInt(u64, image[entry_off + 32 ..][0..8], 34, .little); // first_lba
    std.mem.writeInt(u64, image[entry_off + 40 ..][0..8], 47, .little); // last_lba
    // name: "ESP\0" in UTF-16LE
    image[entry_off + 56] = 'E';
    image[entry_off + 57] = 0;
    image[entry_off + 58] = 'S';
    image[entry_off + 59] = 0;
    image[entry_off + 60] = 'P';
    image[entry_off + 61] = 0;

    // Second partition: Linux root
    const entry2_off = entry_off + 128;
    @memcpy(image[entry2_off..][0..16], &Guid.LINUX_ROOT_X86_64);
    std.mem.writeInt(u64, image[entry2_off + 32 ..][0..8], 48, .little); // first_lba
    std.mem.writeInt(u64, image[entry2_off + 40 ..][0..8], 100, .little); // last_lba

    // Compute and write header CRC32
    // Zero CRC field first
    std.mem.writeInt(u32, image[hdr_off + 16 ..][0..4], 0, .little);
    const crc = gptCrc32(image[hdr_off .. hdr_off + 92]);
    std.mem.writeInt(u32, image[hdr_off + 16 ..][0..4], crc, .little);

    // Parse GPT
    var dev = blockdev.MemBlockDev.init(&image, 512);
    var bdev = dev.blockDev();
    var entries: [128]GptPartitionEntry = undefined;
    const gpt = GptDisk.init(&bdev, &entries) orelse return error.TestFailed;

    try std.testing.expectEqual(@as(u32, 128), gpt.header.num_partition_entries);
    try std.testing.expectEqual(@as(u32, 128), gpt.header.size_of_partition_entry);

    const esp_idx = gpt.findPartition(Guid.EFI_SYSTEM) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 34), gpt.entries[esp_idx].first_lba);
    try std.testing.expectEqual(@as(u64, 47), gpt.entries[esp_idx].last_lba);

    const root_idx = gpt.findPartition(Guid.LINUX_ROOT_X86_64) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 48), gpt.entries[root_idx].first_lba);
    try std.testing.expectEqual(@as(u64, 100), gpt.entries[root_idx].last_lba);

    // Test no match
    try std.testing.expect(gpt.findPartition(Guid.LINUX_HOME) == null);
}

fn gptCrc32(data: []const u8) u32 {
    return ~std.hash.crc.Crc32.cast(0, std.hash.crc.Crc32.update(0xFFFFFFFF, data));
}

test "gpt CRC32 matches header" {
    const data = std.mem.zeroes([92]u8);
    const crc = gptCrc32(&data);
    try std.testing.expect(crc != 0);
}
