const std = @import("std");
const Sha256 = @import("hash.zig").Sha256;
const hash = @import("hash.zig");
const global_alloc = @import("../mem/global.zig");

pub const BasmError = error{
    TreeFull,
    InvalidDepth,
    NodeNotFound,
    InvalidProof,
    MerkleMismatch,
};

fn hashPair(left: [32]u8, right: [32]u8) [32]u8 {
    var state = Sha256.init(.{});
    state.update(&left);
    state.update(&right);
    return state.final();
}

fn leafHash(data: []const u8) [32]u8 {
    return hash.sha256(data);
}

fn zeroHash(depth: usize, max_depth: usize) [32]u8 {
    var z: [32]u8 = [_]u8{0} ** 32;
    var d: usize = 0;
    while (d < max_depth - depth) : (d += 1) {
        z = hashPair(z, z);
    }
    return z;
}

pub const SparseMerkleTree = struct {
    const Self = @This();

    nodes: std.AutoArrayHashMapUnmanaged(u64, [32]u8),
    max_depth: usize,
    leaf_count: usize,

    pub fn init() Self {
        return .{
            .nodes = .{},
            .max_depth = 0,
            .leaf_count = 0,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }

fn pathForKey(key: u64, depth: usize) u64 {
    const shift = @as(u6, @intCast(64 -% depth));
    return key >> shift;
}

    pub fn insert(self: *Self, allocator: std.mem.Allocator, key: u64, data: []const u8, tree_depth: usize) !void {
        const leaf = leafHash(data);
        const shift = @as(u6, @intCast(64 -% tree_depth));
        const index = pathForKey(key, tree_depth) >> shift;
        try self.nodes.put(allocator, index, leaf);

        var d = tree_depth;
        while (d > 0) {
            d -= 1;
            const sibling_bit = (index >> d) & 1;
            const sibling_idx = (index & ~(@as(u64, 1) << d)) | (sibling_bit ^ 1) << d;
            const left_idx = if (sibling_bit == 0) index else sibling_idx;
            const right_idx = if (sibling_bit == 0) sibling_idx else index;

            const left = self.nodes.get(left_idx >> (64 - tree_depth + d + 1)) orelse zeroHash(tree_depth - d - 1, tree_depth);
            const right = self.nodes.get(right_idx >> (64 - tree_depth + d + 1)) orelse zeroHash(tree_depth - d - 1, tree_depth);
            const parent = hashPair(left, right);
            try self.nodes.put(allocator, index >> (64 - tree_depth + d), parent);
        }

        if (tree_depth > self.max_depth) {
            self.max_depth = tree_depth;
        }
        self.leaf_count += 1;
    }

    pub fn getRoot(self: *const Self) [32]u8 {
        if (self.max_depth == 0 or self.leaf_count == 0) {
            return zeroHash(0, 0);
        }
        const root_idx: u64 = 1;
        return self.nodes.get(root_idx) orelse zeroHash(0, 0);
    }

    pub fn prove(self: *const Self, key: u64, tree_depth: usize) !struct { leaf: [32]u8, siblings: [][32]u8 } {
        const index = pathForKey(key, tree_depth) >> (64 - tree_depth);
        const leaf = self.nodes.get(index) orelse return error.NodeNotFound;

        var siblings = try std.ArrayList([32]u8).initCapacity(global_alloc.get(), tree_depth);
        var d: usize = 0;
        while (d < tree_depth) : (d += 1) {
            const sibling_bit = (index >> d) & 1;
            const sibling_idx = (index & ~(@as(u64, 1) << d)) | (sibling_bit ^ 1) << d;
            const sib = self.nodes.get(sibling_idx >> (64 - tree_depth + d + 1)) orelse zeroHash(tree_depth - d - 1, tree_depth);
            siblings.appendAssumeCapacity(sib);
        }

        return .{ .leaf = leaf, .siblings = siblings.items };
    }

    pub fn verify(root: [32]u8, key: u64, leaf: [32]u8, siblings: [][32]u8, tree_depth: usize) bool {
        const index = pathForKey(key, tree_depth) >> (64 - tree_depth);
        var current = leaf;
        var d: usize = 0;
        while (d < tree_depth) : (d += 1) {
            const sibling_bit = (index >> d) & 1;
            current = if (sibling_bit == 0) hashPair(current, siblings[d]) else hashPair(siblings[d], current);
        }
        return std.mem.eql(u8, &current, &root);
    }
};

pub const TopicBlockAnchor = struct {
    block_height: u32,
    topic: [32]u8,
    tree: SparseMerkleTree,
    root: [32]u8,

    pub fn init(block_height: u32, topic: [32]u8) TopicBlockAnchor {
        return .{
            .block_height = block_height,
            .topic = topic,
            .tree = SparseMerkleTree.init(),
            .root = [_]u8{0} ** 32,
        };
    }

    pub fn deinit(self: *TopicBlockAnchor, allocator: std.mem.Allocator) void {
        self.tree.deinit(allocator);
    }

    pub fn admit(self: *TopicBlockAnchor, allocator: std.mem.Allocator, txid: [32]u8) !void {
        const key = @as(u64, self.block_height) + txid[0];
        try self.tree.insert(allocator, key, &txid, 40);
        self.root = self.tree.getRoot();
    }

    pub fn commit(self: *TopicBlockAnchor) [32]u8 {
        self.root = self.tree.getRoot();
        return self.root;
    }

    pub fn computeAnchorId(self: *const TopicBlockAnchor, prev_anchor: [32]u8) [32]u8 {
        var state = Sha256.init(.{});
        var h_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &h_bytes, self.block_height, .little);
        state.update(&h_bytes);
        state.update(&self.topic);
        state.update(&self.root);
        state.update(&prev_anchor);
        return state.final();
    }
};

pub const TbaBlock = struct {
    anchor: TopicBlockAnchor,
    prev_anchor_id: [32]u8,
    anchor_id: [32]u8,
};

pub const TopicAnchorChain = struct {
    const Self = @This();

    blocks: std.ArrayListUnmanaged(TbaBlock),
    topic: [32]u8,

    pub fn init(topic: [32]u8) Self {
        return .{
            .blocks = .{},
            .topic = topic,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| {
            block.anchor.deinit(allocator);
        }
        self.blocks.deinit(allocator);
    }

    pub fn addBlock(self: *Self, allocator: std.mem.Allocator, block_height: u32) !*TopicBlockAnchor {
        const prev_id = if (self.blocks.items.len > 0) self.blocks.items[self.blocks.items.len - 1].anchor_id else [_]u8{0} ** 32;

        var anchor = TopicBlockAnchor.init(block_height, self.topic);
        const anchor_id = anchor.computeAnchorId(prev_id);

        try self.blocks.append(allocator, .{
            .anchor = anchor,
            .prev_anchor_id = prev_id,
            .anchor_id = anchor_id,
        });

        return &self.blocks.items[self.blocks.items.len - 1].anchor;
    }

    pub fn latestAnchorId(self: *const Self) ?[32]u8 {
        if (self.blocks.items.len == 0) return null;
        return self.blocks.items[self.blocks.items.len - 1].anchor_id;
    }

    pub fn latestHeight(self: *const Self) ?u32 {
        if (self.blocks.items.len == 0) return null;
        return self.blocks.items[self.blocks.items.len - 1].anchor.block_height;
    }

    pub fn getAnchor(self: *Self, height: u32) ?*TopicBlockAnchor {
        for (self.blocks.items) |*block| {
            if (block.anchor.block_height == height) return &block.anchor;
        }
        return null;
    }
};

pub const ReconciliationResult = struct {
    common_ancestor: u32,
    local_missing: []u32,
    remote_missing: []u32,
};

pub fn reconcileChains(local: *const TopicAnchorChain, remote: *const TopicAnchorChain, allocator: std.mem.Allocator) ReconciliationResult {
    var local_heights = std.ArrayList(u32).init(allocator);
    var remote_heights = std.ArrayList(u32).init(allocator);

    for (local.blocks.items) |block| {
        local_heights.append(block.anchor.block_height) catch {};
    }
    for (remote.blocks.items) |block| {
        remote_heights.append(block.anchor.block_height) catch {};
    }

    var common: u32 = 0;
    for (local.blocks.items) |lb| {
        for (remote.blocks.items) |rb| {
            if (lb.anchor.block_height == rb.anchor.block_height and
                std.mem.eql(u8, &lb.anchor.root, &rb.anchor.root))
            {
                if (lb.anchor.block_height > common) {
                    common = lb.anchor.block_height;
                }
            }
        }
    }

    return .{ .common_ancestor = common, .local_missing = &.{}, .remote_missing = &.{} };
}

test "sparse merkle tree insert and root" {
    const allocator = std.testing.allocator;
    var tree = SparseMerkleTree.init();
    defer tree.deinit(allocator);

    const data = [_]u8{0xAA} ** 32;
    try tree.insert(allocator, 1, &data, 8);
    const root = tree.getRoot();
    try std.testing.expect(!std.mem.eql(u8, &root, &[_]u8{0} ** 32));
}

test "sparse merkle tree proof verify" {
    const allocator = std.testing.allocator;
    var tree = SparseMerkleTree.init();
    defer tree.deinit(allocator);

    const data = [_]u8{0xBB} ** 32;
    try tree.insert(allocator, 5, &data, 8);
    const root = tree.getRoot();

    const proof = try tree.prove(5, 8);
    defer allocator.free(proof.siblings);
    try std.testing.expect(SparseMerkleTree.verify(root, 5, proof.leaf, proof.siblings, 8));
}

test "sparse merkle tree multi insert" {
    const allocator = std.testing.allocator;
    var tree = SparseMerkleTree.init();
    defer tree.deinit(allocator);

    try tree.insert(allocator, 0, &[_]u8{0xAA} ** 32, 8);
    try tree.insert(allocator, 1, &[_]u8{0xBB} ** 32, 8);
    try tree.insert(allocator, 2, &[_]u8{0xCC} ** 32, 8);

    const root = tree.getRoot();
    try std.testing.expect(!std.mem.eql(u8, &root, &[_]u8{0} ** 32));
    try std.testing.expectEqual(@as(usize, 3), tree.leaf_count);
}

test "topic block anchor admit and commit" {
    const allocator = std.testing.allocator;
    var topic: [32]u8 = [_]u8{0} ** 32;
    @memcpy(topic[0..5], "topic");
    var tba = TopicBlockAnchor.init(800000, topic);
    defer tba.deinit(allocator);

    const txid = [_]u8{0xDD} ** 32;
    try tba.admit(allocator, txid);
    const root = tba.commit();
    try std.testing.expect(!std.mem.eql(u8, &root, &[_]u8{0} ** 32));
}

test "topic anchor chain add block" {
    const allocator = std.testing.allocator;
    var topic: [32]u8 = [_]u8{0} ** 32;
    @memcpy(topic[0..5], "topic");

    var chain = TopicAnchorChain.init(topic);
    defer chain.deinit(allocator);

    _ = try chain.addBlock(allocator, 800000);
    _ = try chain.addBlock(allocator, 800001);

    const latest = chain.latestAnchorId();
    try std.testing.expect(latest != null);
    try std.testing.expectEqual(@as(u32, 800001), chain.latestHeight().?);
}

test "topic anchor chain anchor id chain" {
    const allocator = std.testing.allocator;
    var topic: [32]u8 = [_]u8{0} ** 32;
    @memcpy(topic[0..2], "t1");

    var chain = TopicAnchorChain.init(topic);
    defer chain.deinit(allocator);

    _ = try chain.addBlock(allocator, 100);
    _ = try chain.addBlock(allocator, 101);
    _ = try chain.addBlock(allocator, 102);

    try std.testing.expectEqual(@as(usize, 3), chain.blocks.items.len);
    const first = chain.blocks.items[0];
    const second = chain.blocks.items[1];
    try std.testing.expect(!std.mem.eql(u8, &first.anchor_id, &second.anchor_id));
    try std.testing.expect(std.mem.eql(u8, &first.anchor_id, &second.prev_anchor_id));
}

test "merkle tree proof verify with zeros" {
    const allocator = std.testing.allocator;
    var tree = SparseMerkleTree.init();
    defer tree.deinit(allocator);

    try tree.insert(allocator, 42, &[_]u8{0xAA} ** 32, 16);
    const root = tree.getRoot();

    const proof = try tree.prove(42, 16);
    defer allocator.free(proof.siblings);

    try std.testing.expect(SparseMerkleTree.verify(root, 42, proof.leaf, proof.siblings, 16));
    try std.testing.expect(!SparseMerkleTree.verify(root, 43, proof.leaf, proof.siblings, 16));
}

test "tba compute anchor id" {
    const allocator = std.testing.allocator;
    const topic: [32]u8 = [_]u8{0} ** 32;
    var tba = TopicBlockAnchor.init(500000, topic);
    defer tba.deinit(allocator);

    const prev = [_]u8{0xAA} ** 32;
    const prev2 = [_]u8{0xBB} ** 32;
    const id1 = tba.computeAnchorId(prev);
    const id2 = tba.computeAnchorId(prev2);
    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}
