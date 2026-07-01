const std = @import("std");
const rebrand = @import("rebrand.zig");
const fb_mod = @import("fb.zig");
const font_mod = @import("font.zig");

pub const Layer = enum(u8) {
    background = 0,
    wallpaper = 1,
    overlay = 10,
    hud = 20,
    cursor = 30,
};

pub const Compositor = struct {
    fb: fb_mod.FramebufferInfo,
    font: ?font_mod.Psf2Font = null,

    pub fn init(fb: fb_mod.FramebufferInfo) Compositor {
        return .{ .fb = fb };
    }

    pub fn setFont(self: *Compositor, font: font_mod.Psf2Font) void {
        self.font = font;
    }

    pub fn clear(self: *Compositor, color: u32) void {
        self.fb.clear(color);
    }

    pub fn blitBackground(self: *Compositor, bg_color: u32) void {
        _ = self;
        _ = bg_color;
        // Future: gradient, pattern, or multi-layer background
    }

    pub fn blitWallpaper(self: *Compositor, ppm_data: []const u8) void {
        if (!self.fb.isValid()) return;
        // Scale wallpaper to fill framebuffer
        self.fb.blitPpm(ppm_data, 0, 0, self.fb.width, self.fb.height);
    }

    pub fn drawText(self: *Compositor, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
        const f = self.font orelse return;
        if (!self.fb.isValid()) return;
        f.drawText(
            self.fb.asSlice().?,
            self.fb.width,
            self.fb.height,
            self.fb.bpp,
            x, y, text, fg, bg,
        );
    }

    pub fn drawProgressBar(self: *Compositor, x: u32, y: u32, w: u32, h: u32, progress: f32, bar_color: u32, bg_color: u32) void {
        const fb = self.fb.asSlice() orelse return;
        const bytes_per_pixel: usize = if (self.fb.bpp == 32) 4 else if (self.fb.bpp == 24) 3 else return;
        const stride: usize = self.fb.pitch;

        // Background bar
        for (0..h) |row| {
            for (0..w) |col| {
                const px = x + col;
                const py = y + row;
                if (px >= self.fb.width or py >= self.fb.height) continue;
                const off = py * stride + px * bytes_per_pixel;
                if (off + 2 >= fb.len) continue;
                const c = if (@as(f32, @floatFromInt(col)) < @as(f32, @floatFromInt(w)) * progress) bar_color else bg_color;
                fb[off + 0] = @as(u8, @truncate(c >> 16));
                fb[off + 1] = @as(u8, @truncate(c >> 8));
                fb[off + 2] = @as(u8, @truncate(c));
                if (bytes_per_pixel == 4 and off + 3 < fb.len) fb[off + 3] = 0xFF;
            }
        }
    }

    pub fn present(self: *Compositor) void {
        _ = self;
        // Future: double-buffering, page flip, damage tracking
    }
};
