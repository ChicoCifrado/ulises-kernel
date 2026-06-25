const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // --- Kernel executable ---

    const kernel = b.addExecutable(.{
        .name = "ulises",
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });

    kernel.entry = .disabled;

    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .freestanding) {
        kernel.setLinkerScript(b.path("src/arch/x86_64/link.ld"));
        kernel.root_module.code_model = .kernel;
    }

    const install_kernel = b.addInstallArtifact(kernel, .{});
    const kernel_path = b.getInstallPath(.bin, "ulises");

    // --- Tests ---

    const test_lib = b.addTest(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");
    const run_test = b.addRunArtifact(test_lib);
    test_step.dependOn(&run_test.step);

    // --- UTXO benchmark ---

    const bench = b.addExecutable(.{
        .name = "utxo-bench",
        .root_source_file = b.path("src/utxo/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    b.installArtifact(bench);
    const bench_step = b.step("bench", "Run UTXO stack benchmarks");
    const run_bench = b.addRunArtifact(bench);
    bench_step.dependOn(&run_bench.step);

    // --- ISO (bootable CD image) ---

    const iso_step = b.step("iso", "Create bootable ISO with grub-mkrescue");
    const iso_cmd = b.addSystemCommand(&.{
        "grub-mkrescue", "-o", "zig-out/ulises.iso", "zig-out",
    });
    iso_cmd.step.dependOn(&install_kernel.step);
    iso_step.dependOn(&iso_cmd.step);

    // --- QEMU run ---

    const run_step = b.step("run", "Boot kernel in QEMU");
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-serial", "file:console.log",
        "-m", "512M",
        "-cdrom", "zig-out/ulises.iso",
        "-no-reboot",
        "-no-shutdown",
        "-d", "int",
    });
    qemu_cmd.step.dependOn(&iso_cmd.step);
    run_step.dependOn(&qemu_cmd.step);

    // --- QEMU direct kernel boot (no ISO needed) ---

    const run_direct_step = b.step("run-direct", "Boot kernel ELF directly in QEMU");
    const qemu_direct = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-serial", "file:console.log",
        "-m", "512M",
        "-kernel", kernel_path,
        "-no-reboot",
        "-no-shutdown",
    });
    qemu_direct.step.dependOn(&install_kernel.step);
    run_direct_step.dependOn(&qemu_direct.step);

    // --- QEMU debug (wait for gdb) ---

    const debug_step = b.step("debug", "Boot in QEMU with GDB stub (port 1234)");
    const qemu_debug = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-serial", "file:console.log",
        "-m", "512M",
        "-kernel", kernel_path,
        "-no-reboot",
        "-no-shutdown",
        "-s", "-S",
    });
    qemu_debug.step.dependOn(&install_kernel.step);
    debug_step.dependOn(&qemu_debug.step);
}
