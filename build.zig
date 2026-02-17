const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // Get the actual scip-zig indexer from the dependency
    const scip_dep = b.dependency("scip_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const core_artifact = scip_dep.artifact("scip-zig");
    const install_core = b.addInstallArtifact(core_artifact, .{});
    b.getInstallStep().dependOn(&install_core.step);
}
