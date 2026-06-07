const std = @import("std");
const arena = @import("arena.zig");
const bsv = @import("bsv");
const indexer = @import("indexer");
const p2p = @import("p2p");

pub const Allocator = std.mem.Allocator;

pub const Config = struct {
    data_dir: []const u8 = "/var/lib/bsvindexer",
    hugepages_path: ?[]const u8 = "/mnt/hugepages",
    hot_cache_mib: usize = 4096,
    warm_cache_mib: usize = 32768,
    max_peers: usize = 8,
    checkpoint_interval: u32 = 2016,
    network: bsv.Network = .mainnet,
};

pub const Indexer = struct {
    allocator: Allocator,
    arena: arena.Arena,
    hot_cache: indexer.HotCache,
    warm_cache: indexer.WarmCache,
    p2p: p2p.SyncEngine,
    config: Config,
    height: std.atomic.Atomic(u32),
    tip_hash: std.atomic.Atomic([32]u8),

    pub fn init(allocator: Allocator, config: Config) !Indexer {
        var idx = Indexer{
            .allocator = allocator,
            .arena = arena.Arena.init(allocator, config.hot_cache_mib * 1024 * 1024),
            .hot_cache = indexer.HotCache.init(allocator, config.hot_cache_mib * 1024 * 1024),
            .warm_cache = indexer.WarmCache.init(allocator, config.data_dir, config.warm_cache_mib * 1024 * 1024),
            .p2p = p2p.SyncEngine.init(allocator, config.network, config.max_peers),
            .config = config,
            .height = std.atomic.Atomic(u32).init(0),
            .tip_hash = std.atomic.Atomic([32]u8).init([32]u8{0} ** 32),
        };
        try idx.p2p.start();
        return idx;
    }

    pub fn deinit(self: *Indexer) void {
        self.p2p.stop();
        self.warm_cache.deinit();
        self.hot_cache.deinit();
        self.arena.deinit();
    }

    pub fn getUtxo(self: *Indexer, outpoint: bsv.OutPoint) ?indexer.UtxoEntry {
        if (self.hot_cache.get(outpoint)) |entry| return entry;
        return self.warm_cache.get(outpoint);
    }

    pub fn scanScript(self: *Indexer, pattern: []const u8, callback: fn (bsv.OutPoint, []const u8) bool) void {
        self.hot_cache.scanScript(pattern, callback);
        self.warm_cache.scanScript(pattern, callback);
    }

    pub fn getHeight(self: *Indexer) u32 {
        return self.height.load(.monotonic);
    }

    pub fn getTipHash(self: *Indexer) [32]u8 {
        return self.tip_hash.load(.monotonic);
    }

    pub fn sync(self: *Indexer) !void {
        try self.p2p.sync(.{
            .on_header = self.processHeader,
            .on_block = self.processBlock,
            .on_utxo = self.indexUtxo,
            .ctx = self,
        });
    }

    fn processHeader(ctx: *Indexer, header: bsv.BlockHeader) !void {
        ctx.height.store(header.height, .monotonic);
        ctx.tip_hash.store(header.hash, .monotonic);
    }

    fn processBlock(ctx: *Indexer, block: bsv.Block) !void {
        for (block.txs) |tx| {
            for (tx.outputs) |out, i| {
                if (!out.script.len) continue;
                const outpoint = bsv.OutPoint{ .txid = tx.txid, .vout = @intCast(u32, i) };
                _ = ctx.indexUtxo(outpoint, out.value, out.script, block.height);
            }
            for (tx.inputs) |input| {
                _ = ctx.hot_cache.spend(input.prev_out);
                _ = ctx.warm_cache.spend(input.prev_out);
            }
        }
    }

    fn indexUtxo(ctx: *Indexer, outpoint: bsv.OutPoint, value: u64, script: []const u8, height: u32) !void {
        const entry = indexer.UtxoEntry{
            .outpoint = outpoint,
            .value = value,
            .script = script,
            .height = height,
            .spent = false,
        };
        if (ctx.hot_cache.shouldPromote()) {
            _ = ctx.hot_cache.insert(outpoint, entry);
        } else {
            _ = ctx.warm_cache.insert(outpoint, entry);
        }
    }
};