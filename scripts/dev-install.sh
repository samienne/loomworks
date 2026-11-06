#!/usr/bin/env bash
# Build a fused-everything lw host from the working tree and install it for the
# current user (dev dogfood / stable local install). The installed binary is a
# FROZEN snapshot of the tree at build time — it does not change as you edit the
# repo; use `lw --dev` to run the live checkout.
#
#   make install            # or: bash scripts/dev-install.sh [extra lw install args]
#
# Re-run to update the installed snapshot to the current tree.
set -euo pipefail
command -v luvi >/dev/null 2>&1 || { echo "luvi not found on PATH"; exit 1; }

repo="$(cd "$(dirname "$0")/.." && pwd)"
# Fuse the tree a release executable embeds (scripts/release/stage_tree.sh:
# main.lua, boot/, the system Lua, the release notes and the protocol's schema
# documents), so `lw release-notes` and Root.schema work in a dev build too.
# The trap is set before either temp dir exists, so a failure after the first
# one (e.g. the second mktemp) still removes it; each is removed only when set.
src="" out_dir=""
trap 'if [ -n "$src" ]; then rm -rf "$src"; fi; if [ -n "$out_dir" ]; then rm -rf "$out_dir"; fi' EXIT
src="$(bash "$repo/scripts/release/stage_tree.sh")"
out_dir="$(mktemp -d)"
out="$out_dir/lw"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    out="$out_dir/lw.exe"
    luvi "$(cygpath -w "$src")" --output "$(cygpath -w "$out")" ;;
  *)
    luvi "$src" --output "$out" ;;
esac

# Install the freshly-fused host (skip the release-bundle fetch: it's fused).
# `-y`: `make install` IS the request to replace the installed lw, so don't ask
# the "replace existing binary?" question `lw install` otherwise asks.
"$out" install -y --no-bundle "$@"

echo
echo "This is a development build: \`lw self-update\` never replaces it (re-run"
echo "\`make install\` instead); it always runs its own embedded code, never an"
echo "installed release bundle. It carries the release key, so"
echo "\`lw bootstrap install --version <x.y.z>\` and \`lw bootstrap upgrade\` work against real releases."
echo
echo "Point --dev at this checkout (once):"
echo "  lw settings set dev-lua $repo/lua"
