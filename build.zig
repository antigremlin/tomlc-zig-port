const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "tomlc",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = mod,
    });
    lib_unit_tests.linkLibC();
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const check_step = b.step("check", "Build library and decoder");
    check_step.dependOn(&lib.step);

    const decoder = b.addExecutable(.{
        .name = "toml-test-decoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tools/toml_test_decoder.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    decoder.root_module.addImport("toml", mod);
    decoder.linkLibC();
    b.installArtifact(decoder);
    check_step.dependOn(&decoder.step);

    const toml_test_run = b.addRunArtifact(decoder);
    if (b.args) |args| toml_test_run.addArgs(args);
    const toml_test_step = b.step("toml-test", "Run the toml-test decoder executable");
    toml_test_step.dependOn(&toml_test_run.step);
}
