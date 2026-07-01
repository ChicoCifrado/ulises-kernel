const std = @import("std");
const console = @import("../hal/console.zig");
const ps2 = @import("../hal/usb.zig");
const brc100 = @import("../bsv/brc100.zig");
const hash = @import("../bsv/hash.zig");
const primitives = @import("../bsv/primitives.zig");
const global_alloc = @import("../mem/global.zig");
const net_stack = @import("../net/stack.zig");

const MAX_HISTORY = 64;
const MAX_LINE = 256;

pub const BuiltinCmd = struct {
    name: []const u8,
    help: []const u8,
    handler: *const fn (args: []const u8, con: *console.Console, ctx: *ShellContext) void,
};

pub const ShellContext = struct {
    history: [MAX_HISTORY][]u8 = undefined,
    history_count: usize = 0,
    history_pos: usize = 0,
    wallet: ?*brc100.KernelWallet = null,
    prompt: []const u8 = "> ",
    theme: Theme = .{},
    running: bool = true,
    net_stack: ?*net_stack.Stack = null,

    pub fn addToHistory(self: *ShellContext, line: []const u8) void {
        const allocator = global_alloc.get();
        if (self.history_count < MAX_HISTORY) {
            self.history[self.history_count] = allocator.dupe(u8, line) catch return;
            self.history_count += 1;
        } else {
            allocator.free(self.history[0]);
            for (1..MAX_HISTORY) |i| self.history[i - 1] = self.history[i];
            self.history[MAX_HISTORY - 1] = allocator.dupe(u8, line) catch return;
        }
        self.history_pos = self.history_count;
    }

    pub fn getHistory(self: *const ShellContext, idx: usize) ?[]const u8 {
        if (idx >= self.history_count) return null;
        return self.history[idx];
    }
};

pub const Theme = struct {
    bracket: console.ConsoleColor = .green,
    path: console.ConsoleColor = .cyan,
    symbol: console.ConsoleColor = .yellow,
    prompt_char: console.ConsoleColor = .white,
    err_color: console.ConsoleColor = .red,
    success: console.ConsoleColor = .green,
    info: console.ConsoleColor = .light_blue,
};

const builtins = [_]BuiltinCmd{
    .{ .name = "help",    .help = "Show available commands",     .handler = cmdHelp },
    .{ .name = "clear",   .help = "Clear the screen",           .handler = cmdClear },
    .{ .name = "exit",    .help = "Exit the shell",             .handler = cmdExit },
    .{ .name = "balance", .help = "Show wallet balance",        .handler = cmdBalance },
    .{ .name = "height",  .help = "Show current block height",  .handler = cmdHeight },
    .{ .name = "network", .help = "Show network (mainnet/testnet)", .handler = cmdNetwork },
    .{ .name = "version", .help = "Show kernel version",        .handler = cmdVersion },
    .{ .name = "utxos",   .help = "List UTXOs for active wallet", .handler = cmdUtxos },
    .{ .name = "status",  .help = "Show system status",         .handler = cmdStatus },
    .{ .name = "history", .help = "Show command history",       .handler = cmdHistory },
    .{ .name = "set",     .help = "Set configuration (e.g. prompt)", .handler = cmdSet },
    .{ .name = "peers",   .help = "Show network peers",         .handler = cmdPeers },
    .{ .name = "pci",     .help = "List PCI devices",           .handler = cmdPci },
    .{ .name = "hash",    .help = "Hash input data with SHA256", .handler = cmdHash },
    .{ .name = "theme",   .help = "Change shell theme",         .handler = cmdTheme },
    .{ .name = "echo",    .help = "Print arguments",            .handler = cmdEcho },
};

pub fn run(ctx: *ShellContext, con: *console.Console, wallet: ?*brc100.KernelWallet) void {
    ctx.wallet = wallet;
    con.clear();
    printBanner(con);

    var input_buf: [MAX_LINE]u8 = undefined;
    while (ctx.running) {
        if (ctx.net_stack) |s| s.poll();
        renderPrompt(con, ctx);
        const line = con.readLine(ctx.prompt, &input_buf) catch {
            con.write("\n");
            continue;
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        ctx.addToHistory(trimmed);
        executeLine(trimmed, con, ctx);
    }
}

fn executeLine(line: []const u8, con: *console.Console, ctx: *ShellContext) void {
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const cmd_name = line[0..first_space];
    const args = if (first_space < line.len) std.mem.trim(u8, line[first_space + 1 ..], " ") else "";

    for (&builtins) |cmd| {
        if (std.mem.eql(u8, cmd_name, cmd.name)) {
            cmd.handler(args, con, ctx);
            return;
        }
    }
    con.setFg(.red);
    con.writeFmt("shell: command not found: {s}\n", .{cmd_name});
    con.setFg(.light_gray);
}

fn renderPrompt(con: *console.Console, ctx: *ShellContext) void {
    con.setFg(ctx.theme.bracket);
    con.write("[");
    con.setFg(ctx.theme.path);
    con.write("ulises");
    con.setFg(ctx.theme.bracket);
    con.write("]");
    con.setFg(ctx.theme.symbol);
    con.write(" ");
    con.setFg(ctx.theme.prompt_char);
    con.write(ctx.prompt);
    con.setFg(.light_gray);
}

fn printBanner(con: *console.Console) void {
    con.setFg(.cyan);
    con.write("\n");
    con.write("  +---------------------------------------+\n");
    con.write("  |  Ulises Kernel v1.0.0               |\n");
    con.write("  |  BSV Unikernel  BRC Stack             |\n");
    con.write("  +---------------------------------------+\n");
    con.write("\n");
    con.setFg(.light_gray);
    con.write("  Type 'help' for available commands.\n\n");
}

fn cmdHelp(_: []const u8, con: *console.Console, _: *ShellContext) void {
    con.setFg(.yellow);
    con.write("  Available commands:\n");
    con.setFg(.light_gray);
    for (&builtins) |cmd| {
        con.setFg(.green);
        con.writeFmt("    {s:12}", .{cmd.name});
        con.setFg(.light_gray);
        con.writeFmt(" {s}\n", .{cmd.help});
    }
}

fn cmdClear(_: []const u8, con: *console.Console, _: *ShellContext) void {
    con.clear();
}

fn cmdExit(_: []const u8, _: *console.Console, ctx: *ShellContext) void {
    ctx.running = false;
}

fn cmdBalance(_: []const u8, con: *console.Console, ctx: *ShellContext) void {
    const kw = ctx.wallet orelse {
        con.setFg(.red);
        con.write("  wallet: not initialized\n");
        con.setFg(.light_gray);
        return;
    };
    const bal = kw.getBasketBalance(null) catch {
        con.write("  balance: unavailable\n");
        return;
    };
    con.setFg(.green);
    con.writeFmt("  balance: {} satoshis ({} UTXOs)\n", .{ bal.satoshis, bal.utxo_count });
    con.setFg(.light_gray);
}

fn cmdHeight(_: []const u8, con: *console.Console, ctx: *ShellContext) void {
    const kw = ctx.wallet orelse { con.write("  wallet: n/a\n"); return; };
    con.setFg(.cyan);
    con.writeFmt("  block height: {}\n", .{kw.getHeight()});
    con.setFg(.light_gray);
}

fn cmdNetwork(_: []const u8, con: *console.Console, ctx: *ShellContext) void {
    const kw = ctx.wallet orelse { con.write("  wallet: n/a\n"); return; };
    const net = switch (kw.getNetwork()) {
        .mainnet => "mainnet",
        .testnet => "testnet",
        .regtest => "regtest",
    };
    con.writeFmt("  network: {s}\n", .{net});
}

fn cmdVersion(_: []const u8, con: *console.Console, _: *ShellContext) void {
    con.write("  Ulises Kernel v1.0.0  BRC Stack\n");
}

fn cmdUtxos(_: []const u8, con: *console.Console, ctx: *ShellContext) void {
    _ = ctx;
    con.write("  (UTXO listing requires active wallet)\n");
}

fn cmdStatus(_: []const u8, con: *console.Console, ctx: *ShellContext) void {
    con.setFg(.cyan);
    con.write("  Ulises Kernel  System Status\n");
    con.setFg(.light_gray);
    con.writeFmt("  commands in history: {}\n", .{ctx.history_count});
    if (ctx.wallet) |kw| {
        con.writeFmt("  network: {s}\n", .{switch (kw.getNetwork()) {
            .mainnet => "mainnet", .testnet => "testnet", .regtest => "regtest",
        }});
        con.writeFmt("  height: {}\n", .{kw.getHeight()});
    }
}

fn cmdHistory(_: []const u8, con: *console.Console, ctx: *ShellContext) void {
    for (0..ctx.history_count) |i| {
        con.writeFmt("  {d:4}  {s}\n", .{ i + 1, ctx.history[i] });
    }
}

fn cmdSet(args: []const u8, con: *console.Console, ctx: *ShellContext) void {
    const eq_idx = std.mem.indexOfScalar(u8, args, '=') orelse {
        con.write("  usage: set key=value\n"); return;
    };
    const key = std.mem.trim(u8, args[0..eq_idx], " ");
    const val = std.mem.trim(u8, args[eq_idx + 1 ..], " ");
    if (std.mem.eql(u8, key, "prompt")) {
        ctx.prompt = val;
        con.writeFmt("  prompt set to: {s}\n", .{val});
    } else {
        con.writeFmt("  unknown key: {s}\n", .{key});
    }
}

fn cmdPeers(_: []const u8, con: *console.Console, ctx: *ShellContext) void {
    if (ctx.net_stack) |s| {
        con.writeFmt("  IP: {}.{}.{}.{} / GW: {}.{}.{}.{}\n", .{
            s.our_ip[0], s.our_ip[1], s.our_ip[2], s.our_ip[3],
            s.our_gateway[0], s.our_gateway[1], s.our_gateway[2], s.our_gateway[3],
        });
        con.writeFmt("  MAC: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
            s.our_mac[0], s.our_mac[1], s.our_mac[2], s.our_mac[3], s.our_mac[4], s.our_mac[5],
        });
        con.writeFmt("  ARP cache: {d} entries\n", .{s.arp_cache.count});
    } else {
        con.write("  network: not available (no NIC)\n");
    }
}

fn cmdPci(_: []const u8, con: *console.Console, _: *ShellContext) void {
    con.write("  pci: run 'pci' on actual hardware\n");
}

fn cmdHash(args: []const u8, con: *console.Console, _: *ShellContext) void {
    const h = hash.sha256(args);
    con.setFg(.green);
    const hex = "0123456789abcdef";
    for (h) |b| {
        con.putChar(hex[b >> 4]);
        con.putChar(hex[b & 0x0F]);
    }
    con.write("\n");
    con.setFg(.light_gray);
}

fn cmdTheme(args: []const u8, con: *console.Console, ctx: *ShellContext) void {
    const theme_name = std.mem.trim(u8, args, " ");
    if (std.mem.eql(u8, theme_name, "retro")) {
        ctx.theme = .{ .bracket = .green, .path = .brown, .symbol = .yellow, .prompt_char = .white, .err_color = .red, .success = .green, .info = .light_blue };
        con.write("  theme: retro\n");
    } else if (std.mem.eql(u8, theme_name, "cyber")) {
        ctx.theme = .{ .bracket = .cyan, .path = .light_cyan, .symbol = .light_magenta, .prompt_char = .green, .err_color = .light_red, .success = .green, .info = .cyan };
        con.write("  theme: cyber\n");
    } else if (std.mem.eql(u8, theme_name, "minimal")) {
        ctx.theme = .{ .bracket = .dark_gray, .path = .light_gray, .symbol = .light_gray, .prompt_char = .white, .err_color = .red, .success = .white, .info = .light_gray };
        con.write("  theme: minimal\n");
    } else {
        con.write("  themes: retro, cyber, minimal\n");
    }
}

fn cmdEcho(args: []const u8, con: *console.Console, _: *ShellContext) void {
    con.writeFmt("  {s}\n", .{args});
}

test "shell context init" {
    const ctx = ShellContext{};
    try std.testing.expect(ctx.running);
    try std.testing.expectEqual(@as(usize, 0), ctx.history_count);
}

test "shell add to history" {
    var ctx = ShellContext{};
    ctx.addToHistory("help");
    try std.testing.expectEqual(@as(usize, 1), ctx.history_count);
    const h = ctx.getHistory(0).?;
    try std.testing.expectEqualSlices(u8, "help", h);
}

test "shell builtin names" {
    for (&builtins) |cmd| {
        try std.testing.expect(cmd.name.len > 0);
        try std.testing.expect(cmd.help.len > 0);
    }
}

test "theme defaults" {
    const theme = Theme{};
    try std.testing.expectEqual(@intFromEnum(console.ConsoleColor.green), @intFromEnum(theme.bracket));
}
