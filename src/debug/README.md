# cog-zig Debug and Validation

This directory contains debug-focused documentation, fixtures, and tests for the
`cog-zig` extension.

## Goals

- Verify extension contract compliance from `cog-cli/EXTENSIONS.md`
- Validate indexing reliability and deterministic behavior
- Validate native debug readiness for Zig projects

## Quick Validation

```bash
zig build
zig build test
zig build -Doptimize=ReleaseFast
bin/cog-zig /path/to/zig/project --output /tmp/index.scip
```

Expected:

- `bin/cog-zig` writes a SCIP protobuf to `--output`
- No stdout/stderr output on successful runs (unless `COG_ZIG_DEBUG=1`)

## Native Debugger Expectations

`cog-zig` uses the `native` debugger type and relies on Cog's language-agnostic
DWARF engine.

For best results, compile debug targets with DWARF enabled:

```bash
zig build -Doptimize=Debug
```

Common pitfalls:

- Release builds may optimize away locals
- Stripped binaries reduce symbol fidelity
- Mismatched source/binary paths produce confusing stack frames

See `src/debug/tests/debug_smoke.md` for manual end-to-end debug checks.

Use `src/debug/tests/debug_matrix.md` for build-mode expectations and fixture coverage.

## Indexing Fixture Matrix

The indexing regression corpus lives in `src/debug/fixtures/indexing/`:

- `simple_project`
- `chained_field_access`
- `nested_factory`
- `cross_file_import`
- `pointer_optional`
- `comptime_generic`

Compatibility expectations live in `src/debug/tests/zig_version_matrix.md`.
Common failure diagnosis is documented in `src/debug/TROUBLESHOOTING.md`.
