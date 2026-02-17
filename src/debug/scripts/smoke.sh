#!/usr/bin/env bash
set -euo pipefail

echo "== zig version =="
zig version

echo "== build =="
zig build

echo "== test =="
zig build test

echo "== indexing fixture smoke =="
mkdir -p /tmp/cog-zig
ROOT="$(pwd)"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/chained_field_access" --output "/tmp/cog-zig/chained.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/nested_factory" --output "/tmp/cog-zig/nested.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/cross_file_import" --output "/tmp/cog-zig/cross.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/pointer_optional" --output "/tmp/cog-zig/pointer.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/comptime_generic" --output "/tmp/cog-zig/comptime.scip"

echo "== release build =="
zig build -Doptimize=ReleaseFast

echo "Smoke checks complete."
