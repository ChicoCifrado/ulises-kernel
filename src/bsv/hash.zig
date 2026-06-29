const std = @import("std");

const K = [_]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

pub const Sha256 = struct {
    state: [8]u32,
    buf: [64]u8,
    buf_len: usize,
    total_len: u64,

    pub fn init(_: @TypeOf(.{})) Sha256 {
        return .{
            .state = [_]u32{
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    pub fn update(self: *Sha256, data: []const u8) void {
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

    pub fn final(self: *Sha256) [32]u8 {
        const bits = self.total_len * 8;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;

        if (self.buf_len > 56) {
            @memset(self.buf[self.buf_len..], 0);
            compress(&self.state, &self.buf);
            self.buf_len = 0;
        }

        @memset(self.buf[self.buf_len..], 0);
        self.buf[63] = @truncate(bits);
        self.buf[62] = @truncate(bits >> 8);
        self.buf[61] = @truncate(bits >> 16);
        self.buf[60] = @truncate(bits >> 24);
        self.buf[59] = @truncate(bits >> 32);
        self.buf[58] = @truncate(bits >> 40);
        self.buf[57] = @truncate(bits >> 48);
        self.buf[56] = @truncate(bits >> 56);

        compress(&self.state, &self.buf);

        var result: [32]u8 = undefined;
        for (self.state, 0..) |s, i| {
            result[i * 4 + 0] = @truncate(s >> 24);
            result[i * 4 + 1] = @truncate(s >> 16);
            result[i * 4 + 2] = @truncate(s >> 8);
            result[i * 4 + 3] = @truncate(s);
        }
        return result;
    }

    fn compress(state: *[8]u32, block: *const [64]u8) void {
        var w: [64]u32 = undefined;
        for (0..16) |i| {
            w[i] = @as(u32, block[i * 4]) << 24 |
                @as(u32, block[i * 4 + 1]) << 16 |
                @as(u32, block[i * 4 + 2]) << 8 |
                @as(u32, block[i * 4 + 3]);
        }
        for (16..64) |i| {
            const s0 = std.math.rotr(u32, w[i - 15], 7) ^ std.math.rotr(u32, w[i - 15], 18) ^ (w[i - 15] >> 3);
            const s1 = std.math.rotr(u32, w[i - 2], 17) ^ std.math.rotr(u32, w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
        }

        var a = state[0];
        var b = state[1];
        var c = state[2];
        var d = state[3];
        var e = state[4];
        var f = state[5];
        var g = state[6];
        var h = state[7];

        for (0..64) |i| {
            const s1 = std.math.rotr(u32, e, 6) ^ std.math.rotr(u32, e, 11) ^ std.math.rotr(u32, e, 25);
            const ch = (e & f) ^ ((~e) & g);
            const temp1 = h +% s1 +% ch +% K[i] +% w[i];
            const s0 = std.math.rotr(u32, a, 2) ^ std.math.rotr(u32, a, 13) ^ std.math.rotr(u32, a, 22);
            const maj = (a & b) ^ (a & c) ^ (b & c);
            const temp2 = s0 +% maj;

            h = g;
            g = f;
            f = e;
            e = d +% temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 +% temp2;
        }

        state[0] +%= a;
        state[1] +%= b;
        state[2] +%= c;
        state[3] +%= d;
        state[4] +%= e;
        state[5] +%= f;
        state[6] +%= g;
        state[7] +%= h;
    }
};

pub fn doubleSha256(input: []const u8) [32]u8 {
    var state = Sha256.init(.{});
    state.update(input);
    const hash1 = state.final();

    var state2 = Sha256.init(.{});
    state2.update(&hash1);
    return state2.final();
}

pub fn sha256(input: []const u8) [32]u8 {
    var state = Sha256.init(.{});
    state.update(input);
    return state.final();
}

test "sha256 basic" {
    const result = sha256("hello");
    try std.testing.expectEqual(32, result.len);
    const expected: [32]u8 = .{
        0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e,
        0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9, 0xe2, 0x9e,
        0x1b, 0x16, 0x1e, 0x5c, 0x1f, 0xa7, 0x42, 0x5e,
        0x73, 0x04, 0x33, 0x62, 0x93, 0x8b, 0x98, 0x24,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "double sha256" {
    const result = doubleSha256("hello");
    try std.testing.expectEqual(32, result.len);
}

test "empty string" {
    const result = sha256("");
    try std.testing.expectEqual(32, result.len);
}

test "long input" {
    var buf: [1000]u8 = @splat(0x41);
    const result = sha256(&buf);
    try std.testing.expectEqual(32, result.len);
}
