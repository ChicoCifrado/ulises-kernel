const std = @import("std");
const secp256k1 = @import("secp256k1");

pub const Network = enum { mainnet, testnet, regtest };

pub const OutPoint = struct {
    txid: [32]u8,
    vout: u32,
    pub fn eql(self: OutPoint, other: OutPoint) bool {
        return std.mem.eql(u8, &self.txid, &other.txid) and self.vout == other.vout;
    }
    pub fn hash(self: OutPoint) u64 {
        return std.hash.murmur3(.{ .seed = 0x9e3779b97f4a7c15 }, &self.txid) ^ self.vout;
    }
};

pub const TxIn = struct {
    prev_out: OutPoint,
    script: []const u8,
    sequence: u32 = 0xffffffff,
};

pub const TxOut = struct {
    value: u64,
    script: []const u8,
};

pub const Tx = struct {
    version: i32,
    inputs: []TxIn,
    outputs: []TxOut,
    locktime: u32,
    txid: [32]u8,

    pub fn computeTxid(self: *Tx) void {
        var hasher = std.hash.Sha256.init(.{});
        try hasher.update(std.mem.asBytes(&self.version));
        try hasher.updateVarInt(self.inputs.len);
        for (self.inputs) |in| {
            try hasher.update(&in.prev_out.txid);
            try hasher.update(std.mem.asBytes(&in.prev_out.vout));
            try hasher.updateVarInt(in.script.len);
            try hasher.update(in.script);
            try hasher.update(std.mem.asBytes(&in.sequence));
        }
        try hasher.updateVarInt(self.outputs.len);
        for (self.outputs) |out| {
            try hasher.update(std.mem.asBytes(&out.value));
            try hasher.updateVarInt(out.script.len);
            try hasher.update(out.script);
        }
        try hasher.update(std.mem.asBytes(&self.locktime));
        var hash1: [32]u8 = undefined;
        hasher.final(&hash1);
        var hasher2 = std.hash.Sha256.init(.{});
        try hasher2.update(&hash1);
        hasher2.final(&self.txid);
    }
};

pub const BlockHeader = struct {
    version: i32,
    prev_hash: [32]u8,
    merkle_root: [32]u8,
    timestamp: u32,
    bits: u32,
    nonce: u32,
    height: u32,
    hash: [32]u8,
};

pub const Block = struct {
    header: BlockHeader,
    txs: []Tx,
};

pub fn doubleSha256(input: []const u8) [32]u8 {
    var hasher = std.hash.Sha256.init(.{});
    try hasher.update(input);
    var hash1: [32]u8 = undefined;
    hasher.final(&hash1);
    var hasher2 = std.hash.Sha256.init(.{});
    try hasher2.update(&hash1);
    var hash2: [32]u8 = undefined;
    hasher2.final(&hash2);
    return hash2;
}

pub fn ripemd160(input: []const u8) [20]u8 {
    var ctx = std.hash.Ripemd160.init(.{});
    try ctx.update(input);
    var out: [20]u8 = undefined;
    ctx.final(&out);
    return out;
}

pub fn hash160(input: []const u8) [20]u8 {
    return ripemd160(doubleSha256(input).slice());
}

pub fn verifySig(pubkey: []const u8, msg: [32]u8, sig: []const u8) bool {
    return secp256k1.verify(pubkey, msg, sig);
}

pub fn recoverPubkey(msg: [32]u8, sig: []const u8) ?[33]u8 {
    return secp256k1.recover(msg, sig);
}