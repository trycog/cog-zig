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
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/chained_field_access/src/main.zig" --output "/tmp/cog-zig/chained-main.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/nested_factory/src/main.zig" --output "/tmp/cog-zig/nested-main.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/cross_file_import/src/main.zig" --output "/tmp/cog-zig/cross-main.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/cross_file_import/src/model.zig" --output "/tmp/cog-zig/cross-model.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/pointer_optional/src/main.zig" --output "/tmp/cog-zig/pointer-main.scip"
zig-out/bin/cog-zig "$ROOT/src/debug/fixtures/indexing/comptime_generic/src/main.zig" --output "/tmp/cog-zig/comptime-main.scip"

echo "== release build =="
zig build -Doptimize=ReleaseFast

echo "Smoke checks complete."
