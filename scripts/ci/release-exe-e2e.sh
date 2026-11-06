#!/usr/bin/env bash
# Release executables end-to-end (spec §16.11): the release scripts fuse the
# full tree into `lw`, and the publish gate refuses a host asset that does not
# carry it.
#
#   bash scripts/ci/release-exe-e2e.sh <luvi_binary>
#
# Fuses a release executable with the TEST key (scripts/release/fuse_host.sh),
# smoke-tests it (scripts/release/smoke_exe.sh), builds the bundle and the
# descriptor from it, then stages a draft signed with the TEST key and runs
# scripts/release/verify_draft.sh on it — once as built (accepted) and once with
# a bootstrap-only host asset (main.lua + boot/ only, as releases before
# self-contained executables shipped; refused). Hermetic: no network; per-user
# dirs are sandboxed. Needs python3, openssl and sha256sum or shasum.
set -u

luvi="${1:?usage: release-exe-e2e.sh <luvi>}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fx="$repo/tests/fixtures/dist"
rel="$repo/scripts/release"
ver="0.0.0-test"

PASS=0; FAIL=0
ok()  { printf '  ok  : %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export LOCALAPPDATA="$T/home" XDG_DATA_HOME="$T/home" APPDATA="$T/home" XDG_CONFIG_HOME="$T/home" HOME="$T/home"
unset LOOMWORKS_LUA LOOMWORKS_PINNED LOOMWORKS_LW LOOMWORKS_CHANNEL LOOMWORKS_RELEASE_URL
mkdir -p "$T/home"

has_entry() {  # <zip-or-exe> <entry>
  python3 -c 'import sys, zipfile; sys.exit(0 if sys.argv[2] in zipfile.ZipFile(sys.argv[1]).namelist() else 1)' "$1" "$2"
}

tree_state() { git -C "$repo" status --porcelain --ignored --untracked-files=all 2>/dev/null; }
state_before="$(tree_state)"

echo "=== stage_tree.sh stages the full tree into its own directory ==="
stage="$(bash "$rel/stage_tree.sh")" || { echo "stage_tree.sh failed" >&2; exit 1; }
case "$stage" in "$repo"*) bad "staged inside the repository: $stage" ;; *) ok "staged outside the repository" ;; esac
for f in main.lua boot/verify.lua loomworks/cli.lua loomworks/CHANGELOG.md \
         loomworks/protocol/transport.json; do
  [ -f "$stage/$f" ] && ok "staged $f" || bad "missing $f"
done
[ -n "$(find "$stage/loomworks/protocol/interfaces" -name '*.json' 2>/dev/null)" ] \
  && ok "staged the interface schemas" || bad "no interface schemas staged"
[ ! -e "$stage/loomworks/protocol/frozen" ] && ok "frozen snapshots not staged" || bad "frozen snapshots staged"
rm -rf "$stage"
[ "$(tree_state)" = "$state_before" ] && ok "nothing written into the checkout" || bad "the checkout changed"

# Only tracked files are staged: a dirty checkout's stray files and symlinks
# must never be fused (make dist / dev-install). In a throwaway clone running
# this checkout's stage_tree.sh.
echo "=== stage_tree.sh stages tracked files only ==="
cl="$T/clone"
git clone --quiet --no-hardlinks "$repo" "$cl" || { echo "clone failed" >&2; exit 1; }
cp "$rel/stage_tree.sh" "$cl/scripts/release/stage_tree.sh"
printf 'stray\n' > "$cl/lua/loomworks/zz_untracked_stray.lua"
mkdir -p "$cl/lua/loomworks/zz_untracked_dir"
printf 'stray\n' > "$cl/lua/loomworks/zz_untracked_dir/x.lua"
printf 'target\n' > "$T/link-target.lua"
# A real symlink where the platform allows one (Git Bash otherwise copies).
MSYS=winsymlinks:nativestrict ln -s "$T/link-target.lua" "$cl/lua/loomworks/zz_untracked_link.lua" 2>/dev/null \
  || ln -s "$T/link-target.lua" "$cl/lua/loomworks/zz_untracked_link.lua"
printf '{}\n' > "$cl/spec/protocol/interfaces/zz_untracked.json"
cstage="$(bash "$cl/scripts/release/stage_tree.sh")" || { echo "stage_tree.sh (clone) failed" >&2; exit 1; }
for f in loomworks/zz_untracked_stray.lua loomworks/zz_untracked_dir loomworks/zz_untracked_link.lua \
         loomworks/protocol/interfaces/zz_untracked.json; do
  [ ! -e "$cstage/$f" ] && [ ! -L "$cstage/$f" ] && ok "untracked $f not staged" || bad "untracked $f staged"
done
[ -f "$cstage/loomworks/cli.lua" ] && ok "tracked files still staged" || bad "tracked cli.lua missing"
[ -z "$(find "$cstage" -type l)" ] && ok "no symlinks staged" || bad "symlinks staged"
[ -n "$cstage" ] && rm -rf "$cstage"

echo "=== a release executable carries the full tree ==="
D="$T/dist"; mkdir -p "$D"
host="$D/lw-linux-x86_64"
bash "$rel/fuse_host.sh" "$luvi" "$fx/test_ec_pub.pem" "$host" "$ver" >/dev/null \
  || { echo "fuse_host.sh failed" >&2; exit 1; }
for f in main.lua boot/verify.lua loomworks/cli.lua loomworks/CHANGELOG.md loomworks/protocol/transport.json; do
  has_entry "$host" "$f" && ok "executable contains $f" || bad "executable lacks $f"
done

echo "=== the executable is self-contained ==="
bash "$rel/smoke_exe.sh" "$host" "$ver" && ok "smoke_exe.sh passes" || bad "smoke_exe.sh failed"

echo "=== a bootstrap-only host fails the smoke test ==="
boot="$T/bootonly"; mkdir -p "$boot"
cp "$repo/lua/main.lua" "$boot/main.lua"; cp -R "$repo/lua/boot" "$boot/boot"
old="$T/old-host"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) old="$T/old-host.exe"
    "$luvi" "$(cygpath -w "$boot")" --output "$(cygpath -w "$old")" >/dev/null ;;
  *) "$luvi" "$boot" --output "$old" >/dev/null ;;
esac
has_entry "$old" loomworks/cli.lua && bad "bootstrap-only fixture carries cli.lua" || ok "bootstrap-only fixture lacks cli.lua"
bash "$rel/smoke_exe.sh" "$old" "$ver" >/dev/null 2>&1 && bad "smoke_exe.sh accepted a bootstrap-only host" \
  || ok "smoke_exe.sh refuses a bootstrap-only host"

echo "=== bundle and descriptor ==="
bash "$rel/build_bundle.sh" "$ver" "$D" "$fx/test_ec_priv.pem" >/dev/null && ok "bundle built" || bad "build_bundle.sh failed"
bash "$rel/descriptor.sh" "$ver" "$D" "$host" && ok "descriptor from the executable alone" || bad "descriptor.sh failed"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
sign_draft() {  # <dir>
  ( cd "$1" && for f in *; do
      case "$f" in SHA256SUMS|SHA256SUMS.sig) ;; *) printf '%s  %s\n' "$(sha_of "$f")" "$f" ;; esac
    done > SHA256SUMS )
  openssl dgst -sha256 -sign "$fx/test_ec_priv.pem" -out "$1/SHA256SUMS.sig" "$1/SHA256SUMS"
}

echo "=== the publish gate accepts self-contained host assets ==="
cp "$host" "$D/lw-macos-arm64"; cp "$host" "$D/lw-windows-x86_64.exe"
sign_draft "$D"
bash "$rel/verify_draft.sh" "$ver" "$D" "$fx/test_ec_pub.pem" >/dev/null 2>&1 \
  && ok "verify_draft.sh accepts the draft" || bad "verify_draft.sh refused a good draft"

echo "=== the publish gate refuses a host asset without loomworks/cli.lua ==="
cp "$old" "$D/lw-macos-arm64"
sign_draft "$D"
out="$(bash "$rel/verify_draft.sh" "$ver" "$D" "$fx/test_ec_pub.pem" 2>&1)"; code=$?
[ $code -ne 0 ] && ok "verify_draft.sh exits non-zero" || bad "verify_draft.sh accepted a bootstrap-only host asset"
case "$out" in *"lw-macos-arm64"*"loomworks/cli.lua"*) ok "names the asset and the missing entry" ;; *) bad "unexpected message: $out" ;; esac

echo
echo "release executables e2e: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
