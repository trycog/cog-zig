const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const scip_main = @import("scip/main.zig");
const scip_types = @import("scip/scip.zig");
const protobruh = @import("scip/protobruh.zig");

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
    const index_start_ms = std.time.milliTimestamp();

    // Parse args: --output <output_path> <file_path> [file_path ...]
    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print("Usage: cog-zig --output <output_path> <file_path> [file_path ...]\n", .{});
        process.exit(1);
    }

    var output_path: ?[]const u8 = null;
    var file_paths = std.ArrayListUnmanaged([]const u8){};
    defer file_paths.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else {
            try file_paths.append(allocator, args[i]);
        }
    }

    if (output_path == null or file_paths.items.len == 0) {
        std.debug.print("Error: --output <path> and at least one file path are required\n", .{});
        process.exit(1);
    }

    debugLog("index:start files={d}", .{file_paths.items.len});
    logResourceUsage("index:start");

    var collected_documents = std.ArrayListUnmanaged(scip_types.Document){};
    defer collected_documents.deinit(allocator);
    var collected_external_symbols = std.ArrayListUnmanaged(scip_types.SymbolInformation){};
    defer collected_external_symbols.deinit(allocator);

    var metadata_root: ?[]const u8 = null;

    for (file_paths.items) |input_path| {
        const file_start_ms = std.time.milliTimestamp();
        debugLog("file:start path={s}", .{input_path});
        logResourceUsage("file:start");
        const single_result = indexSingleFile(allocator, input_path, args) catch |err| {
            emitProgress("file_error", input_path);
            debugLog("file:error path={s} err={s} elapsed_ms={d}", .{ input_path, @errorName(err), std.time.milliTimestamp() - file_start_ms });
            logResourceUsage("file:error");
            if (std.posix.getenv("COG_ZIG_DEBUG") != null) {
                std.debug.print("debug: failed to index {s}: {s}\n", .{ input_path, @errorName(err) });
            }
            continue;
        };

        if (metadata_root == null) {
            metadata_root = try allocator.dupe(u8, single_result.index.metadata.project_root);
        }

        for (single_result.index.documents.items) |doc| {
            try collected_documents.append(allocator, doc);
        }
        for (single_result.index.external_symbols.items) |sym| {
            try collected_external_symbols.append(allocator, sym);
        }

        emitProgress("file_done", single_result.relative_path);
        debugLog("file:done path={s} elapsed_ms={d} docs={d} external_symbols={d}", .{ single_result.relative_path, std.time.milliTimestamp() - file_start_ms, single_result.index.documents.items.len, single_result.index.external_symbols.items.len });
        logResourceUsage("file:done");
    }

    const project_root = metadata_root orelse blk: {
        const cwd = try fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        break :blk try std.fmt.allocPrint(allocator, "file://{s}", .{cwd});
    };
    defer allocator.free(project_root);

    const out_file = try fs.cwd().createFile(output_path.?, .{});
    defer out_file.close();

    var write_buf: [4096]u8 = undefined;
    var file_writer = out_file.writer(&write_buf);

    try protobruh.encode(scip_types.Index{
        .metadata = .{
            .version = .unspecified_protocol_version,
            .tool_info = .{
                .name = "cog-zig",
                .version = "unversioned",
                .arguments = .{},
            },
            .project_root = project_root,
            .text_document_encoding = .utf8,
        },
        .documents = collected_documents,
        .external_symbols = collected_external_symbols,
    }, &file_writer.interface);

    try file_writer.interface.flush();
    debugLog("index:done files={d} elapsed_ms={d}", .{ file_paths.items.len, std.time.milliTimestamp() - index_start_ms });
    logResourceUsage("index:done");
}

const SingleIndexResult = struct {
    index: scip_types.Index,
    relative_path: []const u8,
};

fn indexSingleFile(allocator: mem.Allocator, input_path: []const u8, full_args: []const []const u8) !SingleIndexResult {
    const input_kind = pathKind(input_path);
    if (input_kind != .file) return error.InvalidInput;
    const file_start_ms = std.time.milliTimestamp();

    const abs_input_file = try fs.cwd().realpathAlloc(allocator, input_path);
    defer allocator.free(abs_input_file);

    const file_dir = fs.path.dirname(abs_input_file) orelse return error.InvalidInput;
    const workspace_root = try findWorkspaceRoot(allocator, file_dir);
    defer allocator.free(workspace_root);

    const file_relative_path = try fs.path.relative(allocator, workspace_root, abs_input_file);
    debugLog("indexSingleFile:start path={s} abs={s}", .{ file_relative_path, abs_input_file });
    logResourceUsage("indexSingleFile:start");

    const pkg_name = discoverPackageName(allocator, workspace_root) catch |err| blk: {
        if (std.posix.getenv("COG_ZIG_DEBUG") != null) {
            std.debug.print("debug: could not read build.zig.zon ({s}), using directory name fallback\n", .{@errorName(err)});
        }
        break :blk dirBasename(workspace_root);
    };
    defer if (pkg_name.allocated) allocator.free(pkg_name.name);

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const packages = [_]scip_main.PackageSpec{
        .{ .name = pkg_name.name, .path = abs_input_file },
    };

    const scip_run_start_ms = std.time.milliTimestamp();
    try scip_main.run(.{
        .root_path = workspace_root,
        .root_pkg = pkg_name.name,
        .packages = &packages,
        .tool_name = "cog-zig",
        .tool_arguments = full_args,
        .single_document_relative_path = file_relative_path,
    }, allocator, &out.writer);
    debugLog("indexSingleFile:scip_run_done path={s} elapsed_ms={d} bytes={d}", .{ file_relative_path, std.time.milliTimestamp() - scip_run_start_ms, out.written().len });
    logResourceUsage("indexSingleFile:scip_run_done");

    var fbs = std.io.fixedBufferStream(out.written());
    const decode_start_ms = std.time.milliTimestamp();
    const index = try protobruh.decode(scip_types.Index, allocator, fbs.reader());
    debugLog("indexSingleFile:decode_done path={s} elapsed_ms={d} total_elapsed_ms={d}", .{ file_relative_path, std.time.milliTimestamp() - decode_start_ms, std.time.milliTimestamp() - file_start_ms });
    logResourceUsage("indexSingleFile:decode_done");
    return .{ .index = index, .relative_path = file_relative_path };
}

fn debugEnabled() bool {
    return std.posix.getenv("COG_ZIG_DEBUG") != null;
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    std.log.debug(fmt, args);
}

fn logResourceUsage(context: []const u8) void {
    if (!debugEnabled()) return;
    const usage = resourceUsage() orelse return;
    std.log.debug(
        "{s} rss_kb={d} user_ms={d} sys_ms={d} minflt={d} majflt={d} nvcsw={d} nivcsw={d}",
        .{ context, usage.max_rss_kb, usage.user_ms, usage.system_ms, usage.minor_faults, usage.major_faults, usage.vol_cs, usage.invol_cs },
    );
}

const ResourceUsage = struct {
    user_ms: i64,
    system_ms: i64,
    max_rss_kb: i64,
    minor_faults: i64,
    major_faults: i64,
    vol_cs: i64,
    invol_cs: i64,
};

fn resourceUsage() ?ResourceUsage {
    if (@TypeOf(std.c.rusage) == void) return null;

    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return null;

    return .{
        .user_ms = @as(i64, @intCast(usage.utime.sec)) * 1000 + @divTrunc(@as(i64, @intCast(usage.utime.usec)), 1000),
        .system_ms = @as(i64, @intCast(usage.stime.sec)) * 1000 + @divTrunc(@as(i64, @intCast(usage.stime.usec)), 1000),
        .max_rss_kb = @as(i64, @intCast(usage.maxrss)),
        .minor_faults = @as(i64, @intCast(usage.minflt)),
        .major_faults = @as(i64, @intCast(usage.majflt)),
        .vol_cs = @as(i64, @intCast(usage.nvcsw)),
        .invol_cs = @as(i64, @intCast(usage.nivcsw)),
    };
}

fn emitProgress(event: []const u8, path: []const u8) void {
    var escaped_buf: [4096]u8 = undefined;
    const escaped = escapeJson(&escaped_buf, path);
    std.debug.print("{{\"type\":\"progress\",\"event\":\"{s}\",\"path\":\"{s}\"}}\n", .{ event, escaped });
}

fn escapeJson(buf: []u8, input: []const u8) []const u8 {
    var out_idx: usize = 0;
    for (input) |c| {
        switch (c) {
            '\\', '"' => {
                if (out_idx + 2 > buf.len) break;
                buf[out_idx] = '\\';
                buf[out_idx + 1] = c;
                out_idx += 2;
            },
            '\n' => {
                if (out_idx + 2 > buf.len) break;
                buf[out_idx] = '\\';
                buf[out_idx + 1] = 'n';
                out_idx += 2;
            },
            '\r' => {
                if (out_idx + 2 > buf.len) break;
                buf[out_idx] = '\\';
                buf[out_idx + 1] = 'r';
                out_idx += 2;
            },
            '\t' => {
                if (out_idx + 2 > buf.len) break;
                buf[out_idx] = '\\';
                buf[out_idx + 1] = 't';
                out_idx += 2;
            },
            else => {
                if (out_idx + 1 > buf.len) break;
                buf[out_idx] = c;
                out_idx += 1;
            },
        }
    }
    return buf[0..out_idx];
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

const PathKind = enum {
    file,
    directory,
    missing,
};

fn pathKind(path: []const u8) PathKind {
    const stat = fs.cwd().statFile(path) catch return .missing;
    return switch (stat.kind) {
        .directory => .directory,
        else => .file,
    };
}

fn findWorkspaceRoot(allocator: mem.Allocator, start_dir: []const u8) ![]const u8 {
    var current = try allocator.dupe(u8, start_dir);
    errdefer allocator.free(current);

    while (true) {
        const zon_path = try fs.path.join(allocator, &.{ current, "build.zig.zon" });
        defer allocator.free(zon_path);
        if (pathKind(zon_path) == .file) {
            return current;
        }

        const maybe_parent = fs.path.dirname(current);
        if (maybe_parent == null or std.mem.eql(u8, maybe_parent.?, current)) {
            return current;
        }

        const parent = try allocator.dupe(u8, maybe_parent.?);
        allocator.free(current);
        current = parent;
    }
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

test "findWorkspaceRoot walks to build.zig.zon" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("workspace/src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "workspace/build.zig.zon", .data = ".{ .name = .workspace, .version = \"0.0.0\" }\n" });

    const abs_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs_root);
    const nested = try fs.path.join(std.testing.allocator, &.{ abs_root, "workspace", "src", "nested" });
    defer std.testing.allocator.free(nested);

    const discovered = try findWorkspaceRoot(std.testing.allocator, nested);
    defer std.testing.allocator.free(discovered);

    try std.testing.expect(std.mem.endsWith(u8, discovered, "workspace"));
}

test "pathKind distinguishes file and directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("a_dir");
    try tmp.dir.writeFile(.{ .sub_path = "a_file.zig", .data = "pub fn main() void {}\n" });

    const abs_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs_root);
    const abs_dir = try fs.path.join(std.testing.allocator, &.{ abs_root, "a_dir" });
    defer std.testing.allocator.free(abs_dir);
    const abs_file = try fs.path.join(std.testing.allocator, &.{ abs_root, "a_file.zig" });
    defer std.testing.allocator.free(abs_file);

    try std.testing.expectEqual(PathKind.directory, pathKind(abs_dir));
    try std.testing.expectEqual(PathKind.file, pathKind(abs_file));
    try std.testing.expectEqual(PathKind.missing, pathKind("/this/path/should/not/exist-12345"));
}
