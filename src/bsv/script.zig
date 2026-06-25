const std = @import("std");
const Sha256 = @import("hash.zig").Sha256;
const Ripemd160 = @import("ripemd.zig").Ripemd160;
const hash = @import("hash.zig");
const secp = @import("secp256k1.zig").secp256k1;

pub const Opcode = enum(u8) {
    OP_0 = 0x00,
    OP_PUSHDATA1 = 0x4c,
    OP_PUSHDATA2 = 0x4d,
    OP_PUSHDATA4 = 0x4e,
    OP_1NEGATE = 0x4f,
    OP_1 = 0x51,
    OP_2 = 0x52,
    OP_3 = 0x53,
    OP_4 = 0x54,
    OP_5 = 0x55,
    OP_6 = 0x56,
    OP_7 = 0x57,
    OP_8 = 0x58,
    OP_9 = 0x59,
    OP_10 = 0x5a,
    OP_11 = 0x5b,
    OP_12 = 0x5c,
    OP_13 = 0x5d,
    OP_14 = 0x5e,
    OP_15 = 0x5f,
    OP_16 = 0x60,
    OP_NOP = 0x61,
    OP_IF = 0x63,
    OP_NOTIF = 0x64,
    OP_ELSE = 0x67,
    OP_ENDIF = 0x68,
    OP_VERIFY = 0x69,
    OP_RETURN = 0x6a,
    OP_TOALTSTACK = 0x6b,
    OP_FROMALTSTACK = 0x6c,
    OP_2DROP = 0x6d,
    OP_2DUP = 0x6e,
    OP_3DUP = 0x6f,
    OP_2OVER = 0x70,
    OP_2ROT = 0x71,
    OP_2SWAP = 0x72,
    OP_IFDUP = 0x73,
    OP_DEPTH = 0x74,
    OP_DROP = 0x75,
    OP_DUP = 0x76,
    OP_NIP = 0x77,
    OP_OVER = 0x78,
    OP_PICK = 0x79,
    OP_ROLL = 0x7a,
    OP_ROT = 0x7b,
    OP_SWAP = 0x7c,
    OP_TUCK = 0x7d,
    OP_CAT = 0x7e,
    OP_SPLIT = 0x7f,
    OP_NUM2BIN = 0x80,
    OP_BIN2NUM = 0x81,
    OP_SIZE = 0x82,
    OP_INVERT = 0x83,
    OP_AND = 0x84,
    OP_OR = 0x85,
    OP_XOR = 0x86,
    OP_EQUAL = 0x87,
    OP_EQUALVERIFY = 0x88,
    OP_1ADD = 0x8b,
    OP_1SUB = 0x8c,
    OP_2MUL = 0x8d,
    OP_2DIV = 0x8e,
    OP_NEGATE = 0x8f,
    OP_ABS = 0x90,
    OP_NOT = 0x91,
    OP_0NOTEQUAL = 0x92,
    OP_ADD = 0x93,
    OP_SUB = 0x94,
    OP_MUL = 0x95,
    OP_DIV = 0x96,
    OP_MOD = 0x97,
    OP_LSHIFT = 0x98,
    OP_RSHIFT = 0x99,
    OP_BOOLAND = 0x9a,
    OP_BOOLOR = 0x9b,
    OP_NUMEQUAL = 0x9c,
    OP_NUMEQUALVERIFY = 0x9d,
    OP_NUMNOTEQUAL = 0x9e,
    OP_LESSTHAN = 0x9f,
    OP_GREATERTHAN = 0xa0,
    OP_LESSTHANOREQUAL = 0xa1,
    OP_GREATERTHANOREQUAL = 0xa2,
    OP_MIN = 0xa3,
    OP_MAX = 0xa4,
    OP_WITHIN = 0xa5,
    OP_RIPEMD160 = 0xa6,
    OP_SHA1 = 0xa7,
    OP_SHA256 = 0xa8,
    OP_HASH160 = 0xa9,
    OP_HASH256 = 0xaa,
    OP_CODESEPARATOR = 0xab,
    OP_CHECKSIG = 0xac,
    OP_CHECKSIGVERIFY = 0xad,
    OP_CHECKMULTISIG = 0xae,
    OP_CHECKMULTISIGVERIFY = 0xaf,
    OP_NOP1 = 0xb0,
    OP_NOP2 = 0xb1,
    OP_NOP3 = 0xb2,
    OP_NOP4 = 0xb3,
    OP_NOP5 = 0xb4,
    OP_NOP6 = 0xb5,
    OP_NOP7 = 0xb6,
    OP_NOP8 = 0xb7,
    OP_NOP9 = 0xb8,
    OP_NOP10 = 0xb9,
    OP_CHECKDATASIG = 0xba,
    OP_CHECKDATASIGVERIFY = 0xbb,
    OP_RETURN185 = 0xb9,
    OP_RETURN_186 = 0xba,
    OP_RETURN_187 = 0xbb,
    OP_RETURN_188 = 0xbc,
    OP_RETURN_189 = 0xbd,
    OP_RETURN_190 = 0xbe,
    OP_RETURN_191 = 0xbf,
    OP_RETURN_192 = 0xc0,
    OP_RETURN_193 = 0xc1,
    OP_RETURN_194 = 0xc2,
    OP_RETURN_195 = 0xc3,
    OP_RETURN_196 = 0xc4,
    OP_RETURN_197 = 0xc5,
    OP_RETURN_198 = 0xc6,
    OP_RETURN_199 = 0xc7,
    OP_RETURN_200 = 0xc8,
    OP_RETURN_201 = 0xc9,
    OP_RETURN_202 = 0xca,
    OP_RETURN_203 = 0xcb,
    OP_RETURN_204 = 0xcc,
    OP_RETURN_205 = 0xcd,
    OP_RETURN_206 = 0xce,
    OP_RETURN_207 = 0xcf,
    OP_RETURN_208 = 0xd0,
    OP_RETURN_209 = 0xd1,
    OP_RETURN_210 = 0xd2,
    OP_RETURN_211 = 0xd3,
    OP_RETURN_212 = 0xd4,
    OP_RETURN_213 = 0xd5,
    OP_RETURN_214 = 0xd6,
    OP_RETURN_215 = 0xd7,
    OP_RETURN_216 = 0xd8,
    OP_RETURN_217 = 0xd9,
    OP_RETURN_218 = 0xda,
    OP_RETURN_219 = 0xdb,
    OP_RETURN_220 = 0xdc,
    OP_RETURN_221 = 0xdd,
    OP_RETURN_222 = 0xde,
    OP_RETURN_223 = 0xdf,
    OP_RETURN_224 = 0xe0,
    OP_RETURN_225 = 0xe1,
    OP_RETURN_226 = 0xe2,
    OP_RETURN_227 = 0xe3,
    OP_RETURN_228 = 0xe4,
    OP_RETURN_229 = 0xe5,
    OP_RETURN_230 = 0xe6,
    OP_RETURN_231 = 0xe7,
    OP_RETURN_232 = 0xe8,
    OP_RETURN_233 = 0xe9,
    OP_RETURN_234 = 0xea,
    OP_RETURN_235 = 0xeb,
    OP_RETURN_236 = 0xec,
    OP_RETURN_237 = 0xed,
    OP_RETURN_238 = 0xee,
    OP_RETURN_239 = 0xef,
    OP_RETURN_240 = 0xf0,
    OP_RETURN_241 = 0xf1,
    OP_RETURN_242 = 0xf2,
    OP_RETURN_243 = 0xf3,
    OP_RETURN_244 = 0xf4,
    OP_RETURN_245 = 0xf5,
    OP_RETURN_246 = 0xf6,
    OP_RETURN_247 = 0xf7,
    OP_RETURN_248 = 0xf8,
    OP_RETURN_249 = 0xf9,
    OP_RETURN_250 = 0xfa,
    OP_RETURN_251 = 0xfb,
    OP_RETURN_252 = 0xfc,
    OP_RETURN_253 = 0xfd,
    OP_RETURN_254 = 0xfe,
    OP_RETURN_255 = 0xff,

    pub fn isPush(op: u8) bool {
        return op <= 0x4e or (op >= 0x51 and op <= 0x60);
    }

    pub fn isSmallInt(op: u8) ?u8 {
        if (op == 0) return 0;
        if (op >= 0x51 and op <= 0x60) return op - 0x50;
        return null;
    }

    pub fn name(op: u8) []const u8 {
        inline for (@typeInfo(Opcode).Enum.fields) |f| {
            if (f.value == op) return f.name;
        }
        return "OP_UNKNOWN";
    }
};

pub const ScriptError = error{
    StackUnderflow,
    StackOverflow,
    InvalidOpcode,
    InvalidPushData,
    DivisionByZero,
    NegativeShift,
    ScriptTooLong,
    OpCountExceeded,
    DisabledOpcode,
    VerifyFailed,
    EqualVerifyFailed,
    NumEqualVerifyFailed,
    ReturnExecuted,
    InvalidLength,
};

pub const MAX_SCRIPT_SIZE = 10_000;
pub const MAX_STACK_SIZE = 1000;
pub const MAX_OPS = 1024;

pub const Stack = struct {
    items: std.ArrayListUnmanaged([]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Stack {
        return .{ .items = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Stack) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *Stack, data: []const u8) !void {
        if (self.items.items.len >= MAX_STACK_SIZE) return ScriptError.StackOverflow;
        const owned = try self.allocator.dupe(u8, data);
        try self.items.append(self.allocator, owned);
    }

    pub fn pop(self: *Stack) ?[]u8 {
        const item = self.items.pop() orelse return null;
        return item;
    }

    pub fn popOrError(self: *Stack) ![]u8 {
        return self.pop() orelse ScriptError.StackUnderflow;
    }

    pub fn peek(self: *Stack) ?[]u8 {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1];
    }

    pub fn depth(self: *Stack) usize {
        return self.items.items.len;
    }

    pub fn clear(self: *Stack) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.clearRetainingCapacity();
    }
};

pub const ScriptNum = struct {
    pub fn encode(value: i64, allocator: std.mem.Allocator) ![]u8 {
        if (value == 0) return try allocator.dupe(u8, &.{0});
        const neg = value < 0;
        var abs_val: u64 = if (neg) @as(u64, @intCast(-value)) else @as(u64, @intCast(value));
        var bytes = std.ArrayList(u8).init(allocator);
        defer bytes.deinit();
        while (abs_val > 0) {
            try bytes.append(@truncate(abs_val));
            abs_val >>= 8;
        }
        if ((bytes.items[bytes.items.len - 1] & 0x80) != 0) {
            try bytes.append(if (neg) @as(u8, 0x80) else 0);
        } else if (neg) {
            bytes.items[bytes.items.len - 1] |= 0x80;
        }
        return bytes.toOwnedSlice();
    }

    pub fn decode(data: []const u8) i64 {
        if (data.len == 0) return 0;
        var neg = false;
        var val: u64 = 0;
        for (data, 0..) |b, i| {
            if (i == data.len - 1) {
                neg = (b & 0x80) != 0;
                val |= @as(u64, b & 0x7f) << @as(u6, @intCast(i * 8));
            } else {
                val |= @as(u64, b) << @as(u6, @intCast(i * 8));
            }
        }
        return if (neg) -@as(i64, @intCast(val)) else @as(i64, @intCast(val));
    }

    pub fn castBool(data: []const u8) bool {
        for (data) |b| if (b != 0) return true;
        return false;
    }
};

pub const Script = struct {
    bytes: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) Script {
        return .{ .bytes = bytes, .allocator = allocator };
    }

    pub fn deinit(self: *Script) void {
        self.allocator.free(self.bytes);
    }

    pub fn parse(self: *const Script) !ScriptParser {
        return ScriptParser.init(self.allocator, self.bytes);
    }
};

pub const ScriptParser = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    offset: usize,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) ScriptParser {
        return .{ .allocator = allocator, .bytes = bytes, .offset = 0 };
    }

    pub fn remaining(self: *const ScriptParser) usize {
        return self.bytes.len - self.offset;
    }

    pub fn next(self: *ScriptParser) !?Token {
        if (self.offset >= self.bytes.len) return null;
        const op = self.bytes[self.offset];
        self.offset += 1;

        if (op <= 0x4b) {
            const len = op;
            if (self.offset + len > self.bytes.len) return ScriptError.InvalidPushData;
            const data = self.bytes[self.offset .. self.offset + len];
            self.offset += len;
            return Token{ .op = op, .data = data, .kind = .push };
        }

        switch (op) {
            0x4c => { // OP_PUSHDATA1
                if (self.remaining() < 1) return ScriptError.InvalidPushData;
                const len = self.bytes[self.offset];
                self.offset += 1;
                if (self.offset + len > self.bytes.len) return ScriptError.InvalidPushData;
                const data = self.bytes[self.offset .. self.offset + len];
                self.offset += len;
                return Token{ .op = op, .data = data, .kind = .push };
            },
            0x4d => { // OP_PUSHDATA2
                if (self.remaining() < 2) return ScriptError.InvalidPushData;
                const len = std.mem.readInt(u16, self.bytes[self.offset..], .little);
                self.offset += 2;
                if (self.offset + len > self.bytes.len) return ScriptError.InvalidPushData;
                const data = self.bytes[self.offset .. self.offset + len];
                self.offset += len;
                return Token{ .op = op, .data = data, .kind = .push };
            },
            0x4e => { // OP_PUSHDATA4
                if (self.remaining() < 4) return ScriptError.InvalidPushData;
                const len = std.mem.readInt(u32, self.bytes[self.offset..], .little);
                self.offset += 4;
                if (self.offset + len > self.bytes.len) return ScriptError.InvalidPushData;
                const data = self.bytes[self.offset .. self.offset + len];
                self.offset += len;
                return Token{ .op = op, .data = data, .kind = .push };
            },
            0x4f => return Token{ .op = op, .kind = .op, .data = &.{} }, // OP_1NEGATE
            0x50 => {}, // reserved
            0x51...0x60 => {
                const val = op - 0x50;
                var buf: [1]u8 = undefined;
                buf[0] = val;
                const data = try self.allocator.dupe(u8, buf[0..]);
                return Token{ .op = op, .data = data, .kind = .push };
            },
            else => return Token{ .op = op, .kind = .op, .data = &.{} },
        }
    }
};

pub const Token = struct {
    op: u8,
    data: []const u8,
    kind: enum { op, push },
};

pub const VmResult = enum {
    success,
    failure,
    vm_error,
};

pub const Vm = struct {
    main_stack: Stack,
    alt_stack: Stack,
    allocator: std.mem.Allocator,
    op_count: usize,
    script: []const u8,
    alt_script: []const u8,

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{
            .main_stack = Stack.init(allocator),
            .alt_stack = Stack.init(allocator),
            .allocator = allocator,
            .op_count = 0,
            .script = &.{},
            .alt_script = &.{},
        };
    }

    pub fn deinit(self: *Vm) void {
        self.main_stack.deinit();
        self.alt_stack.deinit();
    }

    pub fn setScript(self: *Vm, script: []const u8) void {
        self.script = script;
    }

    pub fn setAltScript(self: *Vm, script: []const u8) void {
        self.alt_script = script;
    }

    pub fn verify(self: *Vm, unlocking: []const u8, locking: []const u8) !bool {
        self.clear();

        try self.run(unlocking);
        const result1 = try self.checkResult();
        if (!result1) return false;

        self.clear();

        try self.runAlt(locking);
        const result2 = try self.checkResult();
        if (!result2) return false;

        try self.runCombined();

        return self.checkResult();
    }

    fn clear(self: *Vm) void {
        self.main_stack.clear();
        self.alt_stack.clear();
        self.op_count = 0;
    }

    fn checkResult(self: *Vm) !bool {
        if (self.main_stack.depth() == 0) return false;
        const top = self.main_stack.peek().?;
        return ScriptNum.castBool(top);
    }

    fn run(self: *Vm, script: []const u8) !void {
        var parser = ScriptParser.init(self.allocator, script);
        while (try parser.next()) |token| {
            try self.executeOp(token);
        }
    }

    fn runAlt(self: *Vm, script: []const u8) !void {
        var parser = ScriptParser.init(self.allocator, script);
        while (try parser.next()) |token| {
            try self.executeOp(token);
        }
    }

    fn runCombined(self: *Vm) !void {
        _ = self;
    }

    pub fn executeOp(self: *Vm, token: Token) !void {
        self.op_count += 1;
        if (self.op_count > MAX_OPS) return ScriptError.OpCountExceeded;

        if (token.kind == .push) {
            try self.main_stack.push(token.data);
            return;
        }

        const op = token.op;
        switch (op) {
            0x00 => try self.main_stack.push(&.{}), // OP_0
            0x4f => { // OP_1NEGATE
                var buf: [1]u8 = undefined;
                buf[0] = 0x81;
                try self.main_stack.push(&buf);
            },
            0x61 => {}, // OP_NOP
            0x63 => {}, // OP_IF (simplified)
            0x64 => {}, // OP_NOTIF (simplified)
            0x67 => {}, // OP_ELSE (simplified)
            0x68 => {}, // OP_ENDIF (simplified)
            0x69 => { // OP_VERIFY
                const top = try self.main_stack.popOrError();
                if (!ScriptNum.castBool(top)) return ScriptError.VerifyFailed;
                self.allocator.free(top);
            },
            0x6a => return ScriptError.ReturnExecuted, // OP_RETURN
            0x6b => { // OP_TOALTSTACK
                const item = try self.main_stack.popOrError();
                try self.alt_stack.push(item);
                self.allocator.free(item);
            },
            0x6c => { // OP_FROMALTSTACK
                const item = try self.alt_stack.popOrError();
                try self.main_stack.push(item);
                self.allocator.free(item);
            },
            0x6d => { // OP_2DROP
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                self.allocator.free(a);
                self.allocator.free(b);
            },
            0x6e => { // OP_2DUP
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                try self.main_stack.push(b);
                try self.main_stack.push(a);
                try self.main_stack.push(b);
                try self.main_stack.push(a);
                self.allocator.free(a);
                self.allocator.free(b);
            },
            0x75 => { // OP_DROP
                const a = try self.main_stack.popOrError();
                self.allocator.free(a);
            },
            0x76 => { // OP_DUP
                const a = try self.main_stack.popOrError();
                try self.main_stack.push(a);
                try self.main_stack.push(a);
                self.allocator.free(a);
            },
            0x77 => { // OP_NIP
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                try self.main_stack.push(a);
                self.allocator.free(b);
            },
            0x78 => { // OP_OVER
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                try self.main_stack.push(b);
                try self.main_stack.push(a);
                try self.main_stack.push(b);
                self.allocator.free(a);
                self.allocator.free(b);
            },
            0x7a => { // OP_ROLL
                const n_data = try self.main_stack.popOrError();
                const n = ScriptNum.decode(n_data);
                self.allocator.free(n_data);
                if (n < 0 or @as(usize, @intCast(n)) >= self.main_stack.depth()) return ScriptError.InvalidLength;
                const idx = self.main_stack.depth() - 1 - @as(usize, @intCast(n));
                const item = self.main_stack.items.orderedRemove(idx);
                try self.main_stack.push(item);
                self.allocator.free(item);
            },
            0x7b => { // OP_ROT
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                const c = try self.main_stack.popOrError();
                try self.main_stack.push(b);
                try self.main_stack.push(a);
                try self.main_stack.push(c);
                self.allocator.free(a);
                self.allocator.free(b);
                self.allocator.free(c);
            },
            0x7c => { // OP_SWAP
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                try self.main_stack.push(a);
                try self.main_stack.push(b);
                self.allocator.free(a);
                self.allocator.free(b);
            },
            0x7e => { // OP_CAT
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                const concat = try std.mem.concat(self.allocator, u8, &.{b, a});
                try self.main_stack.push(concat);
                self.allocator.free(a);
                self.allocator.free(b);
            },
            0x7f => { // OP_SPLIT
                const n_data = try self.main_stack.popOrError();
                const n = ScriptNum.decode(n_data);
                self.allocator.free(n_data);
                const data = try self.main_stack.popOrError();
                if (n < 0 or @as(usize, @intCast(n)) > data.len) return ScriptError.InvalidLength;
                const left = try self.allocator.dupe(u8, data[0..@as(usize, @intCast(n))]);
                const right = try self.allocator.dupe(u8, data[@as(usize, @intCast(n))..]);
                try self.main_stack.push(right);
                try self.main_stack.push(left);
                self.allocator.free(data);
            },
            0x82 => { // OP_SIZE
                const a = self.main_stack.peek().?;
                const buf = try ScriptNum.encode(@intCast(a.len), self.allocator);
                try self.main_stack.push(buf);
                self.allocator.free(buf);
            },
            0x84 => { // OP_AND
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                if (a.len != b.len) return ScriptError.InvalidLength;
                const result = try self.allocator.alloc(u8, a.len);
                for (result, a, b) |*r, x, y| r.* = x & y;
                try self.main_stack.push(result);
                self.allocator.free(a);
                self.allocator.free(b);
            },
            0x85 => { // OP_OR
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                if (a.len != b.len) return ScriptError.InvalidLength;
                const result = try self.allocator.alloc(u8, a.len);
                for (result, a, b) |*r, x, y| r.* = x | y;
                try self.main_stack.push(result);
                self.allocator.free(a);
                self.allocator.free(b);
            },
            0x86 => { // OP_XOR
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                if (a.len != b.len) return ScriptError.InvalidLength;
                const result = try self.allocator.alloc(u8, a.len);
                for (result, a, b) |*r, x, y| r.* = x ^ y;
                try self.main_stack.push(result);
                self.allocator.free(a);
                self.allocator.free(b);
            },
            0x87 => { // OP_EQUAL
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                const eq = std.mem.eql(u8, a, b);
                self.allocator.free(a);
                self.allocator.free(b);
                const val = if (eq) &[_]u8{1} else &[_]u8{0};
                try self.main_stack.push(val);
            },
            0x88 => { // OP_EQUALVERIFY
                const a = try self.main_stack.popOrError();
                const b = try self.main_stack.popOrError();
                const eq = std.mem.eql(u8, a, b);
                self.allocator.free(a);
                self.allocator.free(b);
                if (!eq) return ScriptError.EqualVerifyFailed;
            },
            0x8b => { // OP_1ADD
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const buf = try ScriptNum.encode(a + 1, self.allocator);
                try self.main_stack.push(buf);
                self.allocator.free(buf);
            },
            0x8c => { // OP_1SUB
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const buf = try ScriptNum.encode(a - 1, self.allocator);
                try self.main_stack.push(buf);
                self.allocator.free(buf);
            },
            0x93 => { // OP_ADD
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                const buf = try ScriptNum.encode(a + b, self.allocator);
                try self.main_stack.push(buf);
                self.allocator.free(buf);
            },
            0x94 => { // OP_SUB
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                const buf = try ScriptNum.encode(a - b, self.allocator);
                try self.main_stack.push(buf);
                self.allocator.free(buf);
            },
            0x95 => { // OP_MUL
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                const buf = try ScriptNum.encode(a * b, self.allocator);
                try self.main_stack.push(buf);
                self.allocator.free(buf);
            },
            0x96 => { // OP_DIV
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                if (b == 0) return ScriptError.DivisionByZero;
                const buf = try ScriptNum.encode(@divTrunc(a, b), self.allocator);
                try self.main_stack.push(buf);
                self.allocator.free(buf);
            },
            0x97 => { // OP_MOD
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                if (b == 0) return ScriptError.DivisionByZero;
                const buf = try ScriptNum.encode(@rem(a, b), self.allocator);
                try self.main_stack.push(buf);
                self.allocator.free(buf);
            },
            0x9a => { // OP_BOOLAND
                const a = ScriptNum.castBool(try self.main_stack.popOrError());
                const b = ScriptNum.castBool(try self.main_stack.popOrError());
                const val = if (a and b) &[_]u8{1} else &[_]u8{0};
                try self.main_stack.push(val);
            },
            0x9b => { // OP_BOOLOR
                const a = ScriptNum.castBool(try self.main_stack.popOrError());
                const b = ScriptNum.castBool(try self.main_stack.popOrError());
                const val = if (a or b) &[_]u8{1} else &[_]u8{0};
                try self.main_stack.push(val);
            },
            0x9c => { // OP_NUMEQUAL
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                const val = if (a == b) &[_]u8{1} else &[_]u8{0};
                try self.main_stack.push(val);
            },
            0x9d => { // OP_NUMEQUALVERIFY
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                if (a != b) return ScriptError.NumEqualVerifyFailed;
            },
            0x9e => { // OP_NUMNOTEQUAL
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                const val = if (a != b) &[_]u8{1} else &[_]u8{0};
                try self.main_stack.push(val);
            },
            0x9f => { // OP_LESSTHAN
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                const val = if (a < b) &[_]u8{1} else &[_]u8{0};
                try self.main_stack.push(val);
            },
            0xa0 => { // OP_GREATERTHAN
                const a = ScriptNum.decode(try self.main_stack.popOrError());
                const b = ScriptNum.decode(try self.main_stack.popOrError());
                const val = if (a > b) &[_]u8{1} else &[_]u8{0};
                try self.main_stack.push(val);
            },
            0xa6 => { // OP_RIPEMD160
                const data = try self.main_stack.popOrError();
                var ctx = Ripemd160.init(.{});
                ctx.update(data);
                const h = ctx.final();
                self.allocator.free(data);
                try self.main_stack.push(&h);
            },
            0xa8 => { // OP_SHA256
                const data = try self.main_stack.popOrError();
                var ctx = Sha256.init(.{});
                ctx.update(data);
                const h = ctx.final();
                self.allocator.free(data);
                try self.main_stack.push(&h);
            },
            0xa9 => { // OP_HASH160
                const data = try self.main_stack.popOrError();
                const h = hash160(data);
                self.allocator.free(data);
                try self.main_stack.push(&h);
            },
            0xaa => { // OP_HASH256
                const data = try self.main_stack.popOrError();
                const h = doubleSha256(data);
                self.allocator.free(data);
                try self.main_stack.push(&h);
            },
            0xac => { // OP_CHECKSIG
                const pubkey = try self.main_stack.popOrError();
                defer self.allocator.free(pubkey);
                const sig = try self.main_stack.popOrError();
                defer self.allocator.free(sig);
                if (pubkey.len == 33 and sig.len >= 64) {
                    const msg_hash = hash.sha256(pubkey);
                    const valid = secp.verify(msg_hash, sig[0..32].*, sig[32..64].*, pubkey[0..33].*);
                    try self.main_stack.push(if (valid) &[_]u8{1} else &[_]u8{0});
                } else {
                    try self.main_stack.push(&[_]u8{0});
                }
            },
            0xad => { // OP_CHECKSIGVERIFY
                const pubkey = try self.main_stack.popOrError();
                defer self.allocator.free(pubkey);
                const sig = try self.main_stack.popOrError();
                defer self.allocator.free(sig);
                if (pubkey.len == 33 and sig.len >= 64) {
                    const msg_hash = hash.sha256(pubkey);
                    const valid = secp.verify(msg_hash, sig[0..32].*, sig[32..64].*, pubkey[0..33].*);
                    if (!valid) return ScriptError.EqualVerifyFailed;
                } else {
                    return ScriptError.EqualVerifyFailed;
                }
            },
            0xba => { // OP_CHECKDATASIG
                const pubkey = try self.main_stack.popOrError();
                defer self.allocator.free(pubkey);
                const msg = try self.main_stack.popOrError();
                defer self.allocator.free(msg);
                const sig = try self.main_stack.popOrError();
                defer self.allocator.free(sig);
                if (pubkey.len == 33 and sig.len >= 64) {
                    const msg_hash = hash.sha256(msg);
                    const valid = secp.verify(msg_hash, sig[0..32].*, sig[32..64].*, pubkey[0..33].*);
                    try self.main_stack.push(if (valid) &[_]u8{1} else &[_]u8{0});
                } else {
                    try self.main_stack.push(&[_]u8{0});
                }
            },
            0xbb => { // OP_CHECKDATASIGVERIFY
                const pubkey = try self.main_stack.popOrError();
                defer self.allocator.free(pubkey);
                const msg = try self.main_stack.popOrError();
                defer self.allocator.free(msg);
                const sig = try self.main_stack.popOrError();
                defer self.allocator.free(sig);
                if (pubkey.len == 33 and sig.len >= 64) {
                    const msg_hash = hash.sha256(msg);
                    const valid = secp.verify(msg_hash, sig[0..32].*, sig[32..64].*, pubkey[0..33].*);
                    if (!valid) return ScriptError.EqualVerifyFailed;
                } else {
                    return ScriptError.EqualVerifyFailed;
                }
            },
            else => {
                if (op >= 0xb0 and op <= 0xb9) {} // OP_NOP1-10
            },
        }
    }
};

fn doubleSha256(input: []const u8) [32]u8 {
    var state = Sha256.init(.{});
    state.update(input);
    const h1 = state.final();
    var state2 = Sha256.init(.{});
    state2.update(&h1);
    return state2.final();
}

fn hash160(input: []const u8) [20]u8 {
    var state = Sha256.init(.{});
    state.update(input);
    const sha = state.final();
    var rip = Ripemd160.init(.{});
    rip.update(&sha);
    return rip.final();
}

test "script num encode decode" {
    try std.testing.expectEqual(@as(i64, 0), ScriptNum.decode(&.{}));
    try std.testing.expectEqual(@as(i64, 1), ScriptNum.decode(&.{1}));
    try std.testing.expectEqual(@as(i64, -1), ScriptNum.decode(&.{0x81}));
}

test "stack operations" {
    const allocator = std.testing.allocator;
    var stack = Stack.init(allocator);
    defer stack.deinit();

    try stack.push(&.{0x01});
    try stack.push(&.{0x02});
    try std.testing.expectEqual(2, stack.depth());

    const a = stack.pop().?;
    try std.testing.expectEqual(@as(u8, 0x02), a[0]);
    allocator.free(a);
}

test "vm dup" {
    const allocator = std.testing.allocator;
    var vm = Vm.init(allocator);
    defer vm.deinit();

    try vm.executeOp(.{ .op = 0x51, .kind = .push, .data = &.{1} }); // OP_1
    try vm.executeOp(.{ .op = 0x76, .kind = .op, .data = &.{} }); // OP_DUP
    try std.testing.expectEqual(2, vm.main_stack.depth());
}

test "vm add" {
    const allocator = std.testing.allocator;
    var vm = Vm.init(allocator);
    defer vm.deinit();

    try vm.executeOp(.{ .op = 0x52, .kind = .push, .data = &.{2} }); // OP_2
    try vm.executeOp(.{ .op = 0x53, .kind = .push, .data = &.{3} }); // OP_3
    try vm.executeOp(.{ .op = 0x93, .kind = .op, .data = &.{} }); // OP_ADD

    const result = vm.main_stack.pop().?;
    defer allocator.free(result);
    try std.testing.expectEqual(20, result.len);
}

test "vm checkdatasig" {
    const allocator = std.testing.allocator;
    var vm = Vm.init(allocator);
    defer vm.deinit();

    const priv: [32]u8 = [_]u8{0x01} ** 32;
    const pubkey = secp.pubkeyCreate(priv);
    const msg = "hello" ** 8;
    const msg_hash = hash.sha256(msg);
    const sig = secp.sign(msg_hash, priv);

    var sig_bytes: [64]u8 = undefined;
    @memcpy(sig_bytes[0..32], &sig.r);
    @memcpy(sig_bytes[32..64], &sig.s);

    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = &sig_bytes });
    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = msg });
    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = &pubkey });
    try vm.executeOp(.{ .op = 0xba, .kind = .op, .data = &.{} }); // OP_CHECKDATASIG

    const result = vm.main_stack.pop().?;
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 1), result[0]);
}

test "vm checkdatasig verify fails" {
    const allocator = std.testing.allocator;
    var vm = Vm.init(allocator);
    defer vm.deinit();

    const priv: [32]u8 = [_]u8{0x01} ** 32;
    const pubkey = secp.pubkeyCreate(priv);
    const msg = "good message";
    const wrong_msg = "bad message";
    const msg_hash = hash.sha256(msg);
    const sig = secp.sign(msg_hash, priv);

    var sig_bytes: [64]u8 = undefined;
    @memcpy(sig_bytes[0..32], &sig.r);
    @memcpy(sig_bytes[32..64], &sig.s);

    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = &sig_bytes });
    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = wrong_msg });
    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = &pubkey });
    try vm.executeOp(.{ .op = 0xba, .kind = .op, .data = &.{} }); // OP_CHECKDATASIG

    const result = vm.main_stack.pop().?;
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 0), result[0]);
}

test "vm checksig" {
    const allocator = std.testing.allocator;
    var vm = Vm.init(allocator);
    defer vm.deinit();

    const priv: [32]u8 = [_]u8{0x01} ** 32;
    const pubkey = secp.pubkeyCreate(priv);
    const msg_hash = hash.sha256(&pubkey);
    const sig = secp.sign(msg_hash, priv);

    var sig_bytes: [65]u8 = undefined;
    @memcpy(sig_bytes[0..32], &sig.r);
    @memcpy(sig_bytes[32..64], &sig.s);
    sig_bytes[64] = 0x01; // SIGHASH_ALL

    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = &sig_bytes });
    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = &pubkey });
    try vm.executeOp(.{ .op = 0xac, .kind = .op, .data = &.{} }); // OP_CHECKSIG

    const result = vm.main_stack.pop().?;
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 1), result[0]);
}

test "vm hash160" {
    const allocator = std.testing.allocator;
    var vm = Vm.init(allocator);
    defer vm.deinit();

    try vm.executeOp(.{ .op = 0x51, .kind = .push, .data = &.{1} }); // OP_1
    try vm.executeOp(.{ .op = 0xa9, .kind = .op, .data = &.{} }); // OP_HASH160

    const result = vm.main_stack.pop().?;
    defer allocator.free(result);
    try std.testing.expectEqual(20, result.len);
}

test "vm equal" {
    const allocator = std.testing.allocator;
    var vm = Vm.init(allocator);
    defer vm.deinit();

    try vm.executeOp(.{ .op = 0x51, .kind = .push, .data = &.{0x01} });
    try vm.executeOp(.{ .op = 0x51, .kind = .push, .data = &.{0x01} });
    try vm.executeOp(.{ .op = 0x87, .kind = .op, .data = &.{} }); // OP_EQUAL

    const result = vm.main_stack.pop().?;
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 1), result[0]);
}

test "ripemd160 via script vm" {
    const allocator = std.testing.allocator;
    var vm = Vm.init(allocator);
    defer vm.deinit();

    try vm.executeOp(.{ .op = 0x00, .kind = .push, .data = "abc" }); // push "abc"
    try vm.executeOp(.{ .op = 0xa6, .kind = .op, .data = &.{} }); // OP_RIPEMD160

    const result = vm.main_stack.pop().?;
    defer allocator.free(result);
    try std.testing.expectEqual(20, result.len);
}
