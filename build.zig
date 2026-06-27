const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .freestanding },
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kernel = b.addExecutable(.{
        .name = "ulises",
        .root_module = kernel_mod,
    });

    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .freestanding) {
        kernel_mod.addAssemblyFile(b.path("src/arch/x86_64/pci_config_read.S"));
    }

    kernel.entry = .disabled;

    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .freestanding) {
        kernel.setLinkerScript(b.path("src/arch/x86_64/link.ld"));
        kernel_mod.code_model = .kernel;
    }

    const install_kernel = b.addInstallArtifact(kernel, .{});
    const kernel_path = b.getInstallPath(.bin, "ulises");
    b.default_step.dependOn(&install_kernel.step);
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .freestanding) {
        std.debug.print("DEBUG: kernel_path={s}\n", .{kernel_path});
    }

    const test_lib = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run all tests");
    const run_test = b.addRunArtifact(test_lib);
    test_step.dependOn(&run_test.step);

    const bench = b.addExecutable(.{
        .name = "utxo-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utxo/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const bench_step = b.step("bench", "Run UTXO stack benchmarks");
    const run_bench = b.addRunArtifact(bench);
    bench_step.dependOn(&run_bench.step);

    const iso_step = b.step("iso", "Create bootable ISO with grub-mkrescue");

    const mkdir_boot = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/boot/grub" });
    mkdir_boot.step.dependOn(&install_kernel.step);

    const grub_cfg_write = b.addSystemCommand(&.{ "/bin/sh", "-c", "printf '%s\\n' 'set gfxpayload=text' 'multiboot2 /bin/ulises' 'boot' > zig-out/boot/grub/grub.cfg" });
    grub_cfg_write.step.dependOn(&mkdir_boot.step);

    const iso_cmd = b.addSystemCommand(&.{
        "grub-mkrescue", "-o", "/tmp/ulises.iso", "zig-out",
    });
    const iso_copy = b.addSystemCommand(&.{
        "cp", "/tmp/ulises.iso", "zig-out/ulises.iso",
    });
    iso_cmd.step.dependOn(&grub_cfg_write.step);
    iso_copy.step.dependOn(&iso_cmd.step);
    iso_step.dependOn(&iso_copy.step);

    const run_step = b.step("run", "Boot kernel in QEMU");
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-serial",
        "file:console.log",
        "-m",
        "512M",
        "-cdrom",
        "/tmp/ulises.iso",
        "-no-reboot",
        "-no-shutdown",
        "-d",
        "int",
        "-display",
        "none",
    });
    qemu_cmd.step.dependOn(&iso_cmd.step);
    run_step.dependOn(&qemu_cmd.step);

    const run_direct_step = b.step("run-direct", "Boot kernel ELF directly in QEMU");
    const qemu_direct = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-serial",
        "file:console.log",
        "-m",
        "512M",
        "-kernel",
        kernel_path,
        "-no-reboot",
        "-no-shutdown",
    });
    qemu_direct.step.dependOn(&install_kernel.step);
    run_direct_step.dependOn(&qemu_direct.step);

    const debug_step = b.step("debug", "Boot in QEMU with GDB stub (port 1234)");
    const qemu_debug = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-serial",
        "file:console.log",
        "-m",
        "512M",
        "-kernel",
        kernel_path,
        "-no-reboot",
        "-no-shutdown",
        "-s",
        "-S",
    });
    qemu_debug.step.dependOn(&install_kernel.step);
    debug_step.dependOn(&qemu_debug.step);
}
