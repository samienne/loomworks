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
# Only files TRACKED by git are staged (`git ls-files`; their working-copy
# content), so a dirty checkout never fuses stray untracked files. A tracked
# symlink is refused. The tree must be a git checkout whose top level is this
# repository: anywhere else this fails rather than guessing what to stage.
#
# Writes only into a fresh `mktemp -d` directory of its own and prints its path
# (the only line on stdout). The caller removes it when done.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$repo/CHANGELOG.md" ] || { echo "stage_tree.sh: $repo/CHANGELOG.md is missing" >&2; exit 1; }
[ -f "$repo/lua/loomworks/cli.lua" ] || { echo "stage_tree.sh: $repo/lua/loomworks is incomplete" >&2; exit 1; }

cdup="$(git -C "$repo" rev-parse --show-cdup 2>/dev/null)" \
  || { echo "stage_tree.sh: $repo is not a git checkout (only tracked files are staged)" >&2; exit 1; }
[ -z "$cdup" ] || { echo "stage_tree.sh: $repo is not the top level of its git checkout" >&2; exit 1; }

# The trap always removes the temp file list, and the stage unless completed;
# each only once its variable holds what its own mktemp created.
stage="" list=""
ok=0
trap 'if [ -n "$list" ]; then rm -f "$list"; fi; if [ "$ok" != 1 ] && [ -n "$stage" ]; then rm -rf "$stage"; fi' EXIT
stage="$(mktemp -d "${TMPDIR:-/tmp}/lw-stage.XXXXXX")"
list="$(mktemp "${TMPDIR:-/tmp}/lw-stage-list.XXXXXX")"

# stage <pathspec> <strip-prefix> <dest-dir> [<suffix>]: copy every tracked
# regular file under <pathspec> (ending in <suffix>, if given) to
# <dest-dir>/<path without strip-prefix>. Refuses a tracked symlink, and a
# tracked file missing from the working copy.
stage() {
  local spec="$1" strip="$2" dest="$3" suffix="${4:-}" n=0 meta mode path rel
  local entries=()
  git -C "$repo" ls-files -z -s -- "$spec" > "$list"
  while IFS= read -r -d '' meta; do entries+=("$meta"); done < "$list"
  : > "$list"
  # Builtins only per file (process creation is slow on Windows); the copy is
  # one tar pipe per call.
  for meta in ${entries[@]+"${entries[@]}"}; do
    mode="${meta%% *}"; path="${meta#*$'\t'}"
    case "$path" in *"$suffix") ;; *) continue ;; esac
    if [ "$mode" = 120000 ] || [ -L "$repo/$path" ]; then
      echo "stage_tree.sh: refusing the tracked symlink $path" >&2; exit 1
    fi
    [ -f "$repo/$path" ] || { echo "stage_tree.sh: tracked $path is not a regular file in the working copy" >&2; exit 1; }
    rel="${path#"$strip"}"
    printf '%s\0' "$rel" >> "$list"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "stage_tree.sh: nothing tracked under $spec" >&2; exit 1; }
  mkdir -p "$dest"
  (cd "$repo/$strip" && tar -cf - --no-recursion --null -T "$list") | (cd "$dest" && tar -xf -)
}

stage lua/main.lua lua/ "$stage"
stage lua/boot lua/ "$stage"
stage lua/loomworks lua/ "$stage"
stage CHANGELOG.md "" "$stage/loomworks"

proto="spec/protocol/"
stage "${proto}transport.json" "$proto" "$stage/loomworks/protocol"
stage "${proto}meta" "$proto" "$stage/loomworks/protocol" .json
stage "${proto}interfaces" "$proto" "$stage/loomworks/protocol" .json

ok=1
printf '%s\n' "$stage"
