# Building cmux-tui on Windows and Linux

> Fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) by Manaflow, Inc. See [ATTRIBUTION-PORT.md](ATTRIBUTION-PORT.md).

`cmux-tui` is the cross-platform Rust multiplexer in this repo. It builds and
runs on Linux and Windows 10/11. (The Swift macOS app does not; use cmux-tui.)

## Requirements

| Tool | Version | Notes |
| --- | --- | --- |
| Rust | 1.95.0 | pinned by `rust-toolchain.toml`; rustup installs it automatically |
| Zig | 0.16.0 | builds `libghostty-vt.a` from the `ghostty` submodule |
| libclang | any recent | needed by `bindgen` in `ghostty-vt-sys` |
| C toolchain | MSVC (Windows) / gcc (Linux) | VS 2022 Build Tools on Windows |

Initialise the submodule first: `git submodule update --init --depth 1 ghostty`
(from the repository root).

## Linux

```bash
sudo apt-get install -y build-essential libclang-dev pkg-config unzip
# install Rust (rustup) and Zig 0.16.0, put zig on PATH
cd cmux-tui && cargo build -p cmux-tui
```

Or run `scripts/build-linux.sh`, which does the above for Debian/Ubuntu.

## Windows

Run `scripts\build-windows.ps1` (PowerShell 7 or Windows PowerShell). It
installs Zig and libclang into a local toolchain directory (default
`%USERPROFILE%\cmux-toolchains`) without touching system PATH, then builds.

Manual equivalent:

```powershell
$env:PATH = "$env:USERPROFILE\.cargo\bin;<zig dir>;$env:PATH"
$env:LIBCLANG_PATH = "<dir containing libclang.dll>"   # e.g. from `pip install libclang`
cd cmux-tui; cargo build -p cmux-tui
```

Windows specifics:

- Terminals run through ConPTY (`portable-pty`); the default shell is `pwsh.exe`.
- The control socket is AF_UNIX (via `uds_windows`) under `%TEMP%\cmux-tui-<user>\`.
  Socket paths must fit `SUN_LEN` (about 108 chars), so keep session names short.
- `machine-agent` is Unix-only.
- `server start` runs in the foreground. Background it yourself.

## Smoke test

```bash
cmux-tui server start --session demo &          # foreground process
cmux-tui --session demo --json server status
cmux-tui --session demo --json tab create terminal      # note terminal_id
cmux-tui --session demo terminal <terminal_id> write --text $'echo hi\r'
cmux-tui --session demo terminal <terminal_id> screen read
cmux-tui --session demo server stop
```

## Test status (baseline, `cargo test -p cmux-pty -p cmux-tui-core`)

**Linux (WSL Ubuntu 24.04, running as root):** 1567 passed, 2 failed.

- `workspace_registry::tests::reset_errors_when_state_root_cannot_be_inspected`
  fails only when run as root (chmod 000 does not block root). Passes as a normal user.
- `mux::tests::durable_workspace_creation_supports_the_in_process_terminal_runtime`
  is flaky under parallel runs (passes alone 3/3).

**Windows:** the suite compiles; lib tests 1290 passed / 33 failed (before the
small fixes in this branch). Failures are almost all test-fixture portability, not
product bugs:

- ~25 tests spawn `/bin/sh`, `/bin/cat`, `/usr/bin/true` (CreateProcessW fails;
  hook validation also rejects `/bin/...` as not absolute). Need a portable
  helper or `#[cfg(unix)]`.
- A few tests delete their temp dir while a SQLite handle is still open
  (Windows error 32). Several fixed here with `drop(...)`; at least
  `mux::tests::persistent_workspace_registry_recovers_exact_identity_order_and_revision`
  still fails and may point at a handle held inside `Mux`.
- `serve_paused_creates_missing_explicit_socket_parent` and
  `shutting_down_a_writer_clone_unblocks_the_reader` hit `SUN_LEN`/socket
  shutdown semantics on Windows.
- `websocket_transport::websocket_non_loopback_bind_requires_and_accepts_explicit_insecure_opt_in`
  hangs >60 s on Windows. Run integration tests with a timeout.
- Not yet verified on Windows: browser tabs (CDP), agent hooks, remote/relay, the
  interactive TUI in a real console.
