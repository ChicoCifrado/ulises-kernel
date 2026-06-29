const std = @import("std");
const Sha256 = @import("hash.zig").Sha256;
const hash = @import("hash.zig");
const primitives = @import("primitives.zig");
const utxo_stack = @import("../utxo/stack.zig");
const utxo_slot = @import("../utxo/slot.zig");
const wallet = @import("wallet.zig");
const bkds = @import("bkds.zig");
const brc43 = @import("brc43.zig");
const secp = @import("secp256k1.zig").secp256k1;

pub const ProtocolVersion = struct {
    major: u32,
    minor: u32,
    revision: u32,

    pub fn current() ProtocolVersion {
        return .{ .major = 1, .minor = 0, .revision = 1 };
    }

    pub fn serialize(self: ProtocolVersion) [12]u8 {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], self.major, .little);
        std.mem.writeInt(u32, buf[4..8], self.minor, .little);
        std.mem.writeInt(u32, buf[8..12], self.revision, .little);
        return buf;
    }
};

pub const OutputTemplate = struct {
    locking_script: []const u8,
    value: u64,
    basket: ?[]const u8 = null,
    custom_instructions: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
};

pub const InputTemplate = struct {
    txid: [32]u8,
    vout: u32,
    unlocking_script: ?[]const u8 = null,
    value: u64,
    sequence: u32 = 0xffffffff,
};

pub const Action = struct {
    inputs: []InputTemplate,
    outputs: []OutputTemplate,
    locktime: u32 = 0,
    version: i32 = 1,
    description: ?[]const u8 = null,
    labels: ?[]const []const u8 = null,
};

pub const ActionResponse = struct {
    raw_tx: []u8,
    txid: [32]u8,
    input_count: usize,
    output_count: usize,
};

pub const InternalizeParams = struct {
    raw_tx: []const u8,
    block_height: ?u32 = null,
    proof: ?[]const u8 = null,
};

pub const InternalizeResponse = struct {
    utxo_count: usize,
    spent_count: usize,
    action: []u8,
};

pub const BasketBalance = struct {
    basket: []const u8,
    satoshis: u64,
    utxo_count: usize,
};

pub const FundingDestination = enum(u8) {
    direct = 0x00,
    shared = 0x01,
    parted = 0x02,
    announcement = 0x03,
};

pub const SignableConfig = struct {
    sender_intent: u8 = 0,
    protocol_id: brc43.ProtocolId = brc43.ProtocolId.default(),
    key_id: u64 = 0,
    counterparty: ?brc43.Counterparty = null,
};

pub const KernelWalletError = error{
    NoUtxos,
    InsufficientFunds,
    InternalizeParse,
    UnknownBasket,
    SigningFailed,
    NotImplemented,
};

pub const KernelWallet = struct {
    allocator: std.mem.Allocator,
    wallet_mgr: wallet.WalletManager,
    utxo: *utxo_stack.UtxoStack,
    network: primitives.Network,
    height: u32,
    version: ProtocolVersion,
    active_wallet: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, utxo: *utxo_stack.UtxoStack) KernelWallet {
        return .{
            .allocator = allocator,
            .wallet_mgr = wallet.WalletManager.init(allocator),
            .utxo = utxo,
            .network = .mainnet,
            .height = 0,
            .version = ProtocolVersion.current(),
            .active_wallet = null,
        };
    }

    pub fn deinit(self: *KernelWallet) void {
        self.wallet_mgr.deinit();
    }

    pub fn setActiveWallet(self: *KernelWallet, name: []const u8) void {
        self.active_wallet = name;
    }

    pub fn getVersion(self: *const KernelWallet) ProtocolVersion {
        return self.version;
    }

    pub fn getHeight(self: *const KernelWallet) u32 {
        return self.height;
    }

    pub fn setHeight(self: *KernelWallet, h: u32) void {
        self.height = h;
    }

    pub fn getNetwork(self: *const KernelWallet) primitives.Network {
        return self.network;
    }

    pub fn setNetwork(self: *KernelWallet, net: primitives.Network) void {
        self.network = net;
    }

    pub fn getPublicKeys(self: *const KernelWallet, allocator: std.mem.Allocator) ![][]const u8 {
        return self.wallet_mgr.listWallets(allocator);
    }

    pub fn createWallet(self: *KernelWallet, name: []const u8, pubkey_hash: [20]u8) !void {
        try self.wallet_mgr.createWallet(name, pubkey_hash, self.network);
    }

    pub fn getBasketBalance(self: *KernelWallet, basket_name: ?[]const u8) !BasketBalance {
        const name = basket_name orelse (self.active_wallet orelse return error.UnknownBasket);
        const w = self.wallet_mgr.getWallet(name) orelse return error.UnknownBasket;
        const bal = w.balance(self.utxo);
        const entries = try w.utxos(self.utxo, self.allocator);
        defer self.allocator.free(entries);
        return .{
            .basket = name,
            .satoshis = bal,
            .utxo_count = entries.len,
        };
    }

    pub fn internalizeTx(self: *KernelWallet, raw_tx: []const u8, block_height: ?u32) !InternalizeResponse {
        const height = block_height orelse self.height;
        _ = height;
        const spent_count: usize = 0;
        var utxo_count: usize = 0;

        var offset: usize = 0;
        if (offset + 4 > raw_tx.len) return error.InternalizeParse;
        offset += 4;

        const in_count = primitives.decodeVarInt(raw_tx[offset..]);
        offset += in_count.consumed;

        for (0..in_count.value) |_| {
            if (offset + 36 > raw_tx.len) return error.InternalizeParse;
            offset += 36;
            const script_len = primitives.decodeVarInt(raw_tx[offset..]);
            offset += script_len.consumed;
            if (offset + script_len.value > raw_tx.len) return error.InternalizeParse;
            offset += script_len.value;
            if (offset + 4 > raw_tx.len) return error.InternalizeParse;
            offset += 4;
        }

        const out_count = primitives.decodeVarInt(raw_tx[offset..]);
        offset += out_count.consumed;
        var txid: [32]u8 = @splat(0);
        txid = hash.sha256(raw_tx);

        for (0..out_count.value) |i| {
            if (offset + 8 > raw_tx.len) return error.InternalizeParse;
            const value = std.mem.readInt(u64, raw_tx[offset..][0..8], .little);
            offset += 8;
            const script_len = primitives.decodeVarInt(raw_tx[offset..]);
            offset += script_len.consumed;
            if (offset + script_len.value > raw_tx.len) return error.InternalizeParse;
            const script = raw_tx[offset .. offset + script_len.value];
            offset += script_len.value;

            const slot = utxo_slot.Slot.init(txid, @as(u32, @intCast(i)), value, self.height, .{});
            _ = self.utxo.insert(slot, script) catch continue;
            utxo_count += 1;
        }

        var resp_buf: [64]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "internalized {} utxos, {} spent", .{ utxo_count, spent_count });
        const owned = try self.allocator.dupe(u8, resp);
        return .{
            .utxo_count = utxo_count,
            .spent_count = spent_count,
            .action = owned,
        };
    }

    pub fn createAction(self: *KernelWallet, outputs: []OutputTemplate, config: ?SignableConfig) !ActionResponse {
        _ = config;
        const active = self.active_wallet orelse return error.NoUtxos;
        const w = self.wallet_mgr.getWallet(active) orelse return error.NoUtxos;
        var total_needed: u64 = 0;
        for (outputs) |out| {
            total_needed += out.value;
        }

        const utxo_entries = try w.utxos(self.utxo, self.allocator);
        defer self.allocator.free(utxo_entries);

        if (utxo_entries.len == 0) return error.NoUtxos;

        var collected: u64 = 0;
        const MAX_INPUTS = 256;
        var inputs: [MAX_INPUTS]InputTemplate = undefined;
        var input_count: usize = 0;

        for (utxo_entries) |entry| {
            if (collected >= total_needed) break;
            if (input_count >= MAX_INPUTS) break;
            if (entry.value == 0) continue;
            inputs[input_count] = .{
                .txid = entry.txid,
                .vout = entry.vout,
                .value = entry.value,
            };
            collected += entry.value;
            input_count += 1;
        }

        if (collected < total_needed) return error.InsufficientFunds;

        const change = collected - total_needed;
        var total_outputs = outputs.len;
        if (change > 0) total_outputs += 1;

        const tx_bytes = try self.allocator.alloc(u8, 4096);
        errdefer self.allocator.free(tx_bytes);
        var tx_off: usize = 0;

        std.mem.writeInt(i32, tx_bytes[tx_off..][0..4], 1, .little);
        tx_off += 4;
        tx_off += primitives.encodeVarInt(tx_bytes[tx_off..], input_count);

        for (0..input_count) |i| {
            @memcpy(tx_bytes[tx_off..][0..32], &inputs[i].txid);
            tx_off += 32;
            std.mem.writeInt(u32, tx_bytes[tx_off..][0..4], inputs[i].vout, .little);
            tx_off += 4;
            tx_bytes[tx_off] = 0;
            tx_off += 1;
            std.mem.writeInt(u32, tx_bytes[tx_off..][0..4], inputs[i].sequence, .little);
            tx_off += 4;
        }

        tx_off += primitives.encodeVarInt(tx_bytes[tx_off..], outputs.len);
        for (outputs) |out| {
            std.mem.writeInt(u64, tx_bytes[tx_off..][0..8], out.value, .little);
            tx_off += 8;
            tx_off += primitives.encodeVarInt(tx_bytes[tx_off..], out.locking_script.len);
            @memcpy(tx_bytes[tx_off..][0..out.locking_script.len], out.locking_script);
            tx_off += out.locking_script.len;
        }

        std.mem.writeInt(u32, tx_bytes[tx_off..][0..4], 0, .little);
        tx_off += 4;

        const final_tx = try self.allocator.alloc(u8, tx_off);
        @memcpy(final_tx, tx_bytes[0..tx_off]);

        const action_txid = hash.sha256(final_tx);
        return .{
            .raw_tx = final_tx,
            .txid = action_txid,
            .input_count = input_count,
            .output_count = outputs.len,
        };
    }

    pub fn createActionSimple(self: *KernelWallet, destination_script: []const u8, amount: u64) !ActionResponse {
        var outputs = [_]OutputTemplate{
            .{
                .locking_script = destination_script,
                .value = amount,
            },
        };
        return self.createAction(outputs[0..], null);
    }

    pub fn signHash(self: *KernelWallet, hash32: [32]u8, priv: [32]u8) struct { r: [32]u8, s: [32]u8 } {
        _ = self;
        const sig = secp.sign(hash32, priv);
        return .{ .r = sig.r, .s = sig.s };
    }

    pub fn getPubkey(self: *KernelWallet, priv: [32]u8) [33]u8 {
        _ = self;
        return secp.pubkeyCreate(priv);
    }

    pub fn signSighash(self: *KernelWallet, raw_tx: []const u8, priv: [32]u8) ![65]u8 {
        _ = self;
        const tx_hash = hash.sha256(raw_tx);
        const sig = secp.sign(tx_hash, priv);
        var sig_bytes: [65]u8 = undefined;
        @memcpy(sig_bytes[0..32], &sig.r);
        @memcpy(sig_bytes[32..64], &sig.s);
        sig_bytes[64] = 0x01;
        return sig_bytes;
    }
};

test "kernel wallet version" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();
    var kw = KernelWallet.init(allocator, &stack);
    defer kw.deinit();
    const ver = kw.getVersion();
    try std.testing.expectEqual(@as(u32, 1), ver.major);
}

test "kernel wallet network" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();
    var kw = KernelWallet.init(allocator, &stack);
    defer kw.deinit();
    try std.testing.expectEqual(@as(u8, @intFromEnum(primitives.Network.mainnet)), @intFromEnum(kw.getNetwork()));
    kw.setNetwork(.testnet);
    try std.testing.expectEqual(@as(u8, @intFromEnum(primitives.Network.testnet)), @intFromEnum(kw.getNetwork()));
}

test "kernel wallet height" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();
    var kw = KernelWallet.init(allocator, &stack);
    defer kw.deinit();
    try std.testing.expectEqual(@as(u32, 0), kw.getHeight());
    kw.setHeight(800000);
    try std.testing.expectEqual(@as(u32, 800000), kw.getHeight());
}

test "kernel wallet create wallet and balance" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();
    var kw = KernelWallet.init(allocator, &stack);
    defer kw.deinit();

    const pubkey_hash: [20]u8 = @splat(0xAA);
    try kw.createWallet("default", pubkey_hash);
    kw.setActiveWallet("default");
    _ = try kw.getBasketBalance(null);
}

test "kernel wallet internalize tx" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();
    var kw = KernelWallet.init(allocator, &stack);
    defer kw.deinit();

    var raw_tx: [512]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(i32, raw_tx[off..][0..4], 1, .little);
    off += 4;
    off += primitives.encodeVarInt(raw_tx[off..], 0);
    off += primitives.encodeVarInt(raw_tx[off..], 1);
    std.mem.writeInt(u64, raw_tx[off..][0..8], 10000, .little);
    off += 8;
    const script = [_]u8{ 0x76, 0xa9, 0x14, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x88, 0xac };
    off += primitives.encodeVarInt(raw_tx[off..], script.len);
    @memcpy(raw_tx[off..][0..script.len], &script);
    off += script.len;
    std.mem.writeInt(u32, raw_tx[off..][0..4], 0, .little);
    off += 4;

    const result = try kw.internalizeTx(raw_tx[0..off], 800000);
    defer kw.allocator.free(result.action);
    try std.testing.expectEqual(@as(usize, 1), result.utxo_count);
}

test "kernel wallet create action" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();
    var kw = KernelWallet.init(allocator, &stack);
    defer kw.deinit();

    const pubkey_hash2: [20]u8 = @splat(0xAA);
    try kw.createWallet("default", pubkey_hash2);
    kw.setActiveWallet("default");

    const dest = [_]u8{ 0x76, 0xa9, 0x14, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x88, 0xac };
    const result = kw.createActionSimple(&dest, 5000) catch |err| {
        try std.testing.expectEqual(error.NoUtxos, err);
        return;
    };
    defer kw.allocator.free(result.raw_tx);
}

test "protocol version serialize" {
    const v = ProtocolVersion.current();
    const ser = v.serialize();
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ser[0..4], .little));
}

test "kernel wallet sign hash" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();
    var kw = KernelWallet.init(allocator, &stack);
    defer kw.deinit();

    const priv: [32]u8 = @splat(0xAA);
    const msg: [32]u8 = hash.sha256("test message");
    const sig = kw.signHash(msg, priv);
    const pubkey = kw.getPubkey(priv);
    const valid = secp.verify(msg, sig.r, sig.s, pubkey);
    try std.testing.expect(valid);
}

test "kernel wallet sign sighash" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();
    var kw = KernelWallet.init(allocator, &stack);
    defer kw.deinit();

    const priv: [32]u8 = @splat(0xBB);
    const raw_tx: [10]u8 = [_]u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A};
    const sig65 = try kw.signSighash(&raw_tx, priv);
    try std.testing.expectEqual(65, sig65.len);
    try std.testing.expectEqual(@as(u8, 0x01), sig65[64]); // SIGHASH_ALL
}
