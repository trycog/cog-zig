# Native Debug Smoke Test

This validates that Zig projects can use Cog's native debugger path.

## 1) Build a debug fixture

```bash
zig build-exe src/debug/fixtures/debug/basic_debug.zig -O Debug -femit-bin=/tmp/cog-zig-basic-debug
```

## 2) Start debug daemon

```bash
cog debug/serve
```

## 3) Launch and set breakpoint

```bash
cog debug/send_launch --program /tmp/cog-zig-basic-debug
cog debug/send_breakpoint_set --session_id <id> --file src/debug/fixtures/debug/basic_debug.zig --line 10
```

## 4) Run and inspect

```bash
cog debug/send_run --session_id <id> --action continue
cog debug/send_stacktrace --session_id <id>
cog debug/send_scopes --session_id <id> --frame_id <frame-id>
cog debug/send_inspect --session_id <id> --expression total
```

## 5) Validate expectations

- Breakpoint binds and hits expected user frame
- Stack trace contains user frames; runtime frames are filtered by boundary markers
- Local values are available in Debug builds

For Release-mode expectations, see `src/debug/tests/debug_matrix.md`.
