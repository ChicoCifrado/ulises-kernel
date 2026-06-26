const std = @import("std");
const builtin = @import("builtin");
const idt_mod = @import("../arch/x86_64/idt.zig");

pub const TaskState = enum(u8) {
    dead = 0,
    ready = 1,
    running = 2,
};

pub const Task = struct {
    rsp: u64,
    state: TaskState,
};

const MAX_TASKS = 16;
const TICK_QUANTUM = 5;
const FLD_COUNT = 19;

var tasks: [MAX_TASKS]Task = undefined;
var task_count: u32 = 0;
var current_task: u32 = 0;
var tick_counter: u64 = 0;

pub fn init() void {
    for (&tasks) |*t| t.* = .{ .rsp = 0, .state = .dead };
    task_count = 0;
    current_task = 0;
    tick_counter = 0;
}

pub fn createTask(entry: *const fn () void, stack: []u8) ?u32 {
    if (task_count >= MAX_TASKS) return null;
    const id = task_count;
    task_count += 1;
    const sp = setupStack(stack, entry);
    tasks[id] = .{ .rsp = sp, .state = .ready };
    return id;
}

fn setupStack(stack: []u8, entry: *const fn () void) u64 {
    const end = @intFromPtr(stack.ptr) + stack.len;
    var sp = end;

    const entry_addr = @intFromPtr(entry);
    sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0x202;
    sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0x08;
    sp -= 8; @as(*u64, @ptrFromInt(sp)).* = entry_addr;
    sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0;
    for (0..14) |_| { sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0; }

    return sp;
}

pub fn onTimerTick(frame: *const idt_mod.InterruptFrame) u64 {
    const tmr = @import("../arch/x86_64/timer.zig");
    tmr.eoi();
    tick_counter += 1;
    if (tick_counter % TICK_QUANTUM != 0) return @intFromPtr(frame);
    if (task_count <= 1) return @intFromPtr(frame);

    tasks[current_task].rsp = @intFromPtr(frame);
    current_task = (current_task + 1) % task_count;
    return tasks[current_task].rsp;
}
