const std = @import("std");

pub const FramebufferInfo = struct {
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    type: u8,

    pub fn isValid(self: *const FramebufferInfo) bool {
        return self.addr != 0 and self.width > 0 and self.height > 0;
    }

    pub fn asSlice(self: *const FramebufferInfo) ?[]u8 {
        const size = @as(usize, self.pitch) * @as(usize, self.height);
        return @as([*]u8, @ptrFromInt(@as(usize, @intCast(self.addr))))[0..size];
    }

    pub fn clear(self: *const FramebufferInfo, color: u32) void {
        const fb = self.asSlice() orelse return;
        const bytes_per_pixel: usize = if (self.bpp == 32) 4 else if (self.bpp == 24) 3 else if (self.bpp == 16) 2 else return;
        const r = @as(u8, @truncate(color >> 16));
        const g = @as(u8, @truncate(color >> 8));
        const b = @as(u8, @truncate(color));

        if (bytes_per_pixel == 4) {
            var i: usize = 0;
            while (i < fb.len) {
                fb[i + 0] = r;
                fb[i + 1] = g;
                fb[i + 2] = b;
                fb[i + 3] = 0xFF;
                i += 4;
            }
        } else if (bytes_per_pixel == 3) {
            var i: usize = 0;
            while (i < fb.len) {
                fb[i + 0] = r;
                fb[i + 1] = g;
                fb[i + 2] = b;
                i += 3;
            }
        }
    }

    /// Blit a PPM image (P6 format) to the framebuffer at (dx, dy), scaling to (dw, dh).
    pub fn blitPpm(self: *const FramebufferInfo, ppm_data: []const u8, dx: u32, dy: u32, dw: u32, dh: u32) void {
        const fb = self.asSlice() orelse return;
        const fb_bpp = self.bpp;

        // Parse P6 header: "P6\n{width} {height}\n{maxval}\n"
        if (ppm_data.len < 15) return;
        if (ppm_data[0] != 'P' or ppm_data[1] != '6') return;

        var pos: usize = 3;
        while (pos < ppm_data.len and ppm_data[pos] == '#') {
            while (pos < ppm_data.len and ppm_data[pos] != '\n') pos += 1;
            pos += 1;
        }
        const w = readDec(ppm_data, &pos) orelse return;
        if (pos >= ppm_data.len or ppm_data[pos] != ' ') return;
        pos += 1;
        const h = readDec(ppm_data, &pos) orelse return;
        if (pos >= ppm_data.len or ppm_data[pos] != '\n') return;
        pos += 1;
        const maxval = readDec(ppm_data, &pos) orelse return;
        _ = maxval;
        if (pos >= ppm_data.len or ppm_data[pos] != '\n') return;
        pos += 1;

        const ppm_pixels = ppm_data[pos..];
        const fb_stride: usize = self.pitch;
        const bytes_per_pixel: usize = if (fb_bpp == 32) 4 else if (fb_bpp == 24) 3 else return;

        for (0..@as(usize, @min(dh, h))) |sy| {
            for (0..@as(usize, @min(dw, w))) |sx| {
                const px = dx + sx;
                const py = dy + sy;
                if (px >= self.width or py >= self.height) continue;

                const ppm_off = (sy * w + sx) * 3;
                if (ppm_off + 2 >= ppm_pixels.len) continue;

                const fb_off = py * fb_stride + px * bytes_per_pixel;
                if (fb_off + 2 >= fb.len) continue;

                fb[fb_off + 0] = ppm_pixels[ppm_off + 0];
                fb[fb_off + 1] = ppm_pixels[ppm_off + 1];
                fb[fb_off + 2] = ppm_pixels[ppm_off + 2];
                if (bytes_per_pixel == 4) {
                    if (fb_off + 3 < fb.len) fb[fb_off + 3] = 0xFF;
                }
            }
        }
    }

    fn readDec(data: []const u8, pos: *usize) ?u32 {
        // Skip whitespace
        while (pos.* < data.len and (data[pos.*] == ' ' or data[pos.*] == '\n' or data[pos.*] == '\r' or data[pos.*] == '\t')) {
            pos.* += 1;
        }
        var val: u32 = 0;
        var found = false;
        while (pos.* < data.len) {
            const c = data[pos.*];
            if (c >= '0' and c <= '9') {
                val = val * 10 + (c - '0');
                found = true;
                pos.* += 1;
            } else break;
        }
        if (!found) return null;
        return val;
    }
};

test "isValid zero addr" {
    const fb = FramebufferInfo{ .addr = 0, .pitch = 0, .width = 0, .height = 0, .bpp = 0, .type = 0 };
    try std.testing.expect(!fb.isValid());
}

test "isValid valid" {
    const fb = FramebufferInfo{ .addr = 0x1000, .pitch = 2560, .width = 640, .height = 480, .bpp = 32, .type = 1 };
    try std.testing.expect(fb.isValid());
}

test "clear 32bpp" {
    var buf: [64 * 4]u8 = undefined;
    var fb = FramebufferInfo{
        .addr = @intFromPtr(&buf),
        .pitch = 64 * 4,
        .width = 64,
        .height = 1,
        .bpp = 32,
        .type = 1,
    };
    fb.clear(0xAABBCC);
    for (0..64) |i| {
        try std.testing.expectEqual(@as(u8, 0xAA), buf[i * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 0xBB), buf[i * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 0xCC), buf[i * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 0xFF), buf[i * 4 + 3]);
    }
}

test "clear 24bpp" {
    var buf: [64 * 3]u8 = undefined;
    var fb = FramebufferInfo{
        .addr = @intFromPtr(&buf),
        .pitch = 64 * 3,
        .width = 64,
        .height = 1,
        .bpp = 24,
        .type = 1,
    };
    fb.clear(0xAABBCC);
    for (0..64) |i| {
        try std.testing.expectEqual(@as(u8, 0xAA), buf[i * 3 + 0]);
        try std.testing.expectEqual(@as(u8, 0xBB), buf[i * 3 + 1]);
        try std.testing.expectEqual(@as(u8, 0xCC), buf[i * 3 + 2]);
    }
}

test "blitPpm 2x2" {
    var buf: [4 * 4 * 4]u8 = undefined;
    @memset(&buf, 0x00);
    var fb = FramebufferInfo{
        .addr = @intFromPtr(&buf),
        .pitch = 4 * 4,
        .width = 4,
        .height = 4,
        .bpp = 32,
        .type = 1,
    };

    // Create a minimal PPM (2x2, red + green + blue + white)
    const ppm = "P6\n2 2\n255\n" ++
        "\xFF\x00\x00" ++ // (0,0) red
        "\x00\xFF\x00" ++ // (1,0) green
        "\x00\x00\xFF" ++ // (0,1) blue
        "\xFF\xFF\xFF";   // (1,1) white
    fb.blitPpm(ppm, 0, 0, 4, 4);
    // Top-left (red) at fb[0..3]
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[2]);
    // Top-right (green) at fb[4..7]
    try std.testing.expectEqual(@as(u8, 0x00), buf[4]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[5]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[6]);
    // Bottom-left (blue) at fb[16..19]
    try std.testing.expectEqual(@as(u8, 0x00), buf[16]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[17]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[18]);
    // Bottom-right (white) at fb[20..23]
    try std.testing.expectEqual(@as(u8, 0xFF), buf[20]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[21]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[22]);
}

test "readDec basic" {
    var pos: usize = 0;
    const data = "123 456";
    try std.testing.expectEqual(@as(u32, 123), FramebufferInfo.readDec(data, &pos));
    try std.testing.expectEqual(@as(u32, 456), FramebufferInfo.readDec(data, &pos));
    try std.testing.expect(FramebufferInfo.readDec(data, &pos) == null);
}

test "readDec invalid" {
    var pos: usize = 0;
    try std.testing.expect(FramebufferInfo.readDec("abc", &pos) == null);
}
