const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const scip = @import("scip/main.zig");

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (std.posix.getenv("COG_ZIG_DEBUG") == null) return;
    std.log.defaultLog(level, scope, format, args);
}

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = logFn,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Parse args: <project_root> --output <output_path>
    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print("Usage: cog-zig <project_root> --output <output_path>\n", .{});
        process.exit(1);
    }

    const project_root = args[1];
    var output_path: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        }
    }

    if (output_path == null) {
        std.debug.print("Error: --output <path> is required\n", .{});
        process.exit(1);
    }

    // Discover package name from build.zig.zon
    const pkg_name = discoverPackageName(allocator, project_root) catch |err| blk: {
        if (std.posix.getenv("COG_ZIG_DEBUG") != null) {
            std.debug.print("debug: could not read build.zig.zon ({s}), using directory name fallback\n", .{@errorName(err)});
        }
        break :blk dirBasename(project_root);
    };
    defer if (pkg_name.allocated) allocator.free(pkg_name.name);

    // Discover root source file (absolute path)
    const root_source = discoverRootSource(allocator, project_root) orelse {
        std.debug.print("Error: could not find root source file in {s}\n", .{project_root});
        process.exit(1);
    };
    defer allocator.free(root_source);

    const out_file = try fs.cwd().createFile(output_path.?, .{});
    defer out_file.close();

    var write_buf: [4096]u8 = undefined;
    var file_writer = out_file.writer(&write_buf);

    const tool_args = [_][]const u8{
        "cog-zig",
        "--root-path",
        project_root,
        "--pkg",
        pkg_name.name,
        root_source,
        "--root-pkg",
        pkg_name.name,
    };
    const packages = [_]scip.PackageSpec{
        .{ .name = pkg_name.name, .path = root_source },
    };

    try scip.run(.{
        .root_path = project_root,
        .root_pkg = pkg_name.name,
        .packages = &packages,
        .tool_name = "cog-zig",
        .tool_arguments = &tool_args,
    }, allocator, &file_writer.interface);

    try file_writer.interface.flush();
}

const PackageName = struct {
    name: []const u8,
    allocated: bool,
};

pub fn discoverPackageName(allocator: mem.Allocator, project_root: []const u8) !PackageName {
    const zon_path = try fs.path.join(allocator, &.{ project_root, "build.zig.zon" });
    defer allocator.free(zon_path);

    const content = try fs.cwd().readFileAlloc(allocator, zon_path, 1024 * 1024);
    defer allocator.free(content);

    // Look for .name = .identifier or .name = "string"
    if (parseDotName(content)) |name| {
        return .{ .name = try allocator.dupe(u8, name), .allocated = true };
    }

    if (parseStringName(allocator, content)) |name| {
        return .{ .name = name, .allocated = true };
    }

    return error.NameNotFound;
}

/// Parse `.name = .identifier` form (Zig 0.14+ style)
pub fn parseDotName(content: []const u8) ?[]const u8 {
    const needle = ".name";
    var pos: usize = 0;
    while (pos < content.len) {
        if (mem.indexOfPos(u8, content, pos, needle)) |idx| {
            var i = idx + needle.len;
            // Skip whitespace
            while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '\n' or content[i] == '\r')) : (i += 1) {}
            // Expect '='
            if (i < content.len and content[i] == '=') {
                i += 1;
                // Skip whitespace
                while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '\n' or content[i] == '\r')) : (i += 1) {}
                // Expect '.' for enum-style identifier
                if (i < content.len and content[i] == '.') {
                    i += 1;
                    const start = i;
                    while (i < content.len and (std.ascii.isAlphanumeric(content[i]) or content[i] == '_')) : (i += 1) {}
                    if (i > start) {
                        return content[start..i];
                    }
                }
            }
            pos = idx + 1;
        } else break;
    }
    return null;
}

/// Parse `.name = "string"` form
pub fn parseStringName(allocator: mem.Allocator, content: []const u8) ?[]const u8 {
    const needle = ".name";
    var pos: usize = 0;
    while (pos < content.len) {
        if (mem.indexOfPos(u8, content, pos, needle)) |idx| {
            var i = idx + needle.len;
            while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '\n' or content[i] == '\r')) : (i += 1) {}
            if (i < content.len and content[i] == '=') {
                i += 1;
                while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '\n' or content[i] == '\r')) : (i += 1) {}
                if (i < content.len and content[i] == '"') {
                    i += 1;
                    const start = i;
                    while (i < content.len and content[i] != '"') : (i += 1) {}
                    if (i > start) {
                        // Replace hyphens with underscores for Zig identifier compatibility
                        const name = allocator.dupe(u8, content[start..i]) catch return null;
                        for (name) |*c| {
                            if (c.* == '-') c.* = '_';
                        }
                        return name;
                    }
                }
            }
            pos = idx + 1;
        } else break;
    }
    return null;
}

pub fn dirBasename(path: []const u8) PackageName {
    const basename = fs.path.basename(path);
    return .{ .name = basename, .allocated = false };
}

pub fn discoverRootSource(allocator: mem.Allocator, project_root: []const u8) ?[]const u8 {
    const candidates = [_][]const u8{
        "src/main.zig",
        "src/root.zig",
        "src/lib.zig",
        "build.zig",
    };
    var dir = fs.cwd().openDir(project_root, .{}) catch return null;
    defer dir.close();

    for (candidates) |candidate| {
        dir.access(candidate, .{}) catch continue;
        return fs.path.join(allocator, &.{ project_root, candidate }) catch continue;
    }
    return null;
}

test "parseDotName parses enum-style package name" {
    const input =
        \\ .{
        \\   .name = .cog_zig,
        \\ }
    ;
    const name = parseDotName(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("cog_zig", name);
}

test "parseStringName normalizes hyphenated package names" {
    const allocator = std.testing.allocator;
    const input =
        \\ .{
        \\   .name = "cog-zig",
        \\ }
    ;
    const name = parseStringName(allocator, input) orelse return error.TestUnexpectedResult;
    defer allocator.free(name);
    try std.testing.expectEqualStrings("cog_zig", name);
}

test "discoverRootSource prefers src/main.zig" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "build.zig", .data = "pub fn build(_: *anyopaque) void {}\n" });

    const abs_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs_root);

    const source = discoverRootSource(std.testing.allocator, abs_root) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.endsWith(u8, source, "src/main.zig"));
}
