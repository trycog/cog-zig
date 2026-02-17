# Zig Version Matrix

## Supported Versions

| Zig version | Status | Notes |
|-------------|--------|-------|
| 0.15.x | supported | Primary tested line for this extension |
| 0.14.x | best effort | Run full smoke checks before promoting to supported |

## Required Validation Per Version

```bash
zig version
zig build
zig build test
zig build -Doptimize=ReleaseFast
```

Run native-debug smoke checks from `src/debug/tests/debug_smoke.md` and
build-mode expectations from `src/debug/tests/debug_matrix.md`.

## Promotion Criteria (best effort -> supported)

- `zig build` passes
- `zig build test` passes
- indexing fixture matrix passes
- debug smoke checks pass for Debug and Release expectations
