# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-03-12

### Fixed

- Link libc explicitly in build so `getrusage` resource tracking works on Linux

## [0.1.0] - 2026-03-11

Initial release.

### Added

- SCIP-based code intelligence for Zig (go-to-definition, find references, symbol search)
- Native DWARF debugging support (ptrace on Linux, mach on macOS)
- Auto-discovery of workspace root and package name from `build.zig.zon`
- Structured progress events and optional debug diagnostics (`COG_ZIG_DEBUG=1`)
- Release-based extension installs via `cog ext:install`

[0.1.1]: https://github.com/trycog/cog-zig/releases/tag/v0.1.1
[0.1.0]: https://github.com/trycog/cog-zig/releases/tag/v0.1.0
