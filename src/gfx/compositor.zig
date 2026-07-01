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
        const slice = self.fb.asSlice() orelse return;
        f.drawText(
            slice,
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

test "init compositor" {
    const fb = fb_mod.FramebufferInfo{ .addr = 0, .pitch = 0, .width = 0, .height = 0, .bpp = 0, .type = 0 };
    var comp = Compositor.init(fb);
    try std.testing.expect(comp.font == null);
    try std.testing.expect(!comp.fb.isValid());
}

test "clear compositor" {
    var buf: [64 * 4]u8 = undefined;
    const fb = fb_mod.FramebufferInfo{
        .addr = @intFromPtr(&buf),
        .pitch = 64 * 4,
        .width = 64,
        .height = 1,
        .bpp = 32,
        .type = 1,
    };
    var comp = Compositor.init(fb);
    comp.clear(0xFF0000);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[2]);
}

test "drawProgressBar 50%" {
    var buf: [64 * 4]u8 = undefined;
    @memset(&buf, 0x00);
    const fb = fb_mod.FramebufferInfo{
        .addr = @intFromPtr(&buf),
        .pitch = 64 * 4,
        .width = 64,
        .height = 1,
        .bpp = 32,
        .type = 1,
    };
    var comp = Compositor.init(fb);
    comp.drawProgressBar(0, 0, 64, 1, 0.5, 0x199FFF, 0x3D4450);
    // Column 31 (before 50%) should be accent color
    try std.testing.expectEqual(@as(u8, 0x19), buf[31 * 4 + 0]);
    try std.testing.expectEqual(@as(u8, 0x9F), buf[31 * 4 + 1]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[31 * 4 + 2]);
    // Column 32 (at 50%) should be bg color
    try std.testing.expectEqual(@as(u8, 0x3D), buf[32 * 4 + 0]);
    try std.testing.expectEqual(@as(u8, 0x44), buf[32 * 4 + 1]);
    try std.testing.expectEqual(@as(u8, 0x50), buf[32 * 4 + 2]);
}

test "drawProgressBar 0% and 100%" {
    var buf: [64 * 4]u8 = undefined;
    @memset(&buf, 0x00);
    const fb = fb_mod.FramebufferInfo{
        .addr = @intFromPtr(&buf),
        .pitch = 64 * 4,
        .width = 64,
        .height = 1,
        .bpp = 32,
        .type = 1,
    };
    var comp = Compositor.init(fb);
    comp.drawProgressBar(0, 0, 64, 1, 0.0, 0x199FFF, 0x3D4450);
    // Column 0 should be bg at 0%
    try std.testing.expectEqual(@as(u8, 0x3D), buf[0]);

    @memset(&buf, 0x00);
    comp.drawProgressBar(0, 0, 64, 1, 1.0, 0x199FFF, 0x3D4450);
    // Last column should be accent at 100%
    try std.testing.expectEqual(@as(u8, 0x19), buf[63 * 4 + 0]);
}

test "blitWallpaper 2x2" {
    var buf: [4 * 4 * 4]u8 = undefined;
    @memset(&buf, 0x00);
    const fb = fb_mod.FramebufferInfo{
        .addr = @intFromPtr(&buf),
        .pitch = 4 * 4,
        .width = 4,
        .height = 4,
        .bpp = 32,
        .type = 1,
    };
    var comp = Compositor.init(fb);
    const ppm = "P6\n2 2\n255\n\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\xFF\xFF\xFF";
    comp.blitWallpaper(ppm);
    // Top-left should be red
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[2]);
}
