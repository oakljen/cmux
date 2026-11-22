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

## Windows toolchain note

Zig 0.16 (pinned by Ghostty) bundles a clang that the newest MSVC STL (14.52, VS
2026) rejects with `STL1000: Unexpected compiler version, expected Clang 22 or
newer`. Use Visual Studio 2022 Build Tools (MSVC 14.4x). CI pins `windows-2022`
for this reason.

## Test status (`cargo test -p cmux-pty -p cmux-tui-core`)

**Windows 11:** all suites pass: lib 1303, `browser_runtime` 9, `pty` 3,
`websocket_transport` 7 passed, 0 failed. Tests that cannot run on Windows are
`#[cfg_attr(windows, ignore = "<reason>")]` so they stay visible:

- 52 tests that spawn POSIX `/bin/sh`, `/bin/cat`, `/usr/bin/true` or assert POSIX
  paths (`pty`, `color_ownership`, `websocket_transport`, and parts of the lib).
- 3 `mux` tests of durable terminal-host lifecycle, which is Unix-only: after a
  restart, terminals of a restored session are not live on Windows. This is a
  real feature gap, not just a test issue.
- `websocket_non_loopback_bind_requires_and_accepts_explicit_insecure_opt_in`
  binds `0.0.0.0` and hangs on Windows (likely Windows Firewall); not investigated.
- Occasionally flaky on Windows: `browser::tests::stalled_surface_route_does_not_block_shared_cdp_reader`.
- On the slow hosted GitHub Windows runner, five timing-sensitive tests (four CDP
  `browser` tests and `journal_ingress::...producer_deadline_includes_workspace_registry_mutex_admission`)
  miss their deadlines though they pass locally; the Windows CI job skips them.

**Linux (WSL Ubuntu 24.04, as root):** 1567 passed, 2 failed.

- `workspace_registry::tests::reset_errors_when_state_root_cannot_be_inspected`
  fails only as root (chmod 000 does not block root); passes as a normal user.
- `mux::tests::durable_workspace_creation_supports_the_in_process_terminal_runtime`
  is flaky under parallel runs (passes alone).
- Under heavy load a few journal-timing tests can fail and then pass on rerun.

**Manually verified on Windows 11** (Windows Terminal, pwsh): interactive TUI
rendering, mouse, `Ctrl-b` prefix chords, `Alt` shortcuts, tabs and splits.
Not yet verified on Windows: browser tabs (CDP), agent hooks, remote/relay.

## Desktop app

A Tauri desktop shell around the web frontend lives in
[`../frontends/desktop`](../frontends/desktop/README.md).
