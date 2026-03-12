const std = @import("std");
const build_options = @import("build_options");
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
    var msg_buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch return;
    var escaped_msg_buf: [4096]u8 = undefined;
    const escaped_msg = escapeJson(&escaped_msg_buf, msg);
    std.debug.print(
        "{{\"type\":\"debug\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\"}}\n",
        .{ @tagName(level), @tagName(scope), escaped_msg },
    );
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

    var batch = try indexBatchFiles(allocator, file_paths.items, args);
    defer batch.deinit(allocator);

    const project_root = if (batch.metadata_root) |metadata_root|
        try allocator.dupe(u8, metadata_root)
    else blk: {
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
                .version = build_options.version,
                .arguments = .{},
            },
            .project_root = project_root,
            .text_document_encoding = .utf8,
        },
        .documents = batch.documents,
        .external_symbols = batch.external_symbols,
    }, &file_writer.interface);

    try file_writer.interface.flush();
    debugLog("index:done files={d} elapsed_ms={d}", .{ file_paths.items.len, std.time.milliTimestamp() - index_start_ms });
    logResourceUsage("index:done");
}

const BatchIndexResult = struct {
    documents: std.ArrayListUnmanaged(scip_types.Document),
    external_symbols: std.ArrayListUnmanaged(scip_types.SymbolInformation),
    metadata_root: ?[]const u8,
    analyses: std.ArrayListUnmanaged(scip_main.AnalysisResult),

    fn deinit(batch: *BatchIndexResult, allocator: mem.Allocator) void {
        batch.documents.deinit(allocator);
        batch.external_symbols.deinit(allocator);
        for (batch.analyses.items) |*analysis| {
            analysis.deinit();
        }
        batch.analyses.deinit(allocator);
    }
};

const BatchGroup = struct {
    workspace_root: []const u8,
    package_name: []const u8,
    package_root_input: []const u8,
    requested_paths: std.ArrayListUnmanaged([]const u8) = .{},

    fn deinit(group: *BatchGroup, allocator: mem.Allocator) void {
        allocator.free(group.workspace_root);
        allocator.free(group.package_name);
        allocator.free(group.package_root_input);
        for (group.requested_paths.items) |path| allocator.free(path);
        group.requested_paths.deinit(allocator);
    }
};

fn pathInList(paths: []const []const u8, target: []const u8) bool {
    for (paths) |path| {
        if (mem.eql(u8, path, target)) return true;
    }
    return false;
}

fn emitPhaseProgress(phase: []const u8, done: usize, total: usize, path: ?[]const u8) void {
    var escaped_phase_buf: [128]u8 = undefined;
    const escaped_phase = escapeJson(&escaped_phase_buf, phase);
    if (path) |phase_path| {
        var escaped_path_buf: [4096]u8 = undefined;
        const escaped_path = escapeJson(&escaped_path_buf, phase_path);
        std.debug.print(
            "{{\"type\":\"progress\",\"event\":\"phase\",\"phase\":\"{s}\",\"done\":{d},\"total\":{d},\"path\":\"{s}\"}}\n",
            .{ escaped_phase, done, total, escaped_path },
        );
        return;
    }
    std.debug.print(
        "{{\"type\":\"progress\",\"event\":\"phase\",\"phase\":\"{s}\",\"done\":{d},\"total\":{d}}}\n",
        .{ escaped_phase, done, total },
    );
}

fn indexBatchFiles(allocator: mem.Allocator, file_paths: []const []const u8, full_args: []const []const u8) !BatchIndexResult {
    var groups = std.ArrayListUnmanaged(BatchGroup){};
    defer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    for (file_paths) |input_path| {
        try assignInputToBatchGroup(allocator, &groups, input_path);
    }

    var batch: BatchIndexResult = .{
        .documents = .{},
        .external_symbols = .{},
        .metadata_root = null,
        .analyses = .{},
    };
    errdefer batch.deinit(allocator);

    for (groups.items, 0..) |*group, group_idx| {
        const group_start_ms = std.time.milliTimestamp();
        emitPhaseProgress("group_start", group_idx, groups.items.len, group.workspace_root);
        debugLog("indexBatchFiles:group_start workspace={s} package={s} requested={d}", .{ group.workspace_root, group.package_name, group.requested_paths.items.len });
        logResourceUsage("indexBatchFiles:group_start");

        const packages = [_]scip_main.PackageSpec{
            .{ .name = group.package_name, .path = group.package_root_input },
        };
        var analysis = scip_main.analyze(.{
            .root_path = group.workspace_root,
            .root_pkg = group.package_name,
            .packages = &packages,
            .tool_name = "cog-zig",
            .tool_arguments = full_args,
            .requested_document_relative_paths = group.requested_paths.items,
        }, allocator) catch |err| {
            for (group.requested_paths.items) |requested_path| {
                emitProgress("file_error", requested_path);
                debugLog("file:error path={s} err={s}", .{ requested_path, @errorName(err) });
            }
            if (std.posix.getenv("COG_ZIG_DEBUG") != null) {
                std.debug.print("debug: failed to index batch for {s}: {s}\n", .{ group.workspace_root, @errorName(err) });
            }
            continue;
        };
        errdefer analysis.deinit();

        if (batch.metadata_root == null) {
            batch.metadata_root = analysis.project_root;
        }

        try batch.documents.appendSlice(allocator, analysis.documents.items);
        try batch.external_symbols.appendSlice(allocator, analysis.external_symbols.items);
        try batch.analyses.append(allocator, analysis);

        for (group.requested_paths.items) |requested_path| {
            if (pathInList(analysis.failed_requested_paths.items, requested_path)) {
                emitProgress("file_error", requested_path);
                continue;
            }
            emitProgress("file_done", requested_path);
            debugLog("file:done path={s} elapsed_ms={d}", .{ requested_path, std.time.milliTimestamp() - group_start_ms });
        }
        emitPhaseProgress("group_done", group_idx + 1, groups.items.len, group.workspace_root);
        debugLog("indexBatchFiles:group_done workspace={s} package={s} elapsed_ms={d} docs={d} external_symbols={d}", .{ group.workspace_root, group.package_name, std.time.milliTimestamp() - group_start_ms, analysis.documents.items.len, analysis.external_symbols.items.len });
        logResourceUsage("indexBatchFiles:group_done");
    }

    std.mem.sortUnstable(scip_types.Document, batch.documents.items, {}, struct {
        fn lessThan(_: void, lhs: scip_types.Document, rhs: scip_types.Document) bool {
            return std.mem.lessThan(u8, lhs.relative_path, rhs.relative_path);
        }
    }.lessThan);
    std.mem.sortUnstable(scip_types.SymbolInformation, batch.external_symbols.items, {}, struct {
        fn lessThan(_: void, lhs: scip_types.SymbolInformation, rhs: scip_types.SymbolInformation) bool {
            return std.mem.lessThan(u8, lhs.symbol, rhs.symbol);
        }
    }.lessThan);

    debugLog("indexBatchFiles: completed files={d} docs={d} external_symbols={d}", .{ file_paths.len, batch.documents.items.len, batch.external_symbols.items.len });
    logResourceUsage("indexBatchFiles:done");

    return batch;
}

fn assignInputToBatchGroup(allocator: mem.Allocator, groups: *std.ArrayListUnmanaged(BatchGroup), input_path: []const u8) !void {
    const input_kind = pathKind(input_path);
    if (input_kind != .file) return error.InvalidInput;

    const abs_input_file = try fs.cwd().realpathAlloc(allocator, input_path);
    errdefer allocator.free(abs_input_file);

    const file_dir = fs.path.dirname(abs_input_file) orelse return error.InvalidInput;
    const workspace_root = try findWorkspaceRoot(allocator, file_dir);
    errdefer allocator.free(workspace_root);

    const file_relative_path = try fs.path.relative(allocator, workspace_root, abs_input_file);
    errdefer allocator.free(file_relative_path);

    const pkg_name = discoverPackageName(allocator, workspace_root) catch |err| blk: {
        if (std.posix.getenv("COG_ZIG_DEBUG") != null) {
            std.debug.print("debug: could not read build.zig.zon ({s}), using directory name fallback\n", .{@errorName(err)});
        }
        break :blk dirBasename(workspace_root);
    };
    defer if (pkg_name.allocated) allocator.free(pkg_name.name);

    for (groups.items) |*group| {
        if (!mem.eql(u8, group.workspace_root, workspace_root)) continue;
        if (!mem.eql(u8, group.package_name, pkg_name.name)) continue;

        try group.requested_paths.append(allocator, file_relative_path);
        allocator.free(abs_input_file);
        allocator.free(workspace_root);
        return;
    }

    const owned_package_name = try allocator.dupe(u8, pkg_name.name);
    errdefer allocator.free(owned_package_name);

    var group: BatchGroup = .{
        .workspace_root = workspace_root,
        .package_name = owned_package_name,
        .package_root_input = abs_input_file,
    };
    errdefer group.deinit(allocator);

    try group.requested_paths.append(allocator, file_relative_path);
    try groups.append(allocator, group);
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

test "indexBatchFiles indexes multiple requested files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("workspace/src");
    try tmp.dir.writeFile(.{ .sub_path = "workspace/build.zig.zon", .data = 
        \\ .{
        \\   .name = .workspace,
        \\   .version = "0.0.0",
        \\   .fingerprint = 0x2222222222222222,
        \\   .paths = .{ "src" },
        \\ }
    });
    try tmp.dir.writeFile(.{ .sub_path = "workspace/src/helper.zig", .data = 
        \\ pub fn greet() void {}
    });
    try tmp.dir.writeFile(.{ .sub_path = "workspace/src/main.zig", .data = 
        \\ const helper = @import("helper.zig");
        \\ pub fn main() void {
        \\     helper.greet();
        \\ }
    });

    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const abs_root = try tmp.dir.realpathAlloc(allocator, ".");
    const abs_main = try fs.path.join(allocator, &.{ abs_root, "workspace", "src", "main.zig" });
    const abs_helper = try fs.path.join(allocator, &.{ abs_root, "workspace", "src", "helper.zig" });

    const result = try indexBatchFiles(allocator, &.{ abs_main, abs_helper }, &.{ "cog-zig", "--output", "index.scip", abs_main, abs_helper });

    try std.testing.expectEqual(@as(usize, 2), result.documents.items.len);
    try std.testing.expectEqualStrings("src/helper.zig", result.documents.items[0].relative_path);
    try std.testing.expectEqualStrings("src/main.zig", result.documents.items[1].relative_path);
    try std.testing.expect(result.metadata_root != null);
}
