const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal.zig");
const utxo_stack = @import("utxo/stack.zig");
const utxo_slot = @import("utxo/slot.zig");
const pmm = @import("mem/pmm.zig");
const primitives = @import("bsv/primitives.zig");
const bsv_hash = @import("bsv/hash.zig");
const scheduler = @import("agent/scheduler.zig");
const bkds = @import("bsv/bkds.zig");
const brc43 = @import("bsv/brc43.zig");
const brc100 = @import("bsv/brc100.zig");
const basm = @import("bsv/basm.zig");
const overlay = @import("bsv/overlay.zig");
const secp256k1 = @import("bsv/secp256k1.zig");
const beef = @import("bsv/beef.zig");
const x402 = @import("bsv/x402.zig");
const console_mod = @import("hal/console.zig");
const usb = @import("hal/usb.zig");
const pci = @import("hal/pci.zig");
const e1000 = @import("net/e1000.zig");
const net_stack = @import("net/stack.zig");
const shell = @import("shell/shell.zig");
const smp = if (builtin.target.cpu.arch == .x86_64) @import("arch/smp.zig") else struct {
    pub fn initSmp(_: anytype) void {}
    pub fn startAps() void {}
};
const spinlock = @import("sync/spinlock.zig");
const global_alloc = @import("mem/global.zig");
const gfx_compositor = @import("gfx/compositor.zig");
const gfx_font = @import("gfx/font.zig");
const gfx_fb_mod = @import("gfx/fb.zig");
const gfx_assets = @import("gfx/assets.zig");
const gfx_rebrand = @import("gfx/rebrand.zig");
const fs_memfs = @import("fs/memfs.zig");
const fs_vfs = @import("fs/vfs.zig");
const fs_ext4 = @import("fs/ext4.zig");
const fs_ata = @import("fs/ata.zig");
const fs_gpt = @import("fs/gpt.zig");
const fs_blockdev = @import("fs/blockdev.zig");

var page_mem: [1024 * 4096]u8 align(4096) = undefined;
var nic: e1000.E1000 = undefined;
var g_stack: net_stack.Stack = undefined;
var g_net_available: bool = false;
var g_compositor: gfx_compositor.Compositor = undefined;
var g_fb_available: bool = false;
var g_memfs: fs_memfs.MemFs = undefined;
var g_ext4_instance: ?fs_ext4.Ext4Fs = null;
var g_fs: fs_vfs.Fs = undefined;

comptime {
    if (builtin.target.os.tag == .freestanding and !builtin.is_test) {
        switch (builtin.target.cpu.arch) {
            .x86_64 => { _ = @import("arch/x86_64/boot.zig"); },
            .aarch64, .arm => { _ = @import("arch/aarch64/boot.zig"); },
            else => {},
        }
    }
}

pub const std_options: std.Options = .{
    .log_level = .info,
    .page_size_max = 4096,
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (builtin.target.os.tag == .freestanding and !builtin.is_test) {
        const logger = @import("hal/logger.zig");
        const tag = @tagName(scope);
        const alloc = global_alloc.get();
        const prefix = std.fmt.allocPrint(alloc, "[{s}] [{s}] ", .{ @tagName(level), tag }) catch return;
        defer alloc.free(prefix);
        logger.write(prefix);
        const buf = std.fmt.allocPrint(alloc, format, args) catch return;
        defer alloc.free(buf);
        logger.write(buf);
        logger.write("\n");
    }
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (builtin.target.os.tag == .freestanding and !builtin.is_test) {
        const logger = @import("hal/logger.zig");
        logger.panicLog(msg);
        if (ret_addr) |ra| {
            logger.writeFmt(" @ 0x{x}\n", .{ra});
        }
    }
    var h = hal.Hal.init();
    h.halt(.panic);
}

pub export fn kmain() noreturn {
    return kmainReal();
}

pub export fn kmainReal() noreturn {
    initLogger();
    var h = hal.Hal.init();
    initPlatform();
    var page_allocator = pmm.PageAllocator.init(&page_mem, page_mem.len, 4096);
    if (builtin.target.cpu.arch == .x86_64) {
        smp.initSmp(&page_allocator);
    }
    initInterrupts();

    if (builtin.target.os.tag == .freestanding) {
        global_alloc.init(&page_allocator, 1024 * 1024) catch {
            if (builtin.target.cpu.arch == .x86_64) {
                const log = @import("hal/logger.zig");
                log.errorLog("global_alloc.init failed");
            }
            h.halt(.panic);
        };
    }

    gfxTryInit();
    gfxBootSplash(0.08);

    // Init in-memory filesystem
    {
        const alloc = global_alloc.get();
        g_memfs = fs_memfs.MemFs.init(alloc);
        g_fs = g_memfs.fs();
        g_fs.current_uid = 0;
        g_fs.current_gid = 0;
        // Seed a few files
        var f = g_fs.open("/version", .{ .write = true, .create = true, .truncate = true });
        if (f) |*file| {
            const data = "Ulises Kernel v1.0.0";
            const to_copy = @min(data.len, file.data.len - file.pos);
            @memcpy(file.data[file.pos..][0..to_copy], data[0..to_copy]);
            file.pos += to_copy;
            if (file.pos > file.size) file.size = file.pos;
            g_fs.close(file);
        }
        var f2 = g_fs.open("/network", .{ .write = true, .create = true, .truncate = true });
        if (f2) |*file| {
            const data = "mainnet";
            const to_copy = @min(data.len, file.data.len - file.pos);
            @memcpy(file.data[file.pos..][0..to_copy], data[0..to_copy]);
            file.pos += to_copy;
            if (file.pos > file.size) file.size = file.pos;
            g_fs.close(file);
        }
    }

    dbgWr('b');
    initBootDevices(&page_allocator);

    if (builtin.target.cpu.arch == .x86_64) {
        if (fs_ata.AtaBlockDev.detect(0x1F0, 0x3F6, false)) |ata_val| {
            var ata = ata_val;
            var bdev = ata.blockDev();
            var gpt_entries: [128]fs_gpt.GptPartitionEntry = undefined;
            if (fs_gpt.GptDisk.init(&bdev, &gpt_entries)) |*gpt| {
                for (0..gpt.entries.len) |i| {
                    const part = &gpt.entries[i];
                    if (part.first_lba == 0) continue;
                    var part_dev = fs_blockdev.SubBlockDev.init(&bdev, part.first_lba);
                    var subdev = part_dev.blockDev();
                    if (fs_ext4.Ext4Fs.init(&subdev, global_alloc.get())) |ext4| {
                        g_ext4_instance = ext4;
                        g_fs = g_ext4_instance.?.fs();
                        break;
                    }
                }
            }
        }
    }

    gfxBootSplash(0.30);

    smp.startAps();
    gfxBootSplash(0.45);

    const UTXO_SLOTS = 1000;
    const SCRIPT_HEAP_SIZE = 64 * 1024;

    var utxo = initUtxoStack(UTXO_SLOTS, SCRIPT_HEAP_SIZE) catch {
        if (builtin.target.cpu.arch == .x86_64) {
            const log = @import("hal/logger.zig");
            log.errorLog("initUtxoStack failed");
        }
        h.halt(.panic);
    };
    gfxBootSplash(0.65);

    const kernel_alloc = global_alloc.get();
    var wallet_engine = brc100.KernelWallet.init(kernel_alloc, &utxo);
    wallet_engine.setNetwork(.mainnet);
    gfxBootSplash(0.80);

    _ = initAgent(&h, &wallet_engine);
    gfxBootSplash(0.95);

    gfxBootFinal();

    var ctx = shell.ShellContext{};
    if (g_net_available) ctx.net_stack = &g_stack;
    ctx.fs = &g_fs;
    var con = console_mod.Console.init();
    con.clear();
    shell.run(&ctx, &con, &wallet_engine);

    h.halt(.shutdown);
}

const dbgWr = if (builtin.target.cpu.arch == .x86_64) struct {
    fn f(val: u8) void {
        const port: u16 = 0xE9;
        asm volatile ("outb %[val], %[port]"
            :
            : [val] "{al}" (val),
              [port] "{dx}" (port),
        );
    }
}.f else struct {
    fn f(_: u8) void {}
}.f;

fn initLogger() void {
    if (builtin.target.os.tag == .freestanding and !builtin.is_test) {
        const logger = @import("hal/logger.zig");
        logger.init();
        logger.write("[KERNEL] Ulises booting\n");
    }
}

fn initPlatform() void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const x86_64 = @import("arch/x86_64.zig");
            x86_64.initCpu();
        },
        .aarch64, .arm => {
            const arch = @import("arch/aarch64.zig");
            arch.initCpu();
        },
        .riscv64 => {},
        else => {},
    }
}

fn initInterrupts() void {
    if (builtin.target.os.tag == .freestanding and !builtin.is_test) {
        switch (builtin.target.cpu.arch) {
            .x86_64 => {
                const idt_mod = @import("arch/x86_64/idt.zig");
                const timer_mod = @import("arch/x86_64/timer.zig");
                const sched = @import("sched/scheduler.zig");
                const exc = @import("arch/x86_64/exceptions.zig");
                const x86_64 = @import("arch/x86_64.zig");
                const Handler = struct {
                    fn callback(frame: *const idt_mod.InterruptFrame) callconv(std.lang.CallingConvention.c) u64 {
                        const vec = frame.vector;
                        if (vec < 32) {
                            return exc.handler(frame);
                        }
                        if (vec == 0x20) {
                            return sched.onTimerTick(frame);
                        }
                        return @intFromPtr(frame);
                    }
                };
                idt_mod.init(Handler.callback);
                sched.init();
                x86_64.sti();
                timer_mod.init(Handler.callback);
            },
            .aarch64, .arm => {
                const arch = @import("arch/aarch64.zig");
                const sched = @import("sched/scheduler.zig");
                arch.gicInit();
                // Enable timer PPI (INTID 30 on QEMU virt)
                arch.gicEnableIrq(30);
                // Enable timer at 100 Hz
                arch.timerInit(100);
                sched.init();
                // Enable IRQs
                arch.sti();
            },
            else => {},
        }
    }
}

fn initBootDevices(page_allocator: *pmm.PageAllocator) void {
    if (builtin.target.cpu.arch == .x86_64) {
        const x86_64 = @import("arch/x86_64.zig");
        pci.mapMmioBars(page_allocator);
        usb.init();

        const allocator = global_alloc.get();
        const pci_devs = pci.enumerate(allocator) catch {
            return;
        };
        defer allocator.free(pci_devs);

        for (pci_devs) |dev| {
            if (dev.class_code == 0x02 and dev.subclass == 0x00) {
                dbgWr('E');
                const mmio_phys: u64 = if (dev.bar0_is_64bit)
                    (dev.bar0 & 0xFFFFFFF0) | (@as(u64, dev.bar0_upper) << 32)
                else
                    dev.bar0 & 0xFFFFFFF0;
                x86_64.invlpg(@intCast(mmio_phys));
                const mmio_base: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(mmio_phys)));
                nic = e1000.E1000.init(allocator, mmio_base) catch {
                    logError("e1000 init failed");
                    continue;
                };
                dbgWr('e');
                g_stack = net_stack.Stack.init(&nic, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
                g_stack.dhcp.start();
                g_net_available = true;
                break;
            }
        }
    }
}

fn initUtxoStack(num_slots: usize, script_heap_size: usize) !utxo_stack.UtxoStack {
    const allocator = global_alloc.get();
    return try utxo_stack.UtxoStack.init(allocator, num_slots, script_heap_size);
}

fn gfxBootSplash(progress: f64) void {
    if (!g_fb_available) return;
    if (builtin.target.cpu.arch != .x86_64) return;
    if (builtin.target.os.tag != .freestanding) return;
    if (g_compositor.fb.width == 0) return;
    const bar_w = @min(g_compositor.fb.width / 2, 400);
    const bar_h: u32 = 6;
    const bar_x = (g_compositor.fb.width - bar_w) / 2;
    const bar_y = g_compositor.fb.height - 40;
    if (bar_y >= g_compositor.fb.height) return;
    g_compositor.drawProgressBar(bar_x, bar_y, bar_w, bar_h, @as(f32, @floatCast(progress)), gfx_rebrand.config.progress_color, gfx_rebrand.config.progress_bg);
}

fn gfxBootFinal() void {
    if (!g_fb_available) return;
    if (builtin.target.cpu.arch != .x86_64) return;
    if (builtin.target.os.tag != .freestanding) return;
    if (g_compositor.fb.width == 0 or g_compositor.fb.height == 0) return;
    const fb_slice = g_compositor.fb.asSlice() orelse return;
    const font_data = g_compositor.font orelse return;
    const w = g_compositor.fb.width;
    const h = g_compositor.fb.height;
    const bpp = g_compositor.fb.bpp;
    const title_y: i32 = @intCast(h / 2 - 24);
    const subtitle_y: i32 = title_y + 28;
    font_data.drawText(fb_slice, w, h, bpp, 20, title_y, gfx_rebrand.config.title, gfx_rebrand.config.text_color, 0x00000000);
    font_data.drawText(fb_slice, w, h, bpp, 20, subtitle_y, gfx_rebrand.config.subtitle, gfx_rebrand.config.accent_color, 0x00000000);

    // Mark progress 100%
    gfxBootSplash(1.0);
}

fn gfxTryInit() void {
    if (builtin.target.cpu.arch != .x86_64) return;
    if (builtin.target.os.tag != .freestanding) return;
    const boot_info = @import("arch/x86_64/boot.zig");
    const boot_fb = boot_info.getFramebufferInfo() orelse return;
    if (boot_fb.addr == 0) return;
    const fb_info = gfx_fb_mod.FramebufferInfo{
        .addr = boot_fb.addr,
        .pitch = boot_fb.pitch,
        .width = boot_fb.width,
        .height = boot_fb.height,
        .bpp = boot_fb.bpp,
        .type = boot_fb.type,
    };
    const font_ptr = gfx_font.Psf2Font.init(gfx_assets.font_psf) orelse return;
    g_compositor = gfx_compositor.Compositor.init(fb_info);
    g_compositor.setFont(font_ptr);
    g_compositor.blitWallpaper(gfx_assets.wallpaper_ppm);
    g_fb_available = true;
}

fn logError(msg: []const u8) void {
    if (builtin.target.os.tag == .freestanding and !builtin.is_test) {
        const log = @import("hal/logger.zig");
        log.errorLog(msg);
    }
}

fn initAgent(h: *hal.Hal, wallet_engine: *brc100.KernelWallet) scheduler.AgentScheduler {
    const allocator = global_alloc.get();

    var sched = scheduler.AgentScheduler.init(allocator, @as(*anyopaque, @ptrCast(wallet_engine)), @as(*const anyopaque, @ptrCast(h)));

    sched.registerTool(allocator, "balance", .{
        .name = "balance",
        .handler = struct {
            fn f(ctx: *anyopaque, args: []const u8) []const u8 {
                _ = args;
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                const bal = kw.getBasketBalance(null) catch return "error";
                const result = std.fmt.allocPrint(kw.allocator, "{}", .{bal.satoshis}) catch return "error";
                return result;
            }
        }.f,
    }) catch logError("registerTool balance failed");

    sched.registerTool(allocator, "scan", .{
        .name = "scan",
        .handler = struct {
            fn f(_: *anyopaque, _: []const u8) []const u8 {
                return "ok";
            }
        }.f,
    }) catch logError("registerTool scan failed");

    sched.registerTool(allocator, "version", .{
        .name = "version",
        .handler = struct {
            fn f(ctx: *anyopaque, _: []const u8) []const u8 {
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                const ver = kw.getVersion();
                const result = std.fmt.allocPrint(kw.allocator, "{}.{}.{}", .{ ver.major, ver.minor, ver.revision }) catch return "0.0.0";
                return result;
            }
        }.f,
    }) catch logError("registerTool version failed");

    sched.registerTool(allocator, "network", .{
        .name = "network",
        .handler = struct {
            fn f(ctx: *anyopaque, _: []const u8) []const u8 {
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                return switch (kw.network) {
                    .mainnet => "mainnet",
                    .testnet => "testnet",
                    .regtest => "regtest",
                };
            }
        }.f,
    }) catch logError("registerTool network failed");

    sched.registerTool(allocator, "height", .{
        .name = "height",
        .handler = struct {
            fn f(ctx: *anyopaque, _: []const u8) []const u8 {
                const kw: *brc100.KernelWallet = @ptrCast(@alignCast(ctx));
                const result = std.fmt.allocPrint(kw.allocator, "{}", .{kw.getHeight()}) catch return "0";
                return result;
            }
        }.f,
    }) catch logError("registerTool height failed");

    return sched;
}

comptime {
    std.debug.assert(@sizeOf(utxo_slot.Slot) == 64);
    std.debug.assert(@sizeOf(primitives.OutPoint) == 36);
}

test "kernel integrity" {
    try std.testing.expectEqual(64, @sizeOf(utxo_slot.Slot));
    try std.testing.expectEqual(36, @sizeOf(primitives.OutPoint));
}

test "crypto works" {
    const hash = bsv_hash.doubleSha256("ulises");
    try std.testing.expectEqual(32, hash.len);
}
