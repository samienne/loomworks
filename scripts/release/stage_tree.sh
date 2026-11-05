#!/usr/bin/env bash
# Stage the Lua tree a release executable embeds (spec §16.11) — the ONE
# definition of what is fused into an `lw` executable and what the release
# bundle's `loomworks/` part carries:
#
#   main.lua                                   the host bootstrap
#   boot/**                                    bootstrap modules
#   loomworks/**                               the system Lua (lua/loomworks)
#   loomworks/CHANGELOG.md                     the release notes (spec §16.37)
#   loomworks/protocol/transport.json          the protocol's schema documents
#   loomworks/protocol/{meta,interfaces}/**.json   (spec 19.20; not the frozen
#                                              snapshots), served by Root.schema
#
# The layout is the one the fused-bundle readers expect (release_notice.lua,
# proto/documents.lua, plugin_loader.lua, shim/init.lua).
#
#   stage_tree.sh            # prints the staged directory on stdout
#
# Writes only into a fresh `mktemp -d` directory of its own and prints its path
# (the only line on stdout). The caller removes it when done.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$repo/CHANGELOG.md" ] || { echo "stage_tree.sh: $repo/CHANGELOG.md is missing" >&2; exit 1; }
[ -f "$repo/lua/loomworks/cli.lua" ] || { echo "stage_tree.sh: $repo/lua/loomworks is incomplete" >&2; exit 1; }

stage="$(mktemp -d "${TMPDIR:-/tmp}/lw-stage.XXXXXX")"
ok=0
trap '[ "$ok" = 1 ] || rm -rf "$stage"' EXIT

cp "$repo/lua/main.lua" "$stage/main.lua"
cp -R "$repo/lua/boot" "$stage/boot"
cp -R "$repo/lua/loomworks" "$stage/loomworks"
cp "$repo/CHANGELOG.md" "$stage/loomworks/CHANGELOG.md"

proto="$repo/spec/protocol"
mkdir -p "$stage/loomworks/protocol"
cp "$proto/transport.json" "$stage/loomworks/protocol/transport.json"
( cd "$proto" && find meta interfaces -type f -name '*.json' ) | while IFS= read -r rel; do
  mkdir -p "$stage/loomworks/protocol/$(dirname "$rel")"
  cp "$proto/$rel" "$stage/loomworks/protocol/$rel"
done

ok=1
printf '%s\n' "$stage"
