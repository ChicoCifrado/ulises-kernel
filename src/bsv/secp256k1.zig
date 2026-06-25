const std = @import("std");
const Sha256 = @import("hash.zig").Sha256;
const hash = @import("hash.zig");

const P: [8]u32 = .{
    0xFFFFFC2F, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
    0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
};
const N: [8]u32 = .{
    0xD0364141, 0xBFD25E8C, 0xAF48A03B, 0xBAAEDCE6,
    0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
};
const P_INV: u32 = 0x3D1;
const GX: [8]u32 = .{
    0x16F81798, 0x59F2815B, 0x2DCE28D9, 0x029BFCDB,
    0xCE870B07, 0x55A06295, 0xF9DCBBAC, 0x79BE667E,
};
const GY: [8]u32 = .{
    0xFB10D4B8, 0x9C47D08F, 0xA6855419, 0xFD17B448,
    0x0E1108A8, 0x5DA4FBFC, 0x26A3C465, 0x483ADA77,
};

const Fe = [8]u32;
const Sc = [8]u32;

fn feZero() Fe {
    return [_]u32{0} ** 8;
}

fn feIsZero(a: Fe) bool {
    for (a) |w| if (w != 0) return false;
    return true;
}

fn feEq(a: Fe, b: Fe) bool {
    for (0..8) |i| if (a[i] != b[i]) return false;
    return true;
}

fn feOne() Fe {
    var r: Fe = [_]u32{0} ** 8;
    r[0] = 1;
    return r;
}

fn feAdd(a: Fe, b: Fe) Fe {
    var r: Fe = undefined;
    var carry: u64 = 0;
    for (0..8) |i| {
        const s = @as(u64, a[i]) + @as(u64, b[i]) + carry;
        r[i] = @truncate(s);
        carry = s >> 32;
    }
    if (carry != 0 or feGte(r, P)) r = feSub(r, P);
    return r;
}

fn feSub(a: Fe, b: Fe) Fe {
    var r: Fe = undefined;
    var borrow: i64 = 0;
    for (0..8) |i| {
        const d = @as(i64, a[i]) - @as(i64, b[i]) - borrow;
        r[i] = @truncate(@as(u64, @bitCast(d)));
        borrow = if (d < 0) 1 else 0;
    }
    if (borrow != 0) r = feAdd(r, P);
    return r;
}

fn feGte(a: Fe, b: Fe) bool {
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        if (a[i] > b[i]) return true;
        if (a[i] < b[i]) return false;
    }
    return true;
}

fn feMul(a: Fe, b: Fe) Fe {
    var t: [16]u64 = [_]u64{0} ** 16;
    for (0..8) |i| {
        var carry: u64 = 0;
        for (0..8) |j| {
            const k = i + j;
            const prod = @as(u64, a[i]) * @as(u64, b[j]) + t[k] + carry;
            t[k] = @truncate(prod);
            carry = prod >> 32;
        }
        t[i + 8] += carry;
    }
    return feReduce(t);
}

fn feReduce(t: [16]u64) Fe {
    var r: [16]u64 = t;
    for (8..16) |i| {
        if (r[i] == 0) continue;
        const c = r[i];
        r[i] = 0;
        var carry: u64 = 0;
        const idx = i - 8;
        const prod = @as(u64, @as(u64, @truncate(c))) * @as(u64, P_INV);
        carry = prod;
        var j: usize = 0;
        while (j < 8) {
            const k = idx + j;
            const sum = r[k] + carry;
            r[k] = @truncate(sum);
            carry = sum >> 32;
            if (k < 15) r[k + 1] += carry;
            carry = 0;
            j += 1;
        }
    }
    var result: Fe = undefined;
    for (0..8) |i| result[i] = @truncate(r[i]);
    if (feGte(result, P)) result = feSub(result, P);
    return result;
}

fn feSquare(a: Fe) Fe {
    return feMul(a, a);
}

fn feNeg(a: Fe) Fe {
    return feSub(P, a);
}

fn feInv(a: Fe) Fe {
    const P_MINUS_2: Fe = .{
        0xFFFFFC2E, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
        0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
    };
    var r = a;
    var i: usize = 255;
    while (i > 0) {
        i -= 1;
        r = feSquare(r);
        const byte = @as(usize, @intCast(i / 32));
        const bit = @as(usize, @intCast(i % 32));
        if ((P_MINUS_2[byte] >> @intCast(bit)) & 1 != 0) r = feMul(r, a);
    }
    return r;
}

fn feFromBytes(b: [32]u8) Fe {
    var r: Fe = undefined;
    for (0..8) |i| {
        r[i] = std.mem.readInt(u32, b[i * 4 ..][0..4], .little);
    }
    return r;
}

fn feToBytes(a: Fe) [32]u8 {
    var b: [32]u8 = undefined;
    for (0..8) |i| {
        std.mem.writeInt(u32, b[i * 4 ..][0..4], a[i], .little);
    }
    return b;
}

fn scZero() Sc {
    return [_]u32{0} ** 8;
}

fn scOne() Sc {
    var r: Sc = [_]u32{0} ** 8;
    r[0] = 1;
    return r;
}

fn scIsZero(a: Sc) bool {
    for (a) |w| if (w != 0) return false;
    return true;
}

fn scEq(a: Sc, b: Sc) bool {
    for (0..8) |i| if (a[i] != b[i]) return false;
    return true;
}

fn scGte(a: Sc, b: Sc) bool {
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        if (a[i] > b[i]) return true;
        if (a[i] < b[i]) return false;
    }
    return true;
}

fn scAdd(a: Sc, b: Sc) Sc {
    var r: Sc = undefined;
    var carry: u64 = 0;
    for (0..8) |i| {
        const s = @as(u64, a[i]) + @as(u64, b[i]) + carry;
        r[i] = @truncate(s);
        carry = s >> 32;
    }
    if (carry != 0 or scGte(r, N)) r = scSub(r, N);
    return r;
}

fn scSub(a: Sc, b: Sc) Sc {
    var r: Sc = undefined;
    var borrow: i64 = 0;
    for (0..8) |i| {
        const d = @as(i64, a[i]) - @as(i64, b[i]) - borrow;
        r[i] = @truncate(@as(u64, @bitCast(d)));
        borrow = if (d < 0) 1 else 0;
    }
    if (borrow != 0) r = scAdd(r, N);
    return r;
}

fn scMul(a: Sc, b: Sc) Sc {
    var t: [16]u64 = [_]u64{0} ** 16;
    for (0..8) |i| {
        var carry: u64 = 0;
        for (0..8) |j| {
            const k = i + j;
            const prod = @as(u64, a[i]) * @as(u64, b[j]) + t[k] + carry;
            t[k] = @truncate(prod);
            carry = prod >> 32;
        }
        t[i + 8] += carry;
    }
    return scReduce(t);
}

fn scReduce(t: [16]u64) Sc {
    var r: [8]u64 = undefined;
    for (0..8) |i| r[i] = t[i];
    for (8..16) |i| {
        if (t[i] == 0) continue;
        var carry = t[i];
        var j = i - 8;
        while (carry != 0) {
            if (j < 8) {
                const sum = r[j] + carry;
                r[j] = @truncate(sum);
                carry = sum >> 32;
                j += 1;
            } else {
                var tmp: Sc = undefined;
                for (0..8) |k| tmp[k] = @truncate(r[k]);
                tmp = scSub(tmp, N);
                for (0..8) |k| r[k] = @as(u64, tmp[k]);
                carry -%= 1;
            }
        }
    }
    var result: Sc = undefined;
    for (0..8) |i| result[i] = @truncate(r[i]);
    while (scGte(result, N)) result = scSub(result, N);
    return result;
}

fn scFromBytes(b: [32]u8) Sc {
    var r: Sc = undefined;
    for (0..8) |i| {
        r[i] = std.mem.readInt(u32, b[i * 4 ..][0..4], .little);
    }
    return r;
}

fn scToBytes(a: Sc) [32]u8 {
    var b: [32]u8 = undefined;
    for (0..8) |i| {
        std.mem.writeInt(u32, b[i * 4 ..][0..4], a[i], .little);
    }
    return b;
}

const Ge = struct {
    x: Fe,
    y: Fe,
    infinity: bool,
};

const Gej = struct {
    x: Fe,
    y: Fe,
    z: Fe,
};

fn gejZero() Gej {
    return .{ .x = feOne(), .y = feOne(), .z = feZero() };
}

fn gejIsZero(p: Gej) bool {
    return feIsZero(p.z);
}

fn gejFromGe(p: Ge) Gej {
    if (p.infinity) return gejZero();
    return .{ .x = p.x, .y = p.y, .z = feOne() };
}

fn geFromBytes(b: [33]u8) ?Ge {
    if (b.len == 33) {
        const prefix = b[0];
        if (prefix != 0x02 and prefix != 0x03) return null;
        const x = feFromBytes(b[1..33].*);
        const y = geRecoverY(x, prefix == 0x03);
        return y orelse null;
    }
    return null;
}

fn geToBytes(p: Ge) [33]u8 {
    var b: [33]u8 = undefined;
    b[0] = if (p.y[0] & 1 != 0) 0x03 else 0x02;
    const xb = feToBytes(p.x);
    @memcpy(b[1..33], &xb);
    return b;
}

fn geRecoverY(x: Fe, odd: bool) ?Fe {
    var y2 = feMul(x, x);
    y2 = feMul(y2, x);
    y2 = feAdd(y2, [_]u32{ 7, 0, 0, 0, 0, 0, 0, 0 });
    var y = feSqrt(y2);
    if (!feEq(feMul(y, y), y2)) return null;
    if ((y[0] & 1) != @intFromBool(odd)) y = feNeg(y);
    return y;
}

fn feSqrt(a: Fe) Fe {
    const SQRT_EXP: Fe = .{
        0x7FFFFC2E, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
        0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x3FFFFFFF,
    };
    var r = a;
    var i: usize = 254;
    while (i > 0) {
        i -= 1;
        r = feSquare(r);
        const byte = @as(usize, @intCast(i / 32));
        const bit = @as(usize, @intCast(i % 32));
        if ((SQRT_EXP[byte] >> @intCast(bit)) & 1 != 0) r = feMul(r, a);
    }
    return r;
}

fn gejDouble(p: Gej) Gej {
    if (gejIsZero(p)) return gejZero();
    const z2 = feSquare(p.z);
    const t1 = feSub(feSquare(p.x), z2);
    const t2 = feSub(feSquare(p.y), z2);
    const t3 = feAdd(t1, t2);
    const t4 = feSquare(t3);
    const x3 = feSub(t4, feAdd(feAdd(p.x, p.x), p.x));
    const y3 = feSub(feMul(feSub(p.x, x3), t3), feMul(p.y, p.y));
    const z3 = feMul(p.y, p.z);
    return .{ .x = x3, .y = y3, .z = z3 };
}

fn gejAdd(p: Gej, q: Gej) Gej {
    if (gejIsZero(p)) return q;
    if (gejIsZero(q)) return p;
    const z22 = feSquare(q.z);
    const z12 = feSquare(p.z);
    const p1x = feMul(p.x, z22);
    const p2x = feMul(q.x, z12);
    const p1y = feMul(feMul(p.y, z22), q.z);
    const p2y = feMul(feMul(q.y, z12), p.z);
    if (feEq(p1x, p2x)) {
        if (feEq(p1y, p2y)) return gejDouble(p);
        return gejZero();
    }
    const hx = feSub(p2x, p1x);
    const hx2 = feSquare(hx);
    const hx3 = feMul(hx2, hx);
    const rv = feSub(p2y, p1y);
    const x3 = feSub(feSub(feSquare(rv), hx3), feMul(hx2, feAdd(p1x, p1x)));
    const y3 = feSub(feMul(rv, feSub(hx3, feAdd(x3, x3))), feMul(p1y, hx3));
    const z3 = feMul(feMul(hx, p.z), q.z);
    return .{ .x = x3, .y = y3, .z = z3 };
}

fn gejMul(p: Gej, scalar: Sc) Gej {
    if (scIsZero(scalar)) return gejZero();
    var r = gejZero();
    var s = p;
    var sc = scalar;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if (sc[0] & 1 != 0) r = gejAdd(r, s);
        s = gejDouble(s);
        var carry: u64 = 0;
        for (0..8) |j| {
            const v = @as(u64, sc[j]) >> 1 | carry;
            sc[j] = @truncate(v);
            carry = v >> 32;
        }
    }
    return r;
}

fn gejToGe(p: Gej) Ge {
    if (gejIsZero(p)) return Ge{ .x = feZero(), .y = feZero(), .infinity = true };
    const zinv = feInv(p.z);
    const zinv2 = feSquare(zinv);
    return Ge{
        .x = feMul(p.x, zinv2),
        .y = feMul(feMul(p.y, zinv2), zinv),
        .infinity = false,
    };
}

fn geNeg(p: Ge) Ge {
    return Ge{ .x = p.x, .y = feNeg(p.y), .infinity = p.infinity };
}

pub const secp256k1 = struct {
    pub fn pubkeyCreate(priv: [32]u8) [33]u8 {
        const scalar = scFromBytes(priv);
        const g = Ge{ .x = GX, .y = GY, .infinity = false };
        const p = gejToGe(gejMul(gejFromGe(g), scalar));
        return geToBytes(p);
    }

    pub fn pubkeyFromBytes(b: [33]u8) ?[33]u8 {
        const p = geFromBytes(b) orelse return null;
        return geToBytes(p);
    }

    pub fn sign(hash32: [32]u8, priv: [32]u8) struct { r: [32]u8, s: [32]u8 } {
        const se = scFromBytes(priv);
        const z = scFromBytes(hash32);
        const g = Ge{ .x = GX, .y = GY, .infinity = false };
        var k = se;
        k[0] +%= 1;
        const rp = gejToGe(gejMul(gejFromGe(g), k));
        const rx = rp.x;
        var r: Sc = undefined;
        for (0..8) |i| r[i] = rx[i];
        if (scIsZero(r)) {
            k[0] +%= 1;
            const rp2 = gejToGe(gejMul(gejFromGe(g), k));
            for (0..8) |i| r[i] = rp2.x[i];
        }
        const k_inv = scInv(k);
        var s = scMul(scMul(r, se), k_inv);
        s = scAdd(scMul(z, k_inv), s);
        if (scIsZero(s)) {
            k[0] +%= 1;
            const rp3 = gejToGe(gejMul(gejFromGe(g), k));
            for (0..8) |i| r[i] = rp3.x[i];
            const k_inv2 = scInv(k);
            s = scAdd(scMul(z, k_inv2), scMul(scMul(r, se), k_inv2));
        }

        // low-s normalization
        const s_half: Sc = .{
            0x681B20A0, 0xDFE92F46, 0x57A4501C, 0x5D576E73,
            0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF,
        };
        if (scGte(s, s_half)) s = scSub(N, s);

        return .{ .r = scToBytes(r), .s = scToBytes(s) };
    }

    pub fn verify(hash32: [32]u8, sig_r: [32]u8, sig_s: [32]u8, pubkey: [33]u8) bool {
        const p = geFromBytes(pubkey) orelse return false;
        if (p.infinity) return false;
        const r = scFromBytes(sig_r);
        const s = scFromBytes(sig_s);
        if (scIsZero(r) or scIsZero(s)) return false;
        if (scGte(r, N) or scGte(s, N)) return false;
        const z = scFromBytes(hash32);
        const s_inv = scInv(s);
        const u1_ = scMul(z, s_inv);
        const u2_ = scMul(r, s_inv);
        const g = Ge{ .x = GX, .y = GY, .infinity = false };
        const p1 = gejMul(gejFromGe(g), u1_);
        const p2 = gejMul(gejFromGe(p), u2_);
        const sum = gejToGe(gejAdd(p1, p2));
        if (sum.infinity) return false;
        var rx: Sc = undefined;
        for (0..8) |i| rx[i] = sum.x[i];
        return scEq(rx, r);
    }

    pub fn ecdh(priv: [32]u8, pubkey: [33]u8) [32]u8 {
        const p = geFromBytes(pubkey) orelse return [_]u8{0} ** 32;
        if (p.infinity) return [_]u8{0} ** 32;
        const scalar = scFromBytes(priv);
        const result = gejToGe(gejMul(gejFromGe(p), scalar));
        if (result.infinity) return [_]u8{0} ** 32;
        return feToBytes(result.x);
    }

    pub fn deriveChildPubkey(parent_pub: [33]u8, scalar: [32]u8) [33]u8 {
        const p = geFromBytes(parent_pub) orelse return [_]u8{0} ** 33;
        const s = scFromBytes(scalar);
        const g = Ge{ .x = GX, .y = GY, .infinity = false };
        const offset = gejToGe(gejMul(gejFromGe(g), s));
        const result = gejToGe(gejAdd(gejFromGe(p), gejFromGe(offset)));
        return geToBytes(result);
    }
};

fn scInv(a: Sc) Sc {
    const N_MINUS_2: Sc = .{
        0xD036413F, 0xBFD25E8C, 0xAF48A03B, 0xBAAEDCE6,
        0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
    };
    var r = a;
    var i: usize = 255;
    while (i > 0) {
        i -= 1;
        r = scMul(r, r);
        const byte = @as(usize, @intCast(i / 32));
        const bit = @as(usize, @intCast(i % 32));
        if ((N_MINUS_2[byte] >> @intCast(bit)) & 1 != 0) r = scMul(r, a);
    }
    return r;
}

test "fe add sub roundtrip" {
    const a: Fe = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const b: Fe = [_]u32{ 8, 7, 6, 5, 4, 3, 2, 1 };
    const sum = feAdd(a, b);
    const diff = feSub(sum, a);
    try std.testing.expect(feEq(diff, b));
}

test "fe mul identity" {
    const a: Fe = [_]u32{ 0x12345678, 0x9ABCDEF0, 1, 2, 3, 4, 5, 6 };
    const one = feOne();
    const prod = feMul(a, one);
    try std.testing.expect(feEq(prod, a));
}

test "fe mul zero" {
    const a: Fe = [_]u32{ 0xDEADBEEF, 1, 2, 3, 4, 5, 6, 7 };
    const zero = feZero();
    const prod = feMul(a, zero);
    try std.testing.expect(feIsZero(prod));
}

test "fe inv then mul" {
    const a: Fe = [_]u32{ 9, 0, 0, 0, 0, 0, 0, 0 };
    const inv = feInv(a);
    const prod = feMul(a, inv);
    try std.testing.expect(feEq(prod, feOne()));
}

test "fe from/to bytes" {
    const a: Fe = [_]u32{ 0x11111111, 0x22222222, 0x33333333, 0x44444444, 0x55555555, 0x66666666, 0x77777777, 0x88888888 };
    const bytes = feToBytes(a);
    const back = feFromBytes(bytes);
    try std.testing.expect(feEq(a, back));
}

test "fe sqrt" {
    const four: Fe = [_]u32{ 4, 0, 0, 0, 0, 0, 0, 0 };
    const sqrt = feSqrt(four);
    try std.testing.expect(feEq(feMul(sqrt, sqrt), four));
}

test "sc add sub" {
    const a: Sc = [_]u32{ 1, 0, 0, 0, 0, 0, 0, 0 };
    const b: Sc = [_]u32{ 2, 0, 0, 0, 0, 0, 0, 0 };
    const sum = scAdd(a, b);
    const diff = scSub(sum, a);
    try std.testing.expect(scEq(diff, b));
}

test "sc mul identity" {
    const a: Sc = [_]u32{ 0x12345678, 0x9ABCDEF0, 1, 2, 3, 4, 5, 6 };
    const one = scOne();
    const prod = scMul(a, one);
    try std.testing.expect(scEq(prod, a));
}

test "sc inv then mul" {
    const a: Sc = [_]u32{ 5, 0, 0, 0, 0, 0, 0, 0 };
    const inv = scInv(a);
    const prod = scMul(a, inv);
    try std.testing.expect(scEq(prod, scOne()));
}

test "pubkey create" {
    const priv: [32]u8 = [_]u8{0x01} ** 32;
    const pk = secp256k1.pubkeyCreate(priv);
    try std.testing.expectEqual(33, pk.len);
    try std.testing.expect(pk[0] == 0x02 or pk[0] == 0x03);
}

test "sign and verify" {
    const priv_bytes: [32]u8 = [_]u8{0x01} ** 32;
    const pk_bytes = secp256k1.pubkeyCreate(priv_bytes);
    const msg: [32]u8 = hash.sha256("hello");

    const sig = secp256k1.sign(msg, priv_bytes);
    const valid = secp256k1.verify(msg, sig.r, sig.s, pk_bytes);
    try std.testing.expect(valid);
}

test "verify wrong sig fails" {
    const priv_bytes: [32]u8 = [_]u8{0x01} ** 32;
    const pk_bytes = secp256k1.pubkeyCreate(priv_bytes);
    const msg: [32]u8 = hash.sha256("hello");
    const wrong_msg: [32]u8 = hash.sha256("world");

    const sig = secp256k1.sign(msg, priv_bytes);
    const valid = secp256k1.verify(wrong_msg, sig.r, sig.s, pk_bytes);
    try std.testing.expect(!valid);
}

test "ecdh shared secret" {
    const alice_priv_bytes: [32]u8 = [_]u8{0xAA} ** 32;
    const bob_priv_bytes: [32]u8 = [_]u8{0xBB} ** 32;

    const alice_pk = secp256k1.pubkeyCreate(alice_priv_bytes);
    const bob_pk = secp256k1.pubkeyCreate(bob_priv_bytes);

    const alice_shared = secp256k1.ecdh(alice_priv_bytes, bob_pk);
    const bob_shared = secp256k1.ecdh(bob_priv_bytes, alice_pk);

    try std.testing.expectEqualSlices(u8, &alice_shared, &bob_shared);
}

test "derive child pubkey" {
    const parent_priv_bytes: [32]u8 = [_]u8{0x01} ** 32;
    const parent_pk = secp256k1.pubkeyCreate(parent_priv_bytes);
    const scalar_bytes: [32]u8 = hash.sha256("derive");

    const child_pk = secp256k1.deriveChildPubkey(parent_pk, scalar_bytes);
    _ = child_pk;
}

test "pubkey from bytes" {
    const priv_bytes: [32]u8 = [_]u8{0x01} ** 32;
    const pubkey_bytes = secp256k1.pubkeyCreate(priv_bytes);
    const parsed = secp256k1.pubkeyFromBytes(pubkey_bytes);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualSlices(u8, &pubkey_bytes, &parsed.?);
}
