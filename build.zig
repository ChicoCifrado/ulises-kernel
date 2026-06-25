const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // --- Kernel executable ---

    const kernel = b.addExecutable(.{
        .name = "odysseus",
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });

    kernel.entry = .disabled;

    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .freestanding) {
        kernel.setLinkerScript(b.path("src/arch/x86_64/link.ld"));
        kernel.root_module.code_model = .kernel;
    }

    b.installArtifact(kernel);

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
}
