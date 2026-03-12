<div align="center">

# cog-zig

**Zig language extension for [Cog](https://github.com/trycog/cog-cli).**

SCIP-based code intelligence and native DWARF debugging for Zig projects.

[Installation](#installation) · [Code Intelligence](#code-intelligence) · [Debugging](#debugging) · [How It Works](#how-it-works) · [Development](#development)

</div>

---

## Installation

### Prerequisites

- [Zig 0.15.0+](https://ziglang.org/download/)
- [Cog](https://github.com/trycog/cog-cli) CLI installed

### Install

```sh
cog ext:install https://github.com/trycog/cog-zig.git
cog ext:install https://github.com/trycog/cog-zig --version=0.1.0
cog ext:update
cog ext:update cog-zig
```

Cog downloads the tagged GitHub release tarball, then builds locally on the installing machine with `zig build -Doptimize=ReleaseFast` and installs to `~/.config/cog/extensions/cog-zig/`. `--version` matches an exact release version after optional `v` prefix normalization.

The extension version is defined once in `cog-extension.json`; the Zig build and runtime both read that version from the manifest, release tags use `vX.Y.Z`, and the install flag uses the matching bare semver `X.Y.Z`.

---

## Code Intelligence

Configure file patterns in `.cog/settings.json`:

```json
{
  "code": {
    "index": [
      "src/**/*.zig",
      "build.zig.zon",
      "build.zig"
    ]
  }
}
```

Then build the index:

```sh
cog code:index
```

Query symbols:

```sh
cog code:query --find "main"
cog code:query --refs "allocator"
cog code:query --symbols src/main.zig
```

A built-in file watcher automatically keeps the index up to date as files change — no manual re-indexing needed after the initial build.

| File Type | Capabilities |
|-----------|--------------|
| `.zig` | Go-to-definition, find references, symbol search, project structure |
| `.zon` | Project discovery metadata (package/root inference), not symbol indexing |

By default, successful indexing emits only structured progress events on
stderr so Cog can update file-by-file progress. Set `COG_ZIG_DEBUG=1` to
enable additional verbose diagnostics.

### Indexing Features

The built-in SCIP indexer supports:

- Globals, locals (explicit and inferred typing), and `comptime` expressions
- Functions (parameters, return types, bodies)
- Namespaced declarations (structs, enums, unions, error sets)
- Imports (`@import` with cross-file symbol linking and multi-package resolution)
- Control flow (`if`/`else`, `while`, `for`, `switch`, `catch`, `defer`/`errdefer`, labeled blocks) with payload captures
- Type expressions (pointers `*T`/`[*]T`/`[]T`, optionals `?T`, error unions `E!T`, arrays `[N]T`)
- Error values, enum literals, builtin calls
- Struct literal field references and chained field access
- Type definition relationships (through `?T`, `*T`, `[]T`, `E!T`)
- Write/read access tracking
- Doc comment and signature extraction
- Test declarations
- Deterministic output ordering

---

## Debugging

Start the MCP debug server:

```sh
cog debug:serve
```

Launch a debug-built Zig binary through the debug server for breakpoints, stepping, and variable inspection.

| Setting | Value |
|---------|-------|
| Debugger type | `native` — Cog's built-in DWARF engine |
| Platform support | ptrace (Linux), mach (macOS) |
| Boundary markers | `std.start`, `__zig_return_address` |

Boundary markers filter Zig runtime internals from stack traces so you only see your code.

For smoke-test commands and fixtures, see `src/debug/tests/debug_smoke.md`.
Version and build-mode expectations are tracked in `src/debug/tests/zig_version_matrix.md`.

---

## How It Works

Cog invokes `cog-zig` once per extension group. It expands matched files onto
argv, the wrapper distributes that batch across internal worker threads, and it
emits per-file progress events on stderr as each file finishes:

```
cog invokes:      bin/cog-zig --output <output_path> <file_path> [file_path ...]
wrapper executes: in-process SCIP indexing for one or more documents
```

**Auto-discovery:**

| Step | Logic |
|------|-------|
| Workspace root | Walks up from each input file until a directory containing `build.zig.zon` is found (fallback: file parent directory). |
| Package name | Parsed from workspace `build.zig.zon` `.name` field (both `.identifier` and `"string"` forms). Falls back to workspace directory name. |
| Indexed target | Every file expanded from `{files}`; output is one SCIP protobuf containing one document per input file. |

### Architecture

```
src/
├── main.zig                    # cog-zig wrapper binary (entry point for Cog)
└── scip/
    ├── main.zig                # SCIP indexer core with run() API and standalone CLI
    ├── scip.zig                # SCIP protocol type definitions
    ├── protobruh.zig           # Protobuf encode/decode library
    ├── StoreToScip.zig         # Converts analysis results to SCIP documents
    └── analysis/
        ├── Analyzer.zig        # Zig AST walker and symbol extraction
        ├── DocumentStore.zig   # Document/package management, import resolution
        ├── offsets.zig         # Line index and position calculations
        └── utils.zig           # AST utility functions
```

The indexer has zero external Zig dependencies — everything is self-contained.

---

## Development

### Build from source

```sh
zig build -Doptimize=ReleaseFast
```

Produces `zig-out/bin/cog-zig`.

Cog installs from GitHub release source tarballs and then runs the same build locally after download.

### Test

```sh
zig build test    # Unit + integration tests
```

Tests cover protobuf encoding/decoding, fixture-based indexing (chained field access, cross-file imports, pointer/optional types, comptime generics, nested factories), deterministic output, and single-document filtering.

### Manual verification

```sh
zig build
bin/cog-zig --output /tmp/index.scip /path/to/file.zig /path/to/other.zig
```

### Indexing diagnostics

Enable verbose indexing diagnostics with:

```sh
COG_ZIG_DEBUG=1 bin/cog-zig --output /tmp/index.scip /path/to/file.zig 2> /tmp/cog-zig-debug.log
```

With `COG_ZIG_DEBUG=1`, the wrapper emits structured debug events on stderr for
per-file timing, SCIP phase timing, and process resource-usage snapshots. When
run through `cog code:index` with Cog debug logging enabled, those non-progress
stderr lines are forwarded into `.cog/cog.log` while progress JSON continues to
drive the live TUI.

### Release

- Set the next version in `cog-extension.json`
- Tag releases as `vX.Y.Z` to match Cog's exact-version install flow
- Pushing a matching tag triggers GitHub Actions to verify the tag against `cog-extension.json`, run tests, and create a GitHub Release
- Cog installs from the release source tarball, but the extension still builds locally after download

---

## Acknowledgments

The SCIP indexing engine (`src/scip/`) is derived from [scip-zig](https://github.com/niclas-overby/scip-zig) by Auguste Rame, licensed under the [MIT License](src/scip/LICENSE). The original README is preserved at [`src/scip/README.upstream.md`](src/scip/README.upstream.md).

The SCIP protocol types in `src/scip/scip.zig` are derived from the [SCIP specification](https://github.com/sourcegraph/scip) by Sourcegraph.

---

<div align="center">
<sub>Built with <a href="https://ziglang.org">Zig</a></sub>
</div>
