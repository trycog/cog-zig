const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build vendored scip-zig indexer from source in this repo.
    const scip = b.addExecutable(.{
        .name = "scip-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scip/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(scip);

    // Build the wrapper binary (cog invokes this as "cog-zig")
    const wrapper = b.addExecutable(.{
        .name = "cog-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(wrapper);

    const wrapper_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const scip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scip/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run wrapper and vendored scip-zig tests");
    test_step.dependOn(&b.addRunArtifact(wrapper_tests).step);
    test_step.dependOn(&b.addRunArtifact(scip_tests).step);
}
