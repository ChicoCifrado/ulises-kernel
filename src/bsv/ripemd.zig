const std = @import("std");

const R = [_]u32{
    0x00000000, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e,
};

const Rp = [_]u32{
    0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0x00000000,
};

pub const Ripemd160 = struct {
    state: [5]u32,
    buf: [64]u8,
    buf_len: usize,
    total_len: u64,

    pub fn init(_: @TypeOf(.{})) Ripemd160 {
        return .{
            .state = [_]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    pub fn update(self: *Ripemd160, data: []const u8) void {
        var offset: usize = 0;
        while (offset < data.len) {
            const space = 64 - self.buf_len;
            const to_copy = @min(space, data.len - offset);
            @memcpy(self.buf[self.buf_len..][0..to_copy], data[offset..][0..to_copy]);
            self.buf_len += to_copy;
            offset += to_copy;
            self.total_len += to_copy;
            if (self.buf_len == 64) {
                compress(&self.state, &self.buf);
                self.buf_len = 0;
            }
        }
    }

    pub fn final(self: *Ripemd160) [20]u8 {
        const bits = self.total_len * 8;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;

        if (self.buf_len > 56) {
            @memset(self.buf[self.buf_len..], 0);
            compress(&self.state, &self.buf);
            self.buf_len = 0;
        }

        @memset(self.buf[self.buf_len..], 0);
        var i: usize = 56;
        while (i < 64) : (i += 1) {
            self.buf[i] = @truncate(bits >> @as(u6, @intCast((i - 56) * 8)));
        }

        compress(&self.state, &self.buf);

        var result: [20]u8 = undefined;
        for (self.state, 0..) |s, j| {
            result[j * 4 + 0] = @truncate(s);
            result[j * 4 + 1] = @truncate(s >> 8);
            result[j * 4 + 2] = @truncate(s >> 16);
            result[j * 4 + 3] = @truncate(s >> 24);
        }
        return result;
    }

    fn compress(state: *[5]u32, block: *const [64]u8) void {
        var w: [16]u32 = undefined;
        for (0..16) |i| {
            w[i] = @as(u32, block[i * 4]) |
                @as(u32, block[i * 4 + 1]) << 8 |
                @as(u32, block[i * 4 + 2]) << 16 |
                @as(u32, block[i * 4 + 3]) << 24;
        }

        var al = state[0];
        var bl = state[1];
        var cl = state[2];
        var dl = state[3];
        var el = state[4];
        var ar = state[0];
        var br = state[1];
        var cr = state[2];
        var dr = state[3];
        var er = state[4];

        for (0..80) |j| {
            const word_idx = roundWordIndex(j);
            const rot = roundRotations(j);
            const tl = roundF(j, bl, cl, dl) +% al +% w[word_idx] +% R[j / 16];
            al = el;
            el = dl;
            dl = std.math.rotr(u32, cl, 10);
            cl = bl;
            bl = std.math.rotr(u32, tl, rot);

            const rj = 79 - j;
            const word_idx_r = roundWordIndex(rj);
            const rot_r = roundRotationsRev(rj);
            const tr = roundFr(rj, br, cr, dr) +% ar +% w[word_idx_r] +% Rp[rj / 16];
            ar = er;
            er = dr;
            dr = std.math.rotr(u32, cr, 10);
            cr = br;
            br = std.math.rotr(u32, tr, rot_r);
        }

        const t = state[1] +% cl +% dr;
        state[1] = state[2] +% dl +% er;
        state[2] = state[3] +% el +% ar;
        state[3] = state[4] +% al +% br;
        state[4] = state[0] +% bl +% cr;
        state[0] = t;
    }

    fn roundF(j: usize, x: u32, y: u32, z: u32) u32 {
        return switch (j / 16) {
            0 => x ^ y ^ z,
            1 => (x & y) | (~x & z),
            2 => (x | ~y) ^ z,
            3 => (x & z) | (y & ~z),
            4 => x ^ (y | ~z),
            else => unreachable,
        };
    }

    fn roundFr(j: usize, x: u32, y: u32, z: u32) u32 {
        return switch (j / 16) {
            0 => x ^ (y | ~z),
            1 => (x & z) | (y & ~z),
            2 => (x | ~y) ^ z,
            3 => (x & y) | (~x & z),
            4 => x ^ y ^ z,
            else => unreachable,
        };
    }

    fn roundWordIndex(j: usize) u32 {
        return switch (j / 16) {
            0 => @as(u32, @intCast(j)),
            1 => @as(u32, @intCast((j * 7 + 0) % 16)),
            2 => @as(u32, @intCast((j * 5 + 1) % 16)),
            3 => @as(u32, @intCast((j * 14 + 13) % 16)),
            4 => @as(u32, @intCast((j * 6 + 7) % 16)),
            else => unreachable,
        };
    }

    fn roundRotations(j: usize) u4 {
        const table = [_]u4{ 11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8, 7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12, 11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5, 11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12, 9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6 };
        return table[j];
    }

    fn roundRotationsRev(j: usize) u4 {
        const table = [_]u4{ 8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6, 9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11, 9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5, 15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8, 8, 5, 12, 14, 5, 13, 13, 13, 11, 15, 8, 11, 9, 12, 15, 11 };
        return table[j];
    }
};

test "ripemd160 empty" {
    var ctx = Ripemd160.init(.{});
    const result = ctx.final();
    const expected: [20]u8 = .{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28,
        0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "ripemd160 hello" {
    var ctx = Ripemd160.init(.{});
    ctx.update("hello");
    const result = ctx.final();
    const expected: [20]u8 = .{
        0x10, 0x8f, 0x07, 0xa8, 0x38, 0x83, 0x1f, 0x93, 0x9b, 0x08,
        0x96, 0xda, 0x78, 0xa0, 0xd6, 0xae, 0x18, 0x8f, 0x8a, 0x5b,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "ripemd160 abc" {
    var ctx = Ripemd160.init(.{});
    ctx.update("abc");
    const result = ctx.final();
    const expected: [20]u8 = .{
        0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04,
        0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x8f, 0x05,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "ripemd160 long" {
    var ctx = Ripemd160.init(.{});
    var buf: [100]u8 = @splat(0x61);
    ctx.update(&buf);
    const result = ctx.final();
    try std.testing.expectEqual(20, result.len);
}
