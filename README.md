<div align="center">

# cog-zig

**Zig language extension for [Cog](https://github.com/bcardarella/cog).**

SCIP-based code intelligence and native DWARF debugging for Zig projects.

[Installation](#installation) · [Code Intelligence](#code-intelligence) · [Debugging](#debugging) · [How It Works](#how-it-works) · [Development](#development)

</div>

---

## Installation

### Prerequisites

- [Zig 0.15.0+](https://ziglang.org/download/)
- [Cog](https://github.com/bcardarella/cog) CLI installed

### Install

```sh
cog install https://github.com/bcardarella/cog-zig.git
```

This clones the repo, builds with `zig build -Doptimize=ReleaseFast`, and installs to `~/.config/cog/extensions/cog-zig/`.

---

## Code Intelligence

Index Zig source files in your project:

```sh
cog code/index "**/*.zig"
```

Query symbols:

```sh
cog code/query --find "main"
cog code/query --refs "allocator" --limit 20
cog code/query --symbols src/main.zig
```

| File Type | Capabilities |
|-----------|--------------|
| `.zig` | Go-to-definition, find references, symbol search, project structure |
| `.zon` | Project discovery metadata (package/root inference), not symbol indexing |

By default, successful indexing runs are quiet (no stdout/stderr). Set
`COG_ZIG_DEBUG=1` to enable verbose diagnostics.

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
cog debug/serve
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

Cog invokes `cog-zig` once per file. The wrapper discovers the project context and runs the indexer in-process:

```
cog invokes:      bin/cog-zig <file_path> --output <output_path>
wrapper executes: in-process SCIP indexing for exactly one document
```

**Auto-discovery:**

| Step | Logic |
|------|-------|
| Workspace root | Walks up from input file until a directory containing `build.zig.zon` is found (fallback: file parent directory). |
| Package name | Parsed from workspace `build.zig.zon` `.name` field (both `.identifier` and `"string"` forms). Falls back to workspace directory name. |
| Indexed target | The exact file passed in `{file}`; output is a SCIP protobuf containing one document. |

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

### Test

```sh
zig build test    # Unit + integration tests
```

Tests cover protobuf encoding/decoding, fixture-based indexing (chained field access, cross-file imports, pointer/optional types, comptime generics, nested factories), deterministic output, and single-document filtering.

### Manual verification

```sh
zig build
bin/cog-zig /path/to/file.zig --output /tmp/index.scip
```

---

## Acknowledgments

The SCIP indexing engine (`src/scip/`) is derived from [scip-zig](https://github.com/niclas-overby/scip-zig) by Auguste Rame, licensed under the [MIT License](src/scip/LICENSE). The original README is preserved at [`src/scip/README.upstream.md`](src/scip/README.upstream.md).

The SCIP protocol types in `src/scip/scip.zig` are derived from the [SCIP specification](https://github.com/sourcegraph/scip) by Sourcegraph.

---

<div align="center">
<sub>Built with <a href="https://ziglang.org">Zig</a></sub>
</div>
