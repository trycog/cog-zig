# Troubleshooting Native Zig Debugging

## Breakpoints do not bind

- Build with debug info: `zig build -Doptimize=Debug`
- Ensure the launched binary matches current sources
- Verify paths in stack frames match workspace files

## Variables appear as optimized out

- Expected in `ReleaseFast` and `ReleaseSmall`
- Re-run with `-Doptimize=Debug` for full local visibility

## Stack traces show runtime internals

- Confirm boundary markers in `cog-extension.json` remain:
  - `std.start`
  - `__zig_return_address`

## Empty or partial indexing output

- Run with verbose logs: `COG_ZIG_DEBUG=1 bin/cog-zig <root> --output /tmp/index.scip`
- Ensure `build.zig.zon` has a valid `.name`
- Ensure project has one of:
  - `src/main.zig`
  - `src/root.zig`
  - `src/lib.zig`
  - `build.zig`

## Unexpected stderr output

- Successful indexing should be quiet by default
- Unset `COG_ZIG_DEBUG` in normal runs
