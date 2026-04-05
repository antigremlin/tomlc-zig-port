# tomlc-zig-port

An idiomatic Zig bootstrap port of [`tomlc17`](https://github.com/cktan/tomlc17), targeting TOML v1.1 parse compatibility first.

The upstream C reference checkout used during this port lives at:

- `/Users/tarandr/src/tries/2026-04-03-tomlc17`

This repo keeps a minimal committed parser fixture set in `testdata/parser/`, while the full C reference implementation stays external.

## Workflow

Install the non-Zig dependency used for the official test harness:

```bash
mise install
```

Build and run the local Zig tests:

```bash
mise exec zig@latest -- zig build test
```

Build or run the `toml-test` decoder executable:

```bash
mise exec zig@latest -- zig build check
mise exec zig@latest -- zig build toml-test -- path/to/file.toml
```

To run the official [`toml-test`](https://github.com/toml-lang/toml-test) suite after `mise install`:

```bash
go install github.com/toml-lang/toml-test/v2/cmd/toml-test@latest
toml-test test -toml 1.1 -decoder zig-out/bin/toml-test-decoder
```
