const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const secp256k1 = b.dependency("secp256k1", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "bsvindexer",
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    lib.addIncludePath("src");
    lib.addPackage(secp256k1.module("secp256k1"));
    lib.addPackagePath("bsv_indexer", "src/main.zig");
    lib.linkLibC();
    lib.setTarget(target);

    const headers = b.addInstallHeaders(.{});
    headers.addFile("include/bsv_indexer.h", .{ .source_file = b.path("src/ffi.h") });
    b.installArtifact(lib);
    b.installHeaders(headers, .{ .prefix = "include" });

    const test_step = b.addTest(.{
        .target = target,
        .optimize = optimize,
    });
    test_step.addPackage(lib.getPackage());
    test_step.addPackage(secp256k1.module("secp256k1"));
    b.addStep("test", .{ .description = "Run tests" }, test_step);

    const bench = b.addExecutable(.{
        .name = "bsvindexer-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench.addPackage(lib.getPackage());
    bench.addPackage(secp256k1.module("secp256k1"));
    bench.linkLibC();
    b.addStep("bench", .{ .description = "Run benchmarks" }, bench);

    const exe = b.addExecutable(.{
        .name = "bsvindexer",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addPackage(lib.getPackage());
    exe.addPackage(secp256k1.module("secp256k1"));
    exe.linkLibC();
    b.installArtifact(exe);
}