# Baseline

This baseline captures intended behavior after scip-zig vendoring and in-process
indexing integration.

## Indexing Baseline

- Entry binary: `bin/cog-zig`
- Contract: `cog-zig <project_root> --output <path>`
- Output: SCIP protobuf written to `<path>`
- Runtime model: in-process call into `src/scip/main.zig`

## Logging Baseline

- Successful indexing should be quiet (no stdout/stderr)
- Verbose diagnostics are opt-in via `COG_ZIG_DEBUG=1`

## Debug Baseline

- Debugger type remains `native` in `cog-extension.json`
- Zig-specific behavior remains extension-owned via docs/fixtures/validation
- No language-specific debugger logic is added to `cog-cli`

## Known Indexing Limitations

- Pointer/optional field access and some comptime-generic patterns are indexed,
  but may emit partial read-reference role coverage.
- Fixture coverage tracks these patterns to prevent regressions while semantic
  precision is incrementally improved.
