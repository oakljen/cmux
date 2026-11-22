# Attribution

This is a fork of **cmux** by **Manaflow, Inc.** (https://github.com/manaflow-ai/cmux,
https://cmux.com). All of the cmux code, design and architecture, including the
`cmux-tui` Rust multiplexer this port builds on, are the work of Manaflow and the
cmux contributors. Copyright (c) 2024-present Manaflow, Inc., with other
contributors and third parties retaining copyright in their material.

The terminal engine is **Ghostty** (https://github.com/ghostty-org/ghostty) by
Mitchell Hashimoto and the Ghostty contributors, consumed here through
Manaflow's `ghostty` submodule (https://github.com/manaflow-ai/ghostty) and
`libghostty-vt`.

## What this fork changes

Only Windows/Linux build and portability work: build documentation and scripts,
and test-portability fixes. See `docs/building-windows-linux.md`.

## License

Unchanged from upstream. Material is licensed under GPL-3.0-or-later (see the
root `LICENSE`). Directories carrying their own BUSL-1.1 `LICENSE` (`web/`,
`workers/ci-artifacts/`, `workers/iroh-v2/`, `workers/presence/`,
`services/iroh-relay-minter/`, `cmux-tui/relays/cloudflare-do/`) remain under
that license and are untouched. See `THIRD_PARTY_LICENSES.md` for third-party
notices. This fork is not affiliated with or endorsed by Manaflow.
