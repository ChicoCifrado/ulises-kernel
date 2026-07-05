const std = @import("std");
const rebrand = @import("rebrand.zig");

const psf2_magic: u32 = 0x864ab572;

fn isBigEndian() bool {
    return @import("builtin").target.cpu.arch.endian() == .big;
}

pub const Psf2Font = struct {
    glyph_width: u32,
    glyph_height: u32,
    num_glyphs: u32,
    char_size: u32,
    glyph_data: []const u8,

    pub fn init(data: []const u8) ?Psf2Font {
        if (data.len < @sizeOf(Psf2Header)) return null;
        var hdr: Psf2Header = undefined;
        @memcpy(std.mem.asBytes(&hdr), data[0..@sizeOf(Psf2Header)]);
        if (isBigEndian()) {
            if (hdr.magic != 0x864ab572) return null;
        } else {
            if (hdr.magic != psf2_magic) return null;
        }
        if (hdr.version != 0) return null;
        if (hdr.header_size < @sizeOf(Psf2Header)) return null;
        const expected_size: usize = hdr.header_size + hdr.length * hdr.charsize;
        if (data.len < expected_size) return null;
        return Psf2Font{
            .glyph_width = hdr.width,
            .glyph_height = hdr.height,
            .num_glyphs = hdr.length,
            .char_size = hdr.charsize,
            .glyph_data = data[hdr.header_size..expected_size],
        };
    }

    pub fn width(self: *const Psf2Font) u32 {
        return self.glyph_width;
    }

    pub fn height(self: *const Psf2Font) u32 {
        return self.glyph_height;
    }

    pub fn numGlyphs(self: *const Psf2Font) u32 {
        return self.num_glyphs;
    }

    pub fn glyphBytes(self: *const Psf2Font) u32 {
        return self.char_size;
    }

    pub fn getGlyph(self: *const Psf2Font, cp: u32) ?[]const u8 {
        if (cp >= self.num_glyphs) return null;
        const off = self.char_size * cp;
        return self.glyph_data[off..][0..self.char_size];
    }

    /// Blit a glyph to a framebuffer at (x, y) with given fg/bg colors.
    /// fb_pitch is bytes per scanline in the framebuffer.
    pub fn blitGlyph(self: *const Psf2Font, fb: []u8, fb_width: usize, fb_height: usize, fb_bpp: usize, x: i32, y: i32, cp: u32, fg: u32, bg: u32) void {
        const gw = self.glyph_width;
        const gh = self.glyph_height;
        const glyph = self.getGlyph(cp) orelse return;

        const bytes_per_pixel: usize = if (fb_bpp == 32) 4 else if (fb_bpp == 24) 3 else if (fb_bpp == 16) 2 else return;
        const fb_stride: usize = fb_width * bytes_per_pixel;

        for (0..gh) |row| {
            const row_data = glyph[row];
            const fy = @as(i64, @intCast(y)) + @as(i64, @intCast(row));
            if (fy < 0 or fy >= fb_height) continue;

            for (0..gw) |col| {
                const fx = @as(i64, @intCast(x)) + @as(i64, @intCast(col));
                if (fx < 0 or fx >= fb_width) continue;

                const on = (row_data >> (@as(u3, @intCast(7 - col)))) & 1;
                const color = if (on != 0) fg else bg;

                const fb_off = @as(usize, @intCast(fy)) * fb_stride + @as(usize, @intCast(fx)) * bytes_per_pixel;
                if (fb_off + 3 > fb.len) continue;

                if (bytes_per_pixel == 4) {
                    fb[fb_off + 0] = @as(u8, @truncate(color >> 16));
                    fb[fb_off + 1] = @as(u8, @truncate(color >> 8));
                    fb[fb_off + 2] = @as(u8, @truncate(color));
                    fb[fb_off + 3] = 0xFF;
                } else if (bytes_per_pixel == 3) {
                    fb[fb_off + 0] = @as(u8, @truncate(color >> 16));
                    fb[fb_off + 1] = @as(u8, @truncate(color >> 8));
                    fb[fb_off + 2] = @as(u8, @truncate(color));
                } else {
                    const rgb565 = ((@as(u16, @truncate(color >> 19)) << 11) |
                        (@as(u16, @truncate(color >> 10)) << 5) |
                        @as(u16, @truncate(color >> 3)));
                    fb[fb_off + 0] = @as(u8, @truncate(rgb565));
                    fb[fb_off + 1] = @as(u8, @truncate(rgb565 >> 8));
                }
            }
        }
    }

    /// Draw a null-terminated string starting at (x, y).
    pub fn drawText(self: *const Psf2Font, fb: []u8, fb_width: usize, fb_height: usize, fb_bpp: usize, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
        var cx = x;
        for (text) |ch| {
            if (ch == '\n') {
                cx = x;
                continue;
            }
            self.blitGlyph(fb, fb_width, fb_height, fb_bpp, cx, y, ch, fg, bg);
            cx += @as(i32, @intCast(self.glyph_width));
        }
    }
};

const Psf2Header = extern struct {
    magic: u32,
    version: u32,
    header_size: u32,
    flags: u32,
    length: u32,
    charsize: u32,
    height: u32,
    width: u32,
};

comptime {
    if (@sizeOf(Psf2Header) != 32) @compileError("Psf2Header must be 32 bytes");
}

test "parse PSF2 font" {
    // Minimal test with a small inline PSF2 font (1 glyph)
    const glyph: [16]u8 = @splat(0);
    const hdr = Psf2Header{
        .magic = psf2_magic,
        .version = 0,
        .header_size = 32,
        .flags = 0,
        .length = 1,
        .charsize = 16,
        .height = 16,
        .width = 8,
    };
    var data: [32 + 16]u8 = undefined;
    @memcpy(data[0..32], std.mem.asBytes(&hdr));
    @memcpy(data[32..], &glyph);

    const font = Psf2Font.init(&data) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 8), font.width());
    try std.testing.expectEqual(@as(u32, 16), font.height());
    try std.testing.expectEqual(@as(u32, 1), font.numGlyphs());
    try std.testing.expect(font.getGlyph(0) != null);
    try std.testing.expect(font.getGlyph(1) == null);
}
