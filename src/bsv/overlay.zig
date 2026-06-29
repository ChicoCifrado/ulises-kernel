const std = @import("std");
const Sha256 = @import("hash.zig").Sha256;
const hash = @import("hash.zig");
const basm = @import("basm.zig");

pub const OverlayError = error{
    UnknownTopic,
    AdmitFailed,
    ReconcileFailed,
    SyncInProgress,
    InvalidMessage,
    NotImplemented,
};

pub const TopicId = [32]u8;

pub const TopicManager = struct {
    const Self = @This();

    id: TopicId,
    name: []const u8,
    chain: basm.TopicAnchorChain,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Self {
        var topic_id: TopicId = @splat(0);
        const name_hash = hash.sha256(name);
        @memcpy(&topic_id, &name_hash);
        return .{
            .id = topic_id,
            .name = try allocator.dupe(u8, name),
            .chain = basm.TopicAnchorChain.init(topic_id),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.chain.deinit(self.allocator);
        self.allocator.free(self.name);
    }

    pub fn admitTx(self: *Self, txid: [32]u8) !void {
        const height = self.chain.latestHeight() orelse {
            _ = try self.chain.addBlock(self.allocator, 0);
            return self.admitTx(txid);
        };
        const anchor = self.chain.getAnchor(height) orelse {
            _ = try self.chain.addBlock(self.allocator, height + 1);
            return self.admitTx(txid);
        };
        anchor.admit(self.allocator, txid) catch {};
    }

    pub fn syncToHeight(self: *Self, height: u32) !void {
        const current = self.chain.latestHeight() orelse 0;
        var h = current + 1;
        while (h <= height) : (h += 1) {
            _ = try self.chain.addBlock(self.allocator, h);
        }
    }

    pub fn latestAnchor(self: *const Self) ?[32]u8 {
        return self.chain.latestAnchorId();
    }
};

pub const ShipMessage = struct {
    pub const Kind = enum(u8) {
        hello = 0x00,
        get_admittances = 0x01,
        admittances = 0x02,
        get_tba = 0x03,
        tba = 0x04,
        get_proof = 0x05,
        proof = 0x06,
        get_sync = 0x07,
        sync_done = 0x08,
        err = 0xFF,
    };

    kind: Kind,
    topic: TopicId,
    payload: []const u8,
};

pub const SlapMessage = struct {
    pub const Kind = enum(u8) {
        submit = 0x00,
        admit = 0x01,
        reject = 0x02,
        query = 0x03,
        response = 0x04,
    };

    kind: Kind,
    topic: TopicId,
    payload: []const u8,
};

pub const OverlayNode = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    topic_managers: std.StringArrayHashMapUnmanaged(TopicManager),
    peers: std.ArrayListUnmanaged(PeerInfo),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .topic_managers = .{},
            .peers = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.topic_managers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.topic_managers.deinit(self.allocator);
        self.peers.deinit(self.allocator);
    }

    pub fn registerTopic(self: *Self, name: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        var mgr = try TopicManager.init(self.allocator, name);
        errdefer mgr.deinit();
        try self.topic_managers.put(self.allocator, owned_name, mgr);
    }

    pub fn getTopicManager(self: *Self, name: []const u8) ?*TopicManager {
        return self.topic_managers.getPtr(name);
    }

    pub fn processSlapSubmit(self: *Self, msg: SlapMessage) !void {
        const mgr = self.topic_managers.getPtr(@as([]const u8, @ptrCast(&msg.topic))) orelse return error.UnknownTopic;
        var txid: [32]u8 = @splat(0);
        if (msg.payload.len >= 32) {
            @memcpy(&txid, msg.payload[0..32]);
        }
        try mgr.admitTx(txid);
    }

    pub fn reconcileWithPeer(_: *Self, _: usize) !void {
        return error.NotImplemented;
    }

    pub fn topicCount(self: *const Self) usize {
        return self.topic_managers.count();
    }

    pub fn peerCount(self: *const Self) usize {
        return self.peers.items.len;
    }

    pub fn addPeer(self: *Self, info: PeerInfo) !void {
        try self.peers.append(self.allocator, info);
    }
};

pub const PeerInfo = struct {
    id: [32]u8,
    address: []const u8,
    port: u16,
    topics: []TopicId,
};

pub fn computeTopicId(name: []const u8) TopicId {
    var id: TopicId = @splat(0);
    const name_hash = hash.sha256(name);
    @memcpy(&id, &name_hash);
    return id;
}

test "topic manager init" {
    const allocator = std.testing.allocator;
    var mgr = try TopicManager.init(allocator, "test-topic");
    defer mgr.deinit();
    try std.testing.expect(mgr.latestAnchor() == null);
}

test "topic manager admit tx" {
    const allocator = std.testing.allocator;
    var mgr = try TopicManager.init(allocator, "payments");
    defer mgr.deinit();

    const txid: [32]u8 = @splat(0xAA);
    try mgr.admitTx(txid);
    try mgr.syncToHeight(100);
    try std.testing.expect(mgr.latestAnchor() != null);
}

test "topic manager sync to height" {
    const allocator = std.testing.allocator;
    var mgr = try TopicManager.init(allocator, "sync-test");
    defer mgr.deinit();

    try mgr.syncToHeight(1000);
    const latest = mgr.latestAnchor();
    try std.testing.expect(latest != null);
}

test "overlay node register topic" {
    const allocator = std.testing.allocator;
    var node = OverlayNode.init(allocator);
    defer node.deinit();

    try node.registerTopic("market");
    try node.registerTopic("chat");
    try std.testing.expectEqual(@as(usize, 2), node.topicCount());
}

test "overlay node process slap submit" {
    const allocator = std.testing.allocator;
    var node = OverlayNode.init(allocator);
    defer node.deinit();

    try node.registerTopic("payments");
    const topic_id = computeTopicId("payments");
    const msg = SlapMessage{
        .kind = .submit,
        .topic = topic_id,
        .payload = &(@as([32]u8, @splat(0xDD)) ++ [_]u8{0x00}),
    };
    try node.processSlapSubmit(msg);
}

test "overlay node peer management" {
    const allocator = std.testing.allocator;
    var node = OverlayNode.init(allocator);
    defer node.deinit();

    try node.addPeer(.{
        .id = @as([32]u8, @splat(0xAA)),
        .address = "127.0.0.1",
        .port = 8333,
        .topics = &.{},
    });
    try std.testing.expectEqual(@as(usize, 1), node.peerCount());
}

test "compute topic id" {
    const id = computeTopicId("hello");
    try std.testing.expectEqual(32, id.len);
    const id2 = computeTopicId("hello");
    try std.testing.expect(std.mem.eql(u8, &id, &id2));
    const id3 = computeTopicId("world");
    try std.testing.expect(!std.mem.eql(u8, &id, &id3));
}
