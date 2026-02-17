# Logging Controls

`cog-zig` defaults to quiet operation so extension invocations do not pollute
stderr/stdout in successful runs.

## Enable verbose logs

Set:

```bash
COG_ZIG_DEBUG=1
```

When set, wrapper and indexer logs are emitted using `std.log`.

## Operational guidance

- Keep `COG_ZIG_DEBUG` unset for normal Cog indexing
- Enable only for local troubleshooting
- Treat warning-heavy logs as analyzer parity signals, not hard failures
