# Native Debug Matrix

This matrix hardens native debugger validation for Zig while keeping
`cog-cli` language-agnostic.

## Build Modes

| Mode | Expected behavior |
|------|-------------------|
| `Debug` | Breakpoints, locals, and stepping should be high-fidelity |
| `ReleaseFast` | Stepping works, locals may be partial/optimized out |
| `ReleaseSmall` | Similar to ReleaseFast with additional symbol loss risk |

## Fixture Coverage

| Fixture | Goal |
|---------|------|
| `src/debug/fixtures/debug/basic_debug.zig` | baseline breakpoint + locals |
| `src/debug/fixtures/debug/inline_stack.zig` | inline call stack behavior |
| `src/debug/fixtures/debug/optimized_visibility.zig` | optimized variable visibility expectations |

## Validation Commands

```bash
zig build-exe src/debug/fixtures/debug/basic_debug.zig -O Debug -femit-bin=/tmp/cog-zig-basic-debug
zig build-exe src/debug/fixtures/debug/inline_stack.zig -O Debug -femit-bin=/tmp/cog-zig-inline-debug
zig build-exe src/debug/fixtures/debug/optimized_visibility.zig -O ReleaseFast -femit-bin=/tmp/cog-zig-opt-debug
```

Then run each binary through `cog debug/*` flow from `debug_smoke.md`.

## Acceptance Criteria

- Debug mode fixtures hit breakpoints in user code.
- Stack traces retain user frames with runtime filtering from boundary markers.
- Release fixtures may report optimized-out locals without being treated as failures.
