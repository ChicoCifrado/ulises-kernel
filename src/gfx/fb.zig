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
        const size = self.pitch * self.height;
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
