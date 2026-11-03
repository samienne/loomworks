# loomworks

The editor-independent core of loomworks: the `lw` command-line tool and the
workspace daemon. loomworks turns a project's build variants into resolved,
buildable profiles and drives configure, build, run, test and clean through
one consistent interface.

The Neovim integration lives in
[loomworks.nvim](https://github.com/samienne/loomworks.nvim), which talks to
this daemon over its protocol.

**Status:** work in progress. The code is being moved here from
loomworks.nvim.

## Layout

Imported from loomworks.nvim at commit e9a5785b (no history).

| Path | Contents |
|---|---|
| `lua/main.lua`, `lua/boot/` | `lw` entry point, launcher, version pin, self-update, release verification |
| `lua/loomworks/` | CLI (`cli*.lua`), workspace model, domain objects, build/test planning |
| `lua/loomworks/daemon/` | the workspace daemon (server, services, views) |
| `lua/loomworks/proto/` | protocol code shared with clients (framing, schemas, conformance) |
| `lua/loomworks/modules/`, `sdks/`, `remote/`, `progress/`, `test_units/`, `integrations/inventory/` | build-system modules, SDKs, device execution, progress parsers, test units, tool inventory |
| `lua/loomworks/shim/` | the `vim.*` shim the standalone `lw` runs on |
| `spec/protocol/` | wire protocol (`PROTOCOL.md`, `API.md`), interface schemas, transcripts |
| `specification.md`, `spec/` | behavioural specification (index in `specification.md`) |
| `ARCHITECTURE.md`, `DAEMON.md` | implementation architecture and daemon roadmap |
| `bin/` | development launchers (`bin/lw`, `bin/lw.cmd`) |
| `scripts/release/`, `keys/` | release build and signing tooling (public key only) |
| `scripts/ci/`, `scripts/conformance.lua` | CI end-to-end scripts and protocol conformance |
| `tests/` | spec files (`make test`), standalone suite (`make test-standalone`) |

Some modules here are still shared with the Neovim plugin and are copied
for now (`loomworks` (init), `views`, `overseer`, `debug`, `workspace_view`,
`daemon/remote_task`, `provision/sha256`); they are to be decoupled.

Tests run in headless Neovim with plenary.nvim (`make test`); the standalone
suite needs `luvi` on `PATH`.
