# AGENTS.md

## Repo Purpose

This repo is an idiomatic Zig port of the local `tomlc17` C library:

- Reference source: `/Users/tarandr/src/tries/2026-04-03-tomlc17`
- Goal: TOML v1.1 parser compliance in Zig, with an allocator-backed public API and `toml-test` coverage

The current implementation is intentionally incomplete but bootstrapped and runnable.

## Important Files

- `src/root.zig`: public API and local tests
- `src/parser.zig`: document/table parsing and table state handling
- `src/scanner.zig`: scalar, string, array, and inline-table scanning/parsing
- `src/datetime.zig`: TOML date/time parsing helpers
- `src/value.zig`: in-memory value tree and TOML-test JSON rendering
- `test/tools/toml_test_decoder.zig`: decoder executable used by the official `toml-test` harness
- `testdata/parser/`: the minimal committed parser golden fixtures used by local tests
- `mise.toml`: tool versions and tasks

## Working Commands

Use the Xcode 26.3 developer dir configured in `mise.toml`.

- `mise install`
- `zig build test`
- `zig build check`
- `zig build toml-test -- testdata/parser/in/1.toml`
- `mise run toml-test`

Notes:

- `zig build` installs the decoder into `zig-out/bin/toml-test-decoder`
- `zig build check` only compiles artifacts; it is not enough for the `toml-test` harness by itself
- `testdata/parser/` is the only committed local fixture set

## Current Status

Verified in this repo:

- `zig build test` passes
- `zig build check` passes
- manual decoder run works on `testdata/upstream/parser/in/1.toml`

Official `toml-test` status from April 5, 2026:

- valid tests: `151 passed`, `63 failed`
- invalid tests: `339 passed`, `127 failed`

## Main Remaining Gaps

1. Parser structural rules

- Array trailing commas/comments
- Current-table resolution for arrays of tables
- Rejecting trailing junk after headers and values
- Relevant code: `src/parser.zig`, `src/scanner.zig`

2. Scalar and datetime compliance

- `inf` / `nan`
- integer underscore validation
- optional-seconds date/time forms
- TOML-test datetime rendering details
- Relevant code: `src/scanner.zig`, `src/datetime.zig`, `src/value.zig`

3. String and escape validation

- invalid escapes
- multiline string edge cases
- illegal newline handling in strings/keys
- Relevant code: `src/scanner.zig`

## Linear Tracking

Linear project:

- `TOML parser in zig`

Linear issues created for continuation:

- `ANT-13` Bootstrap Zig TOML parser port and capture current state
- `ANT-14` Close parser structural gaps in tables, arrays, and line termination
- `ANT-15` Close scalar and datetime compliance gaps
- `ANT-16` Harden string parsing and escape validation

`ANT-13` has a summary comment describing what was completed and the current test counts.

## Practical Guidance For Future Sessions

- Start by running `zig build test` and `mise run toml-test`
- Do not reintroduce the earlier macOS/Xcode debugging workarounds; the current `DEVELOPER_DIR` setup is the working fix
- When changing parser behavior, prefer validating against `toml-test` failure groups rather than adding many one-off local tests first
- Keep the public API idiomatic Zig; do not add a C-compat surface unless explicitly requested
