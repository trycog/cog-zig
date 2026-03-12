const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Extension version") orelse readExtensionVersion(b);

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "cog-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_tests.root_module.addOptions("build_options", options);

    const scip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scip/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(scip_tests).step);
}

fn readExtensionVersion(b: *std.Build) []const u8 {
    const metadata_path = b.pathFromRoot("cog-extension.json");
    const metadata = std.fs.cwd().readFileAlloc(b.allocator, metadata_path, 64 * 1024) catch @panic("failed to read cog-extension.json");
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, metadata, .{}) catch @panic("failed to parse cog-extension.json");
    if (parsed.value != .object) @panic("invalid cog-extension.json");
    const version_value = parsed.value.object.get("version") orelse @panic("missing version in cog-extension.json");
    if (version_value != .string) @panic("invalid version in cog-extension.json");
    return version_value.string;
}
