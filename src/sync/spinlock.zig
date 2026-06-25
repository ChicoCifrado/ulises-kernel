const std = @import("std");
const builtin = @import("builtin");
const x86_64 = @import("../arch/x86_64.zig");

pub const SpinLock = struct {
    ticket: u32 = 0,
    serving: u32 = 0,

    pub fn lock(self: *SpinLock) void {
        const t = @atomicRmw(u32, &self.ticket, .Add, 1, .acq_rel);
        while (true) {
            const s = @atomicLoad(u32, &self.serving, .acquire);
            if (s == t) break;
            if (builtin.target.cpu.arch == .x86_64) {
                asm volatile ("pause");
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        _ = @atomicRmw(u32, &self.serving, .Add, 1, .release);
    }

    pub fn tryLock(self: *SpinLock) bool {
        const t = @atomicLoad(u32, &self.ticket, .acquire);
        const s = @atomicLoad(u32, &self.serving, .acquire);
        if (t != s) return false;
        const next = @atomicRmw(u32, &self.ticket, .Add, 1, .acq_rel);
        if (next != s) {
            _ = @atomicRmw(u32, &self.ticket, .Sub, 1, .release);
            return false;
        }
        return true;
    }

    pub fn isLocked(self: *const SpinLock) bool {
        const t = @atomicLoad(u32, &self.ticket, .acquire);
        const s = @atomicLoad(u32, &self.serving, .acquire);
        return t != s;
    }
};

pub const IrqSpinLock = struct {
    inner: SpinLock = .{},
    flags: u64 = 0,

    pub fn lock(self: *IrqSpinLock) void {
        if (builtin.target.cpu.arch == .x86_64) {
            var f: u64 = undefined;
            asm volatile ("pushfq; popq %[f]; cli"
                : [f] "={rax}" (f)
            );
            self.flags = f;
        }
        self.inner.lock();
    }

    pub fn unlock(self: *IrqSpinLock) void {
        self.inner.unlock();
        if (builtin.target.cpu.arch == .x86_64 and self.flags & 0x200 != 0) {
            x86_64.sti();
        }
    }
};

pub const Atomic = struct {
    pub inline fn store(ptr: *u32, val: u32) void {
        @atomicStore(u32, ptr, val, .release);
    }

    pub inline fn load(ptr: *const u32) u32 {
        return @atomicLoad(u32, ptr, .acquire);
    }

    pub inline fn exchange(ptr: *u32, val: u32) u32 {
        return @atomicRmw(u32, ptr, .Xchg, val, .acq_rel);
    }

    pub inline fn fetchAdd(ptr: *u32, val: u32) u32 {
        return @atomicRmw(u32, ptr, .Add, val, .acq_rel);
    }

    pub inline fn fetchSub(ptr: *u32, val: u32) u32 {
        return @atomicRmw(u32, ptr, .Sub, val, .acq_rel);
    }

    pub inline fn cmpxchg(ptr: *u32, expected: u32, new: u32) ?u32 {
        return @cmpxchgWeak(u32, ptr, expected, new, .acq_rel, .acquire);
    }

    pub inline fn store64(ptr: *u64, val: u64) void {
        @atomicStore(u64, ptr, val, .release);
    }

    pub inline fn load64(ptr: *const u64) u64 {
        return @atomicLoad(u64, ptr, .acquire);
    }

    pub inline fn exchange64(ptr: *u64, val: u64) u64 {
        return @atomicRmw(u64, ptr, .Xchg, val, .acq_rel);
    }
};

comptime {
    if (@sizeOf(SpinLock) != 8) @compileError("SpinLock must be 8 bytes");
    if (@sizeOf(IrqSpinLock) != 24) @compileError("IrqSpinLock must be 24 bytes (no padding)");
}

test "spinlock basic lock unlock" {
    var lock = SpinLock{};
    lock.lock();
    try std.testing.expect(lock.isLocked());
    lock.unlock();
    try std.testing.expect(!lock.isLocked());
}

test "spinlock try lock" {
    var lock = SpinLock{};
    try std.testing.expect(lock.tryLock());
    lock.unlock();
    try std.testing.expect(!lock.isLocked());
}

test "atomic store load" {
    var val: u32 = 0;
    Atomic.store(&val, 42);
    try std.testing.expectEqual(@as(u32, 42), Atomic.load(&val));
}

test "atomic exchange" {
    var val: u32 = 10;
    const old = Atomic.exchange(&val, 20);
    try std.testing.expectEqual(@as(u32, 10), old);
    try std.testing.expectEqual(@as(u32, 20), Atomic.load(&val));
}

test "atomic fetch add" {
    var val: u32 = 5;
    const old = Atomic.fetchAdd(&val, 3);
    try std.testing.expectEqual(@as(u32, 5), old);
    try std.testing.expectEqual(@as(u32, 8), Atomic.load(&val));
}

test "atomic cmpxchg success" {
    var val: u32 = 10;
    const result = Atomic.cmpxchg(&val, 10, 20);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 20), Atomic.load(&val));
}

test "atomic cmpxchg failure" {
    var val: u32 = 10;
    const result = Atomic.cmpxchg(&val, 99, 20);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 10), Atomic.load(&val));
}
