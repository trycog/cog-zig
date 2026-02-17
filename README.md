<div align="center">

# cog-zig

**Zig language extension for [Cog](https://github.com/bcardarella/cog).**

Code intelligence and native DWARF debugging for Zig projects. Wraps [scip-zig](https://github.com/bcardarella/scip-zig) for SCIP indexing.

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

| File Types | Capabilities |
|------------|-------------|
| `.zig`, `.zon` | Go-to-definition, find references, symbol search, project structure |

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

---

## How It Works

The wrapper binary (`bin/cog-zig`) translates Cog's calling convention to [scip-zig](https://github.com/bcardarella/scip-zig)'s CLI:

```
cog invokes:   bin/cog-zig <project_root> --output <output_path>
wrapper runs:  bin/scip-zig --root-path <project_root> --pkg <name> <root_source> --root-pkg <name>
```

**Auto-discovery:**

| Step | Logic |
|------|-------|
| Package name | Parsed from `build.zig.zon` `.name` field. Falls back to directory name. |
| Root source | Checks `src/main.zig` → `src/root.zig` → `src/lib.zig` → `build.zig` |

---

## Development

### Build from source

```sh
zig build -Doptimize=ReleaseFast
```

Produces two binaries in `zig-out/bin/`:

| Binary | Purpose |
|--------|---------|
| `cog-zig` | Wrapper binary (Cog invokes this) |
| `scip-zig` | The scip-zig indexer (wrapper invokes this) |

### Verify

```sh
zig build                                    # Debug build
bin/cog-zig /path/to/project --output /tmp/index.scip  # Test indexing
```

---

<div align="center">
<sub>Built with <a href="https://ziglang.org">Zig</a> · Powered by <a href="https://github.com/bcardarella/scip-zig">scip-zig</a></sub>
</div>
