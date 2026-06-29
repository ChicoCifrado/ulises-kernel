const std = @import("std");
const utxo_stack = @import("../utxo/stack.zig");
const utxo_slot = @import("../utxo/slot.zig");
const primitives = @import("primitives.zig");
const builder = @import("builder.zig");
const script = @import("script.zig");

pub const WalletError = error{
    InsufficientFunds,
    InvalidAddress,
    UtxoNotFound,
    ScriptCreationFailed,
    WalletNotFound,
};

pub const Address = struct {
    hash: [20]u8,
    network: primitives.Network,

    pub fn fromPubkeyHash(hash: [20]u8, network: primitives.Network) Address {
        return .{ .hash = hash, .network = network };
    }

    pub fn toLockingScript(self: Address, allocator: std.mem.Allocator) ![]u8 {
        var b = builder.ScriptBuilder.init(allocator);
        errdefer b.deinit();
        try b.buildP2PKH(self.hash);
        return b.finish();
    }

    pub fn matchesScript(self: Address, script_bytes: []const u8) bool {
        if (script_bytes.len != 25) return false;
        if (script_bytes[0] != 0x76) return false; // OP_DUP
        if (script_bytes[1] != 0xa9) return false; // OP_HASH160
        if (script_bytes[2] != 20) return false; // push 20
        if (script_bytes[23] != 0x88) return false; // OP_EQUALVERIFY
        if (script_bytes[24] != 0xac) return false; // OP_CHECKSIG
        return std.mem.eql(u8, script_bytes[3..23], &self.hash);
    }
};

pub const Wallet = struct {
    address: Address,
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, address: Address) Wallet {
        return .{
            .address = address,
            .name = allocator.dupe(u8, name) catch @panic("OOM"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Wallet) void {
        self.allocator.free(self.name);
    }

    pub fn balance(self: *Wallet, utxo: *const utxo_stack.UtxoStack) u64 {
        var total: u64 = 0;
        for (0..utxo.capacity) |i| {
            const slot = utxo.get(i) orelse continue;
            if (slot.isSpent()) continue;
            const sc = utxo.getScript(slot) orelse continue;
            if (self.address.matchesScript(sc)) {
                total += slot.value;
            }
        }
        return total;
    }

    pub fn utxos(self: *Wallet, utxo: *const utxo_stack.UtxoStack, allocator: std.mem.Allocator) ![]UtxoEntry {
        var entries: std.ArrayList(UtxoEntry) = .empty;
        errdefer entries.deinit(allocator);

        for (0..utxo.capacity) |i| {
            const slot = utxo.get(i) orelse continue;
            if (slot.isSpent()) continue;
            const sc = utxo.getScript(slot) orelse continue;
            if (self.address.matchesScript(sc)) {
                try entries.append(allocator, UtxoEntry{
                    .slot_idx = i,
                    .txid = slot.txid,
                    .vout = slot.vout,
                    .value = slot.value,
                    .height = slot.height,
                });
            }
        }
        return entries.toOwnedSlice(allocator);
    }
};

pub const UtxoEntry = struct {
    slot_idx: usize,
    txid: [32]u8,
    vout: u32,
    value: u64,
    height: u32,
};

pub const WalletManager = struct {
    wallets: std.StringArrayHashMapUnmanaged(Wallet),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WalletManager {
        return .{ .wallets = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *WalletManager) void {
        var it = self.wallets.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.wallets.deinit(self.allocator);
    }

    pub fn createWallet(self: *WalletManager, name: []const u8, hash: [20]u8, network: primitives.Network) !void {
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const wallet = Wallet.init(self.allocator, name, Address.fromPubkeyHash(hash, network));
        try self.wallets.put(self.allocator, name_owned, wallet);
    }

    pub fn getWallet(self: *WalletManager, name: []const u8) ?*Wallet {
        return self.wallets.getPtr(name);
    }

    pub fn totalBalance(self: *WalletManager, utxo: *const utxo_stack.UtxoStack) u64 {
        var total: u64 = 0;
        var it = self.wallets.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.balance(utxo);
        }
        return total;
    }

    pub fn listWallets(self: *WalletManager, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).init(allocator);
        errdefer names.deinit();
        var it = self.wallets.iterator();
        while (it.next()) |entry| {
            try names.append(entry.key_ptr.*);
        }
        return names.toOwnedSlice();
    }
};

test "address matching" {
    const hash: [20]u8 = @splat(0xAA);
    const addr = Address.fromPubkeyHash(hash, .mainnet);

    const allocator = std.testing.allocator;
    var b = builder.ScriptBuilder.init(allocator);
    defer b.deinit();
    try b.buildP2PKH(hash);
    const sc = try b.finish();
    defer allocator.free(sc);

    try std.testing.expect(addr.matchesScript(sc));
}

test "address non-matching" {
    const hash_a: [20]u8 = @splat(0xAA);
    const hash_b: [20]u8 = @splat(0xBB);
    const addr = Address.fromPubkeyHash(hash_a, .mainnet);

    const allocator = std.testing.allocator;
    var b = builder.ScriptBuilder.init(allocator);
    defer b.deinit();
    try b.buildP2PKH(hash_b);
    const sc2 = try b.finish();
    defer allocator.free(sc2);

    try std.testing.expect(!addr.matchesScript(sc2));
}

test "wallet balance" {
    const allocator = std.testing.allocator;
    var stack = try utxo_stack.UtxoStack.init(allocator, 1024, 65536);
    defer stack.deinit();

    const hash: [20]u8 = @splat(0xAA);
    const addr = Address.fromPubkeyHash(hash, .mainnet);

    var b = builder.ScriptBuilder.init(allocator);
    defer b.deinit();
    try b.buildP2PKH(hash);
    const sc3 = try b.finish();
    defer allocator.free(sc3);

    const txid: [32]u8 = @splat(0xAA);
    const slot = utxo_slot.Slot.init(txid, 0, 100000, 800000, .{});
    _ = try stack.insert(slot, sc3);

    var wallet = Wallet.init(allocator, "test", addr);
    defer wallet.deinit();

    try std.testing.expectEqual(@as(u64, 100000), wallet.balance(&stack));
}

test "wallet manager" {
    const allocator = std.testing.allocator;
    var mgr = WalletManager.init(allocator);
    defer mgr.deinit();

    const hash: [20]u8 = @splat(0xAA);
    try mgr.createWallet("default", hash, .mainnet);

    const wallets = try mgr.listWallets(allocator);
    defer allocator.free(wallets);
    try std.testing.expectEqual(@as(usize, 1), wallets.len);
}
