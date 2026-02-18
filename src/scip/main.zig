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
    std.log.defaultLog(level, scope, format, args);
}

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = logFn,
};

const ArgState = enum {
    none,
    add_package_name,
    add_package_path,
    root_name,
    root_path,
};

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
};

pub fn run(config: RunConfig, allocator: std.mem.Allocator, writer: anytype) !void {
    var doc_store = DocumentStore{
        .allocator = allocator,
        .root_path = config.root_path,
    };
    defer doc_store.deinit();

    for (config.packages) |pkg| {
        try doc_store.createPackage(pkg.name, pkg.path);
    }

    var tool_args = std.ArrayListUnmanaged([]const u8){};
    defer tool_args.deinit(allocator);
    try tool_args.appendSlice(allocator, config.tool_arguments);

    // Run postResolves on all packages
    var pkg_it = doc_store.packages.iterator();
    while (pkg_it.next()) |pkg_entry| {
        var handle_it = pkg_entry.value_ptr.handles.iterator();
        while (handle_it.next()) |h| {
            try h.value_ptr.*.analyzer.postResolves();
        }
    }

    var documents = try StoreToScip.storeToScip(allocator, &doc_store, config.root_pkg);
    defer {
        for (documents.items) |*doc| {
            allocator.free(doc.relative_path);
        }
        documents.deinit(allocator);
    }

    try filterDocumentsForSinglePath(&documents, config.single_document_relative_path);

    var external_symbols = try StoreToScip.collectExternalSymbols(allocator, documents, config.root_pkg, &doc_store);
    defer external_symbols.deinit(allocator);

    const project_root = try utils.fromPath(allocator, config.root_path);
    defer allocator.free(project_root);
    std.log.info("Using project root {s}", .{project_root});

    try protobruh.encode(scip.Index{
        .metadata = .{
            // unspecified_protocol_version (0) is the only defined value per the SCIP proto spec
            .version = .unspecified_protocol_version,
            .tool_info = .{
                .name = config.tool_name,
                .version = config.tool_version,
                .arguments = tool_args,
            },
            .project_root = project_root,
            .text_document_encoding = .utf8,
        },
        .documents = documents,
        .external_symbols = external_symbols,
    }, writer);
}

fn filterDocumentsForSinglePath(documents: *std.ArrayListUnmanaged(scip.Document), maybe_target_path: ?[]const u8) !void {
    const target_path = maybe_target_path orelse return;

    var target_index: ?usize = null;
    for (documents.items, 0..) |doc, idx| {
        if (std.mem.eql(u8, doc.relative_path, target_path)) {
            target_index = idx;
            break;
        }
    }

    const idx = target_index orelse return error.TargetDocumentNotFound;
    if (idx != 0) {
        const keep = documents.items[idx];
        const first = documents.items[0];
        documents.items[0] = keep;
        documents.items[idx] = first;
    }
    documents.items.len = 1;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;

    var root_path: []const u8 = try std.posix.getcwd(&cwd_buf);
    var root_name: ?[]const u8 = null;
    var package_name: ?[]const u8 = null;
    var root_path_set: bool = false;

    var arg_state: ArgState = .none;
    var arg_iterator = try std.process.ArgIterator.initWithAllocator(allocator);
    defer arg_iterator.deinit();

    // Save arguments during first pass for tool_info
    var saved_args = std.ArrayListUnmanaged([]const u8){};
    defer saved_args.deinit(allocator);

    var packages = std.ArrayListUnmanaged(PackageSpec){};
    defer packages.deinit(allocator);

    while (arg_iterator.next()) |arg| {
        try saved_args.append(allocator, arg);
        switch (arg_state) {
            .none => {
                if (std.mem.eql(u8, arg, "--pkg")) arg_state = .add_package_name;
                if (std.mem.eql(u8, arg, "--root-pkg")) arg_state = .root_name;
                if (std.mem.eql(u8, arg, "--root-path")) arg_state = .root_path;
            },
            .add_package_name => {
                package_name = arg;
                arg_state = .add_package_path;
            },
            .add_package_path => {
                try packages.append(allocator, .{ .name = package_name.?, .path = arg });
                arg_state = .none;
            },
            .root_name => {
                if (root_name != null) std.log.err("Multiple roots detected; this invocation may not behave as expected!", .{});
                root_name = arg;
                arg_state = .none;
            },
            .root_path => {
                if (root_path_set) std.log.err("Multiple root paths detected; this invocation may not behave as expected!", .{});
                root_path_set = true;
                root_path = arg;
                arg_state = .none;
            },
        }
    }

    // Validate that arg parsing completed cleanly
    switch (arg_state) {
        .none => {},
        .add_package_name => {
            std.log.err("--pkg requires <name> <path> arguments", .{});
            return;
        },
        .add_package_path => {
            std.log.err("--pkg requires a path after the package name", .{});
            return;
        },
        .root_name => {
            std.log.err("--root-pkg requires a package name argument", .{});
            return;
        },
        .root_path => {
            std.log.err("--root-path requires a path argument", .{});
            return;
        },
    }

    if (root_name == null) {
        std.log.err("Please specify a root package name with --root-pkg!", .{});
        return;
    }

    var index = try std.fs.cwd().createFile("index.scip", .{});
    defer index.close();

    var write_buf: [4096]u8 = undefined;
    var file_writer = index.writer(&write_buf);

    try run(.{
        .root_path = root_path,
        .root_pkg = root_name.?,
        .packages = packages.items,
        .tool_arguments = saved_args.items,
    }, allocator, &file_writer.interface);

    try file_writer.interface.flush();
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

test "single-document filter keeps only requested document" {
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

    try filterDocumentsForSinglePath(&docs, "src/b.zig");
    try std.testing.expectEqual(@as(usize, 1), docs.items.len);
    try std.testing.expectEqualStrings("src/b.zig", docs.items[0].relative_path);
}
