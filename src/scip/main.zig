const std = @import("std");
const scip = @import("scip.zig");
const protobruh = @import("protobruh.zig");
const StoreToScip = @import("StoreToScip.zig");
const DocumentStore = @import("analysis/DocumentStore.zig");
const utils = @import("analysis/utils.zig");

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
    } else {
        std.debug.print(
            "{{\"type\":\"progress\",\"event\":\"phase\",\"phase\":\"{s}\",\"done\":{d},\"total\":{d}}}\n",
            .{ escaped_phase, done, total },
        );
    }
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

pub const PackageSpec = struct {
    name: []const u8,
    path: []const u8,
};

pub const RunConfig = struct {
    root_path: []const u8,
    root_pkg: []const u8,
    packages: []const PackageSpec,
    tool_name: []const u8 = "scip-zig",
    tool_version: []const u8 = "unversioned",
    tool_arguments: []const []const u8 = &.{},
    single_document_relative_path: ?[]const u8 = null,
    requested_document_relative_paths: ?[]const []const u8 = null,
};

pub const AnalysisResult = struct {
    store: DocumentStore,
    documents: std.ArrayListUnmanaged(scip.Document),
    external_symbols: std.ArrayListUnmanaged(scip.SymbolInformation),
    project_root: []const u8,
    failed_requested_paths: std.ArrayListUnmanaged([]const u8),

    pub fn deinit(result: *AnalysisResult) void {
        for (result.documents.items) |*doc| {
            result.store.allocator.free(doc.relative_path);
        }
        result.documents.deinit(result.store.allocator);
        result.external_symbols.deinit(result.store.allocator);
        result.failed_requested_paths.deinit(result.store.allocator);
        result.store.allocator.free(result.project_root);
        result.store.deinit();
    }
};

fn markFailedRequestedPath(
    allocator: std.mem.Allocator,
    failed_paths: *std.ArrayListUnmanaged([]const u8),
    requested_path: []const u8,
) !void {
    for (failed_paths.items) |existing| {
        if (std.mem.eql(u8, existing, requested_path)) return;
    }
    try failed_paths.append(allocator, requested_path);
}

fn pathRequested(requested_paths: []const []const u8, path: []const u8) bool {
    for (requested_paths) |requested_path| {
        if (std.mem.eql(u8, requested_path, path)) return true;
    }
    return false;
}

pub fn analyze(config: RunConfig, allocator: std.mem.Allocator) !AnalysisResult {
    const analyze_start_ms = std.time.milliTimestamp();
    var doc_store = DocumentStore{
        .allocator = allocator,
        .root_path = config.root_path,
    };
    errdefer doc_store.deinit();

    for (config.packages) |pkg| {
        try doc_store.createPackage(pkg.name, pkg.path);
    }

    var failed_requested_paths = std.ArrayListUnmanaged([]const u8){};
    errdefer failed_requested_paths.deinit(allocator);

    if (config.requested_document_relative_paths) |requested_paths| {
        emitPhaseProgress("load_requested", 0, requested_paths.len, config.root_path);
        for (requested_paths, 0..) |requested_path, idx| {
            _ = doc_store.getOrLoadFile(config.root_pkg, requested_path) catch |err| {
                try markFailedRequestedPath(allocator, &failed_requested_paths, requested_path);
                std.log.warn("failed to load requested path {s}: {s}", .{ requested_path, @errorName(err) });
                continue;
            };
            emitPhaseProgress("load_requested", idx + 1, requested_paths.len, requested_path);
        }
    }

    std.log.info("analyze: requested loading elapsed_ms={d}", .{std.time.milliTimestamp() - analyze_start_ms});

    // Run postResolves on all packages
    const post_resolve_start_ms = std.time.milliTimestamp();
    var pkg_it = doc_store.packages.iterator();
    var total_handles: usize = 0;
    var pkg_it_count = doc_store.packages.iterator();
    while (pkg_it_count.next()) |pkg_entry| total_handles += pkg_entry.value_ptr.handles.count();
    var resolved_handles: usize = 0;
    while (pkg_it.next()) |pkg_entry| {
        var handle_it = pkg_entry.value_ptr.handles.iterator();
        while (handle_it.next()) |h| {
            emitPhaseProgress("post_resolves", resolved_handles, total_handles, h.key_ptr.*);
            h.value_ptr.*.analyzer.postResolves() catch |err| {
                if (config.requested_document_relative_paths) |requested_paths| {
                    if (pathRequested(requested_paths, h.key_ptr.*)) {
                        try markFailedRequestedPath(allocator, &failed_requested_paths, h.key_ptr.*);
                    }
                }
                std.log.warn("postResolves failed for {s}: {s}", .{ h.key_ptr.*, @errorName(err) });
                resolved_handles += 1;
                continue;
            };
            resolved_handles += 1;
        }
    }
    emitPhaseProgress("post_resolves", resolved_handles, total_handles, config.root_path);
    std.log.info("analyze: postResolves elapsed_ms={d} handles={d}", .{ std.time.milliTimestamp() - post_resolve_start_ms, total_handles });

    var requested_paths = config.requested_document_relative_paths;
    var single_requested: [1][]const u8 = undefined;
    if (requested_paths == null) {
        if (config.single_document_relative_path) |single_path| {
            single_requested[0] = single_path;
            requested_paths = single_requested[0..];
        }
    }

    var successful_requested_paths = std.ArrayListUnmanaged([]const u8){};
    defer successful_requested_paths.deinit(allocator);
    if (requested_paths) |paths| {
        for (paths) |requested_path| {
            if (!pathRequested(failed_requested_paths.items, requested_path)) {
                try successful_requested_paths.append(allocator, requested_path);
            }
        }
        requested_paths = successful_requested_paths.items;
    }

    const store_to_scip_start_ms = std.time.milliTimestamp();
    emitPhaseProgress("store_to_scip", 0, 1, config.root_path);
    var documents = try StoreToScip.storeToScip(allocator, &doc_store, config.root_pkg, requested_paths);
    errdefer {
        for (documents.items) |*doc| {
            allocator.free(doc.relative_path);
        }
        documents.deinit(allocator);
    }
    emitPhaseProgress("store_to_scip", 1, 1, config.root_path);
    std.log.info("analyze: storeToScip elapsed_ms={d} docs={d}", .{ std.time.milliTimestamp() - store_to_scip_start_ms, documents.items.len });

    try validateRequestedDocuments(documents.items, requested_paths);

    const external_symbols_start_ms = std.time.milliTimestamp();
    emitPhaseProgress("external_symbols", 0, 1, config.root_path);
    var external_symbols = try StoreToScip.collectExternalSymbols(allocator, documents, config.root_pkg, &doc_store);
    errdefer external_symbols.deinit(allocator);
    emitPhaseProgress("external_symbols", 1, 1, config.root_path);
    std.log.info("analyze: external_symbols elapsed_ms={d} symbols={d}", .{ std.time.milliTimestamp() - external_symbols_start_ms, external_symbols.items.len });

    const project_root = try utils.fromPath(allocator, config.root_path);
    std.log.info("Using project root {s}", .{project_root});
    std.log.info("analyze: total elapsed_ms={d}", .{std.time.milliTimestamp() - analyze_start_ms});

    return .{
        .store = doc_store,
        .documents = documents,
        .external_symbols = external_symbols,
        .project_root = project_root,
        .failed_requested_paths = failed_requested_paths,
    };
}

pub fn run(config: RunConfig, allocator: std.mem.Allocator, writer: anytype) !void {
    var result = try analyze(config, allocator);
    defer result.deinit();

    var tool_args = std.ArrayListUnmanaged([]const u8){};
    defer tool_args.deinit(allocator);
    try tool_args.appendSlice(allocator, config.tool_arguments);

    try protobruh.encode(scip.Index{
        .metadata = .{
            // unspecified_protocol_version (0) is the only defined value per the SCIP proto spec
            .version = .unspecified_protocol_version,
            .tool_info = .{
                .name = config.tool_name,
                .version = config.tool_version,
                .arguments = tool_args,
            },
            .project_root = result.project_root,
            .text_document_encoding = .utf8,
        },
        .documents = result.documents,
        .external_symbols = result.external_symbols,
    }, writer);
}

fn validateRequestedDocuments(documents: []const scip.Document, maybe_requested_paths: ?[]const []const u8) !void {
    const requested_paths = maybe_requested_paths orelse return;

    for (requested_paths) |requested_path| {
        for (documents) |doc| {
            if (std.mem.eql(u8, doc.relative_path, requested_path)) break;
        } else return error.TargetDocumentNotFound;
    }
}

test {
    _ = @import("protobruh.zig");
    _ = @import("StoreToScip.zig");
    _ = @import("analysis/Analyzer.zig");
}

test "indexes chained field access with correct symbol roles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "build.zig.zon", .data = 
        \\ .{
        \\   .name = .fixture,
        \\   .version = "0.0.0",
        \\   .fingerprint = 0x2222222222222222,
        \\   .paths = .{ "src" },
        \\ }
    });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = 
        \\ const Data = struct { value: i32 };
        \\ fn make() Data {
        \\     return .{ .value = 42 };
        \\ }
        \\ pub fn main() void {
        \\     const x = make().value;
        \\     _ = x;
        \\ }
    });

    const abs_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs_root);
    const abs_main = try std.fs.path.join(std.testing.allocator, &.{ abs_root, "src/main.zig" });
    defer std.testing.allocator.free(abs_main);

    var store = DocumentStore{
        .allocator = std.testing.allocator,
        .root_path = abs_root,
    };
    defer store.deinit();

    try store.createPackage("fixture", abs_main);

    var pkg_it = store.packages.iterator();
    while (pkg_it.next()) |pkg_entry| {
        var handle_it = pkg_entry.value_ptr.handles.iterator();
        while (handle_it.next()) |h| {
            try h.value_ptr.*.analyzer.postResolves();
        }
    }

    const pkg = store.packages.get("fixture") orelse return error.TestUnexpectedResult;
    const root_handle = pkg.handles.get(pkg.root_relative) orelse return error.TestUnexpectedResult;

    var value_occurrences: usize = 0;
    var saw_definition = false;
    var saw_read_reference = false;
    for (root_handle.analyzer.occurrences.items) |occ| {
        if (std.mem.endsWith(u8, occ.symbol, "value.")) {
            value_occurrences += 1;
            const is_definition = (occ.symbol_roles & @intFromEnum(scip.SymbolRole.definition)) != 0;
            const is_read = (occ.symbol_roles & @intFromEnum(scip.SymbolRole.read_access)) != 0;

            if (is_definition) saw_definition = true;
            if (is_read and !is_definition) saw_read_reference = true;
        }
    }

    try std.testing.expect(value_occurrences >= 2);
    try std.testing.expect(saw_definition);
    try std.testing.expect(saw_read_reference);
}

test "emits import relationships with kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "build.zig.zon", .data = 
        \\ .{
        \\   .name = .fixture,
        \\   .version = "0.0.0",
        \\   .fingerprint = 0x2222222222222222,
        \\   .paths = .{ "src" },
        \\ }
    });
    try tmp.dir.writeFile(.{ .sub_path = "src/helper.zig", .data = 
        \\ pub fn greet() void {}
    });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = 
        \\ const helper = @import("helper.zig");
        \\ fn greet() void {
        \\     helper.greet();
        \\ }
        \\ pub fn run() void {
        \\     greet();
        \\ }
    });

    const abs_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs_root);
    const abs_main = try std.fs.path.join(std.testing.allocator, &.{ abs_root, "src/main.zig" });
    defer std.testing.allocator.free(abs_main);

    var store = DocumentStore{
        .allocator = std.testing.allocator,
        .root_path = abs_root,
    };
    defer store.deinit();

    try store.createPackage("fixture", abs_main);

    var pkg_it = store.packages.iterator();
    while (pkg_it.next()) |pkg_entry| {
        var handle_it = pkg_entry.value_ptr.handles.iterator();
        while (handle_it.next()) |h| {
            try h.value_ptr.*.analyzer.postResolves();
        }
    }

    const pkg = store.packages.get("fixture") orelse return error.TestUnexpectedResult;
    const root_handle = pkg.handles.get(pkg.root_relative) orelse return error.TestUnexpectedResult;

    var saw_import = false;
    for (root_handle.analyzer.symbols.items) |sym| {
        for (sym.relationships.items) |rel| {
            if (std.mem.eql(u8, rel.kind, "imports")) saw_import = true;
        }
    }

    try std.testing.expect(saw_import);
}

fn analyzeFixtureMain(allocator: std.mem.Allocator, fixture_rel_root: []const u8, package_name: []const u8) !*DocumentStore.Handle {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const abs_root = try std.fs.path.join(allocator, &.{ cwd, fixture_rel_root });
    errdefer allocator.free(abs_root);
    const abs_main = try std.fs.path.join(allocator, &.{ abs_root, "src/main.zig" });
    defer allocator.free(abs_main);

    var store = try allocator.create(DocumentStore);
    errdefer {
        allocator.free(abs_root);
        allocator.destroy(store);
    }
    store.* = .{
        .allocator = allocator,
        .root_path = abs_root,
    };

    try store.createPackage(package_name, abs_main);

    var pkg_it = store.packages.iterator();
    while (pkg_it.next()) |pkg_entry| {
        var handle_it = pkg_entry.value_ptr.handles.iterator();
        while (handle_it.next()) |h| {
            try h.value_ptr.*.analyzer.postResolves();
        }
    }

    const pkg = store.packages.get(package_name) orelse return error.TestUnexpectedResult;
    const root_handle = pkg.handles.get(pkg.root_relative) orelse return error.TestUnexpectedResult;
    return root_handle;
}

fn indexFixtureBytes(
    allocator: std.mem.Allocator,
    fixture_rel_root: []const u8,
    package_name: []const u8,
) ![]u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const abs_root = try std.fs.path.join(allocator, &.{ cwd, fixture_rel_root });
    defer allocator.free(abs_root);
    const abs_main = try std.fs.path.join(allocator, &.{ abs_root, "src/main.zig" });
    defer allocator.free(abs_main);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_file = try tmp.dir.createFile("index.scip", .{});
    defer out_file.close();

    var write_buf: [4096]u8 = undefined;
    var writer = out_file.writer(&write_buf);

    const args = [_][]const u8{ "cog-zig", fixture_rel_root, "--output", "index.scip" };
    const packages = [_]PackageSpec{.{ .name = package_name, .path = abs_main }};

    try run(.{
        .root_path = abs_root,
        .root_pkg = package_name,
        .packages = &packages,
        .tool_name = "cog-zig",
        .tool_arguments = &args,
    }, allocator, &writer.interface);
    try writer.interface.flush();

    return try tmp.dir.readFileAlloc(allocator, "index.scip", 64 * 1024 * 1024);
}

test "fixture matrix nested_factory has field read references" {
    const allocator = std.testing.allocator;
    const handle = try analyzeFixtureMain(allocator, "src/debug/fixtures/indexing/nested_factory", "nested_factory");
    defer {
        const store = handle.document_store;
        store.deinit();
        allocator.free(store.root_path);
        allocator.destroy(store);
    }

    var saw_inner_read = false;
    var saw_value_read = false;
    for (handle.analyzer.occurrences.items) |occ| {
        const is_read = (occ.symbol_roles & @intFromEnum(scip.SymbolRole.read_access)) != 0;
        const is_definition = (occ.symbol_roles & @intFromEnum(scip.SymbolRole.definition)) != 0;
        if (is_read and !is_definition and std.mem.endsWith(u8, occ.symbol, "inner.")) saw_inner_read = true;
        if (is_read and !is_definition and std.mem.endsWith(u8, occ.symbol, "value.")) saw_value_read = true;
    }

    try std.testing.expect(saw_inner_read);
    try std.testing.expect(saw_value_read);
}

test "fixture matrix cross_file_import has imported field read reference" {
    const allocator = std.testing.allocator;
    const handle = try analyzeFixtureMain(allocator, "src/debug/fixtures/indexing/cross_file_import", "cross_file_import");
    defer {
        const store = handle.document_store;
        store.deinit();
        allocator.free(store.root_path);
        allocator.destroy(store);
    }

    var saw_amount_read = false;
    for (handle.analyzer.occurrences.items) |occ| {
        const is_read = (occ.symbol_roles & @intFromEnum(scip.SymbolRole.read_access)) != 0;
        const is_definition = (occ.symbol_roles & @intFromEnum(scip.SymbolRole.definition)) != 0;
        if (is_read and !is_definition and std.mem.endsWith(u8, occ.symbol, "amount.")) {
            saw_amount_read = true;
        }
    }

    try std.testing.expect(saw_amount_read);
}

test "fixture matrix pointer_optional indexes field symbols" {
    const allocator = std.testing.allocator;
    const handle = try analyzeFixtureMain(allocator, "src/debug/fixtures/indexing/pointer_optional", "pointer_optional");
    defer {
        const store = handle.document_store;
        store.deinit();
        allocator.free(store.root_path);
        allocator.destroy(store);
    }

    var saw_name_symbol = false;
    for (handle.analyzer.occurrences.items) |occ| {
        if (std.mem.endsWith(u8, occ.symbol, "name.")) saw_name_symbol = true;
    }

    try std.testing.expect(saw_name_symbol);
}

test "fixture matrix comptime_generic indexes field symbols" {
    const allocator = std.testing.allocator;
    const handle = try analyzeFixtureMain(allocator, "src/debug/fixtures/indexing/comptime_generic", "comptime_generic");
    defer {
        const store = handle.document_store;
        store.deinit();
        allocator.free(store.root_path);
        allocator.destroy(store);
    }

    var saw_value_symbol = false;
    for (handle.analyzer.occurrences.items) |occ| {
        if (std.mem.endsWith(u8, occ.symbol, "value.")) saw_value_symbol = true;
    }

    try std.testing.expect(saw_value_symbol);
}

test "deterministic SCIP output for indexing fixtures" {
    const allocator = std.testing.allocator;

    const first = try indexFixtureBytes(allocator, "src/debug/fixtures/indexing/chained_field_access", "chained_field_access");
    defer allocator.free(first);
    const second = try indexFixtureBytes(allocator, "src/debug/fixtures/indexing/chained_field_access", "chained_field_access");
    defer allocator.free(second);

    try std.testing.expectEqual(first.len, second.len);
    try std.testing.expect(std.mem.eql(u8, first, second));
}

test "validateRequestedDocuments accepts requested paths" {
    var docs = std.ArrayListUnmanaged(scip.Document){};
    defer docs.deinit(std.testing.allocator);

    try docs.append(std.testing.allocator, .{
        .language = "zig",
        .relative_path = "src/a.zig",
        .occurrences = .{},
        .symbols = .{},
    });
    try docs.append(std.testing.allocator, .{
        .language = "zig",
        .relative_path = "src/b.zig",
        .occurrences = .{},
        .symbols = .{},
    });

    try validateRequestedDocuments(docs.items, &.{"src/b.zig"});
    try std.testing.expectError(error.TargetDocumentNotFound, validateRequestedDocuments(docs.items, &.{"src/missing.zig"}));
}
