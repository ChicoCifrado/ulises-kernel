const std = @import("std");

pub const Message = struct {
    pub const Kind = enum(u8) {
        balance_check = 0x01,
        utxo_scan = 0x02,
        tx_build = 0x03,
        tx_sign = 0x04,
        tx_broadcast = 0x05,
        wallet_create = 0x06,
        market_check = 0x07,
        trade_execute = 0x08,
        agent_status = 0x09,
        tool_call = 0x0A,
    };

    kind: Kind,
    payload: []const u8,
    reply_channel: ?*ReplyChannel = null,
};

pub const ReplyChannel = struct {
    data: ?[]const u8 = null,
    ready: bool = false,

    pub fn send(self: *ReplyChannel, data: []const u8) void {
        self.data = data;
        self.ready = true;
    }

    pub fn recv(self: *ReplyChannel) ?[]const u8 {
        if (!self.ready) return null;
        return self.data;
    }
};

pub const Tool = struct {
    name: []const u8,
    handler: *const fn (ctx: *anyopaque, args: []const u8) []const u8,
};

pub const AgentScheduler = struct {
    task_queue: std.ArrayListUnmanaged(Message),
    tools: std.StringArrayHashMapUnmanaged(Tool),
    agent_ctx: *anyopaque,

    pub fn init(_: std.mem.Allocator, agent_ctx: *anyopaque, _: *const anyopaque) AgentScheduler {
        return .{
            .task_queue = .empty,
            .tools = .empty,
            .agent_ctx = agent_ctx,
        };
    }

    pub fn deinit(self: *AgentScheduler, allocator: std.mem.Allocator) void {
        self.task_queue.deinit(allocator);
        self.tools.deinit(allocator);
    }

    pub fn registerTool(self: *AgentScheduler, allocator: std.mem.Allocator, name: []const u8, tool: Tool) !void {
        try self.tools.put(allocator, name, tool);
    }

    pub fn enqueue(self: *AgentScheduler, allocator: std.mem.Allocator, msg: Message) !void {
        try self.task_queue.append(allocator, msg);
    }

    pub fn processOnce(self: *AgentScheduler) void {
        if (self.task_queue.items.len == 0) return;
        const msg = self.task_queue.orderedRemove(0);
        self.dispatch(msg);
    }

    pub fn processAll(self: *AgentScheduler) void {
        while (self.task_queue.items.len > 0) {
            const msg = self.task_queue.orderedRemove(0);
            self.dispatch(msg);
        }
    }

    pub fn processN(self: *AgentScheduler, n: usize) void {
        var count: usize = 0;
        while (self.task_queue.items.len > 0 and count < n) {
            const msg = self.task_queue.orderedRemove(0);
            self.dispatch(msg);
            count += 1;
        }
    }

    pub fn pendingCount(self: *const AgentScheduler) usize {
        return self.task_queue.items.len;
    }

    fn dispatch(self: *AgentScheduler, msg: Message) void {
        switch (msg.kind) {
            .agent_status => {
                if (msg.reply_channel) |ch| {
                    ch.send("running");
                }
            },
            .tool_call => {
                const colon = std.mem.indexOfScalar(u8, msg.payload, ':');
                const tool_name = if (colon) |c| msg.payload[0..c] else msg.payload;
                const args = if (colon) |c| msg.payload[c + 1 ..] else "";

                if (self.tools.get(tool_name)) |tool| {
                    const result = tool.handler(self.agent_ctx, args);
                    if (msg.reply_channel) |ch| {
                        ch.send(result);
                    }
                } else {
                    if (msg.reply_channel) |ch| {
                        ch.send("error: unknown tool");
                    }
                }
            },
            else => {
                if (msg.reply_channel) |ch| {
                    ch.send("ack");
                }
            },
        }
    }
};

test "agent scheduler basic" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    var hal: u8 = 0;

    var scheduler = AgentScheduler.init(allocator, &dummy, &hal);
    defer scheduler.deinit(allocator);

    try scheduler.enqueue(allocator, .{ .kind = .agent_status, .payload = "" });
    try scheduler.enqueue(allocator, .{ .kind = .balance_check, .payload = "addr" });

    try std.testing.expectEqual(2, scheduler.pendingCount());
    scheduler.processAll();
    try std.testing.expectEqual(0, scheduler.pendingCount());
}

test "agent scheduler tool call" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    var hal: u8 = 0;

    var scheduler = AgentScheduler.init(allocator, &dummy, &hal);
    defer scheduler.deinit(allocator);

    try scheduler.registerTool(allocator, "ping", .{
        .name = "ping",
        .handler = struct {
            fn f(_: *anyopaque, _: []const u8) []const u8 {
                return "pong";
            }
        }.f,
    });

    var ch = ReplyChannel{};
    try scheduler.enqueue(allocator, .{
        .kind = .tool_call,
        .payload = "ping:",
        .reply_channel = &ch,
    });

    scheduler.processOnce();
    try std.testing.expect(ch.ready);
    try std.testing.expectEqualSlices(u8, "pong", ch.data.?);
}
