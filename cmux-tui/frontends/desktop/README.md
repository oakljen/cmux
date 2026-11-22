# cmux desktop (Windows / Linux)

A [Tauri 2](https://tauri.app) desktop shell around the in-tree web frontend
([`../web`](../web)). It starts a bundled `cmux-tui` server on a random
loopback WebSocket port with a random token, opens the frontend against it
(auto-connect), and stops the server when the window closes.

> Fork of [cmux](https://github.com/manaflow-ai/cmux) by Manaflow, Inc. The web
> frontend, protocol and server are upstream's work; this directory adds only the
> desktop shell. Terminal engine: [Ghostty](https://github.com/ghostty-org/ghostty).
> See [../../docs/ATTRIBUTION-PORT.md](../../docs/ATTRIBUTION-PORT.md).

## What you get

- Workspace sidebar, tab strip, splits and xterm.js terminals (the upstream web UI)
- A native window, one process tree: app -> `cmux-tui server` -> your shells
- Windows 11 (WebView2) and Linux (WebKitGTK)

## Build and run

Prerequisites: Rust 1.95 (see `../rust-toolchain.toml`), Node 20+, and a built
`cmux-tui` (see [../../docs/building-windows-linux.md](../../docs/building-windows-linux.md)).
Linux also needs `libwebkit2gtk-4.1-dev libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev`.

```bash
# 1. Build the TypeScript SDK and the web frontend
(cd ../../bindings/typescript && npm ci && npm run build)
(cd ../web && npm ci && npm run build)

# 2. Build cmux-tui and stage it as the Tauri sidecar
(cd ../.. && cargo build -p cmux-tui --release)
npm ci
npm run prepare-sidecar          # copies target/release (or debug) cmux-tui

# 3. Run a quick debug build, or produce installers
npx tauri build --debug --no-bundle   # src-tauri/target/debug/cmux-desktop[.exe]
npm run build                         # installers under src-tauri/target/release/bundle
```

Set `CMUX_TUI_BIN=/path/to/cmux-tui` to use a different server binary.

## How it behaves

- **Fresh session per launch** (`desktop-<pid>`) with one terminal already open.
  Sessions do not persist across app restarts yet: on Windows the terminal hosts
  behind a restored session are not live (durable terminal hosts are Unix-only).
- **Server lifetime** is tied to the app. A Windows job object (and
  `PR_SET_PDEATHSIG` on Linux) kills the server even if the app is force-killed.
- **Security:** the WebSocket binds `127.0.0.1` only and uses a random per-launch
  token. The token is passed to the server on its command line, so other
  processes of the same user can see it in the process list. The frontend
  receives it in the URL fragment and removes it immediately.

## Status

Verified on Windows 11: window launches, auto-connects, shows a live PowerShell,
renders output, and cleans up on close and on force-kill. Not yet verified:
Linux GUI run, installers/bundles, keyboard input inside the native window
(upstream's web tests cover input), browser surfaces (upstream follow-up).
