const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .freestanding },
    });

    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    // Compile kernel.zig to a standalone object
    const kernel_obj = b.addObject(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (arch == .x86_64 and os == .freestanding) {
        kernel_obj.root_module.red_zone = false;
    }

    // Compile asm files to a standalone object
    const asm_obj = b.addObject(.{
        .name = "asm",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        }),
    });

    if (arch == .x86_64 and os == .freestanding) {
        asm_obj.root_module.addAssemblyFile(b.path("src/arch/x86_64/pci_config_read.S"));
        asm_obj.root_module.addAssemblyFile(b.path("src/arch/x86_64/boot32.S"));

        // Generate ISR stubs for x86_64
        var stubs_buf: [50000]u8 = undefined;
        var pos: usize = 0;
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const has_err = switch (i) {
                8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
                else => false,
            };
            const suffix = if (has_err) "_err" else "";
            const line1 = b.fmt(".globl isrStub{d}{s}\n", .{ i, suffix });
            const line2 = b.fmt("isrStub{d}{s}:\n", .{ i, suffix });
            const line3 = if (!has_err) "pushq $0\n" else "";
            const line4 = b.fmt("pushq ${d}\n", .{i});
            const line5 = "jmp isrCommon\n";
            for (&[_][]const u8{ line1, line2, line3, line4, line5 }) |part| {
                @memcpy(stubs_buf[pos..][0..part.len], part);
                pos += part.len;
            }
        }
        const wf = b.addWriteFiles();
        const stubs_lazy = wf.add("isr_stubs.S", stubs_buf[0..pos]);
        asm_obj.root_module.addAssemblyFile(stubs_lazy);
    }

    if (arch == .aarch64 and os == .freestanding) {
        asm_obj.root_module.addAssemblyFile(b.path("src/arch/aarch64/boot.S"));
    }

    // Link all objects into the final kernel executable
    const kernel = b.addExecutable(.{
        .name = "ulises",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        }),
    });

    kernel.entry = .default;
    kernel.root_module.addObjectFile(kernel_obj.getEmittedBin());
    kernel.root_module.addObjectFile(asm_obj.getEmittedBin());

    if (arch == .x86_64 and os == .freestanding) {
        kernel.setLinkerScript(b.path("src/arch/x86_64/link.ld"));
    }
    if (arch == .aarch64 and os == .freestanding) {
        kernel.setLinkerScript(b.path("src/arch/aarch64/link.ld"));
        kernel.root_module.red_zone = false;
    }

    const install_kernel = b.addInstallArtifact(kernel, .{});
    const kernel_lp = kernel.getEmittedBin();
    b.default_step.dependOn(&install_kernel.step);

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

    // Architecture-specific run steps
    if (arch == .x86_64 and os == .freestanding) {
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
            "-serial", "file:console.log",
            "-m", "512M",
            "-cdrom", "/tmp/ulises.iso",
            "-no-reboot", "-no-shutdown",
            "-d", "int",
            "-display", "none",
        });
        qemu_cmd.step.dependOn(&iso_cmd.step);
        run_step.dependOn(&qemu_cmd.step);

        const run_direct_step = b.step("run-direct", "Boot kernel ELF directly in QEMU");
        const qemu_direct = b.addSystemCommand(&.{
            "qemu-system-x86_64",
            "-serial", "file:console.log",
            "-m", "512M",
            "-no-reboot", "-no-shutdown",
            "-kernel",
        });
        qemu_direct.addFileArg(kernel_lp);
        qemu_direct.step.dependOn(&install_kernel.step);
        run_direct_step.dependOn(&qemu_direct.step);

        const debug_step = b.step("debug", "Boot in QEMU with GDB stub (port 1234)");
        const qemu_debug = b.addSystemCommand(&.{
            "qemu-system-x86_64",
            "-serial", "file:console.log",
            "-m", "512M",
            "-no-reboot", "-no-shutdown",
            "-s", "-S",
            "-kernel",
        });
        qemu_debug.addFileArg(kernel_lp);
        qemu_debug.step.dependOn(&install_kernel.step);
        debug_step.dependOn(&qemu_debug.step);
    }

    if (arch == .aarch64 and os == .freestanding) {
        const run_step = b.step("run", "Boot kernel in QEMU aarch64");
        const qemu_cmd = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-machine", "virt",
            "-cpu", "cortex-a57",
            "-serial", "file:console.log",
            "-m", "512M",
            "-no-reboot", "-no-shutdown",
            "-display", "none",
            "-kernel",
        });
        qemu_cmd.addFileArg(kernel_lp);
        qemu_cmd.step.dependOn(&install_kernel.step);
        run_step.dependOn(&qemu_cmd.step);

        const debug_step = b.step("debug", "Boot in QEMU with GDB stub (port 1234)");
        const qemu_debug = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-machine", "virt",
            "-cpu", "cortex-a57",
            "-serial", "file:console.log",
            "-m", "512M",
            "-no-reboot", "-no-shutdown",
            "-display", "none",
            "-s", "-S",
            "-kernel",
        });
        qemu_debug.addFileArg(kernel_lp);
        qemu_debug.step.dependOn(&install_kernel.step);
        debug_step.dependOn(&qemu_debug.step);
    }
}
