const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Parse args: <project_root> --output <output_path>
    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print("Usage: scip-zig <project_root> --output <output_path>\n", .{});
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
        std.debug.print("Warning: could not read build.zig.zon ({s}), falling back to directory name\n", .{@errorName(err)});
        break :blk dirBasename(project_root);
    };
    defer if (pkg_name.allocated) allocator.free(pkg_name.name);

    // Discover root source file (absolute path)
    const root_source = discoverRootSource(allocator, project_root) orelse {
        std.debug.print("Error: could not find root source file in {s}\n", .{project_root});
        process.exit(1);
    };
    defer allocator.free(root_source);

    // Locate scip-zig-core next to this executable
    const core_path = try findCoreBinary(allocator);
    defer allocator.free(core_path);

    // Create a temp directory for scip-zig-core to write index.scip into
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Spawn scip-zig-core
    var child = process.Child.init(
        &.{ core_path, "--root-path", project_root, "--pkg", pkg_name.name, root_source, "--root-pkg", pkg_name.name },
        allocator,
    );
    child.cwd = tmp_path;
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    _ = try child.spawnAndWait();

    // Copy index.scip from temp dir to output path
    const index_file = tmp_dir.dir.openFile("index.scip", .{}) catch |err| {
        std.debug.print("Error: scip-zig-core did not produce index.scip: {s}\n", .{@errorName(err)});
        process.exit(1);
    };
    defer index_file.close();

    const out_file = try fs.cwd().createFile(output_path.?, .{});
    defer out_file.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try index_file.read(&buf);
        if (n == 0) break;
        try out_file.writeAll(buf[0..n]);
    }
}

const PackageName = struct {
    name: []const u8,
    allocated: bool,
};

fn discoverPackageName(allocator: mem.Allocator, project_root: []const u8) !PackageName {
    const zon_path = try fs.path.join(allocator, &.{ project_root, "build.zig.zon" });
    defer allocator.free(zon_path);

    const content = try fs.cwd().readFileAlloc(allocator, zon_path, 1024 * 1024);
    defer allocator.free(content);

    // Look for .name = .identifier or .name = "string"
    if (parseDotName(content)) |name| {
        return .{ .name = name, .allocated = false };
    }

    if (parseStringName(allocator, content)) |name| {
        return .{ .name = name, .allocated = true };
    }

    return error.NameNotFound;
}

/// Parse `.name = .identifier` form (Zig 0.14+ style)
fn parseDotName(content: []const u8) ?[]const u8 {
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
fn parseStringName(allocator: mem.Allocator, content: []const u8) ?[]const u8 {
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

fn dirBasename(path: []const u8) PackageName {
    const basename = fs.path.basename(path);
    return .{ .name = basename, .allocated = false };
}

fn discoverRootSource(allocator: mem.Allocator, project_root: []const u8) ?[]const u8 {
    const candidates = [_][]const u8{
        "src/main.zig",
        "src/root.zig",
        "src/lib.zig",
        "build.zig",
    };
    for (candidates) |candidate| {
        const dir = fs.cwd().openDir(project_root, .{}) catch continue;
        dir.access(candidate, .{}) catch continue;
        return fs.path.join(allocator, &.{ project_root, candidate }) catch continue;
    }
    return null;
}

fn findCoreBinary(allocator: mem.Allocator) ![]const u8 {
    const self_path = try fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const dir = fs.path.dirname(self_path) orelse ".";
    return try fs.path.join(allocator, &.{ dir, "scip-zig" });
}
