#!/usr/bin/env bash
# Host self-update end-to-end (spec §16.32): fuse real self-contained
# executables (scripts/release/fuse_host.sh, the full tree) — an "old" one
# (release 0.2.0-rc.1) and a "new" one (release 0.2.0-test) — publish the new
# one in a local mirror with a SHA256SUMS signed by the TEST key and naming the
# release's descriptor (no manifest.json), then let the old one `self-update`
# itself: it replaces only the executable — on Windows this exercises the real
# running-.exe rename-aside dance, which no unit test can — and installs no
# bundle anywhere. Also: a development
# build (no release version) never replaces itself, and a bootstrap-only host
# (transitional, releases before self-contained executables) updates to the
# self-contained executable, and before that, with no bundle, still answers
# version and help (naming self-update, or the launcher in a pinned repo).
#
#   bash scripts/ci/host-self-update-e2e.sh <luvi_binary>
#
# Needs python3 (fuse_host.sh), openssl (to sign the hash list), and
# sha256sum or shasum. Hermetic: no network; data/config dirs are sandboxed.
set -u

luvi="${1:?usage: host-self-update-e2e.sh <luvi>}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fx="$repo/tests/fixtures/dist"
ver="0.2.0-test"   # the "new" executable's release (self-contained)
oldver="0.2.0-rc.1"   # the "old" executable's release (older than $ver)

PASS=0; FAIL=0
ok()  { printf '  ok  : %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  Darwin) os=macos ;;
  *) os=linux ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) arch="$(uname -m)" ;;
esac
case "$os-$arch" in
  linux-x86_64) asset=lw-linux-x86_64 ;;
  macos-arm64) asset=lw-macos-arm64 ;;
  windows-x86_64) asset=lw-windows-x86_64.exe ;;
  *) echo "no host asset for $os/$arch — skipping"; exit 0 ;;
esac
exe_name=lw; [ "$os" = windows ] && exe_name=lw.exe

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$T/install" "$T/mirror" "$T/home" "$T/work"
fuse() { bash "$repo/scripts/release/fuse_host.sh" "$luvi" "$fx/test_ec_pub.pem" "$@" >/dev/null; }
fuse "$T/install/$exe_name" "$oldver" || { echo "fuse (old) failed" >&2; exit 1; }
mkdir -p "$T/devbuild"
fuse "$T/devbuild/$exe_name" || { echo "fuse (dev build) failed" >&2; exit 1; }
fuse "$T/mirror/$asset" "$ver" || { echo "fuse (new) failed" >&2; exit 1; }
cp "$T/install/$exe_name" "$T/old-copy"
cp "$T/mirror/$asset" "$T/new-copy"

# The mirror: the new executable and the signed hash list — no manifest.json
# and no bundle: the newest release is read from the list itself. Like a real
# release, the list names the release's own version-bearing descriptor
# (lw-<ver>-descriptor.json) — the host refuses a list without it (anti-replay).
# `sign_sums <descriptor-version>` forges another release's list (replay test);
# `sign_sums none` leaves the descriptor out.
printf '{"descriptor":1}\n' > "$T/descriptor.json"
sign_sums() {
  local dver="${1:-$ver}"
  ( cd "$T/mirror" && {
      printf '%s  %s\n' "$(sha_of "$asset")" "$asset"
      [ "$dver" = none ] || printf '%s  %s\n' "$(sha_of "$T/descriptor.json")" "lw-$dver-descriptor.json"
    } > SHA256SUMS )
  openssl dgst -sha256 -sign "$fx/test_ec_priv.pem" -out "$T/mirror/SHA256SUMS.sig" "$T/mirror/SHA256SUMS"
}
sign_sums

# Sandbox every per-user dir; point the release source at the mirror.
export LOCALAPPDATA="$T/home" XDG_DATA_HOME="$T/home" APPDATA="$T/home" XDG_CONFIG_HOME="$T/home"
export LOOMWORKS_RELEASE_URL="$T/mirror"
[ "$os" = windows ] && export LOOMWORKS_RELEASE_URL="$(cygpath -m "$T/mirror")"
unset LOOMWORKS_LUA LOOMWORKS_PINNED LOOMWORKS_LW LOOMWORKS_CHANNEL
# The retired install folder (spec §16.22): set to a folder holding a decoy
# bundle, it must be ignored and left exactly as it is.
mkdir -p "$T/instdecoy/lua-9.9.9/loomworks"
printf 'error("the decoy bundle ran")\n' > "$T/instdecoy/lua-9.9.9/loomworks/cli.lua"
export LOOMWORKS_INSTALL_DIR="$T/instdecoy"
[ "$os" = windows ] && export LOOMWORKS_INSTALL_DIR="$(cygpath -m "$T/instdecoy")"
decoy_before="$(cd "$T/instdecoy" && find . | sort)"
no_bundles() {  # nothing named lua-* in the data dir, the install dir or the mirror
  [ -z "$(find "$T/home" "$T/install" "$T/mirror" -name 'lua-*' 2>/dev/null)" ]
}
cd "$T/work"
lw="$T/install/$exe_name"

echo "=== the old executable reports its release, self-contained ==="
out="$("$lw" version 2>&1)"; echo "$out"
case "$out" in *"host: $oldver "*"(self-contained)"*) ok "reports self-contained release $oldver" ;; *) bad "unexpected version: $out" ;; esac

# Help needs no bundle: the executable carries the CLI (spec §16.7, §16.11).
echo "=== help works with no bundle installed ==="
for h in "help" "--help" "-h" "install --help" "help self-update" "build --help"; do
  # shellcheck disable=SC2086
  out="$("$lw" $h 2>&1)"; code=$?
  [ $code -eq 0 ] && ok "lw $h exits 0" || bad "lw $h exit $code: $out"
  case "$out" in *"no loomworks release is installed"*|*"Full help needs"*) bad "lw $h: asks for a bundle: $out" ;; esac
done
out="$("$lw" install --help 2>&1)"
case "$out" in *"lw install [-y]"*"--dry-run"*) ok "install --help: install's own help" ;; *) bad "install --help: $out" ;; esac
[ ! -e "$T/home/Microsoft" ] && [ ! -e "$T/home/.local/bin" ] && ok "install --help installed nothing" || bad "install --help installed something"

echo "=== self-update --no-host is a usage error ==="
out="$("$lw" self-update --no-host 2>&1)"; code=$?; echo "$out"
[ $code -eq 2 ] && ok "--no-host exits 2" || bad "--no-host exit $code"
case "$out" in *"replaces only the"*) ok "--no-host: says self-update replaces only the executable" ;; *) bad "--no-host message: $out" ;; esac
cmp -s "$lw" "$T/old-copy" && ok "--no-host: host binary unchanged" || bad "--no-host changed the host"

# `--help` on a host command is left to the CLI's help dispatcher — it must never
# perform the operation. (The help text itself is covered by
# tests/cli_subcommand_help_spec.lua.)
echo "=== self-update --help updates nothing ==="
out="$("$lw" self-update --help 2>&1)"; echo "$out" | head -3
case "$out" in *"checking for updates"*) bad "--help ran an update" ;; *) ok "--help ran no update" ;; esac
cmp -s "$lw" "$T/old-copy" && ok "--help: host binary unchanged" || bad "--help changed the host"

echo "=== self-update replaces the running host ==="
out="$("$lw" self-update 2>&1)"; code=$?; echo "$out"
[ $code -eq 0 ] && ok "self-update exits 0" || bad "self-update exit $code"
case "$out" in *"latest release: $ver"*) ok "newest release read from the signed SHA256SUMS (no manifest.json)" ;; *) bad "latest release not named" ;; esac
case "$out" in *"updated lw $oldver -> $ver"*) ok "reports the executable replacement" ;; *) bad "no replacement reported" ;; esac
case "$out" in *LOOMWORKS_INSTALL_DIR*) bad "mentions the retired install folder" ;; *) ok "no install-folder message" ;; esac
no_bundles && ok "no lua-* created anywhere" || bad "a bundle was installed"
[ "$(cd "$T/instdecoy" && find . | sort)" = "$decoy_before" ] && ok "LOOMWORKS_INSTALL_DIR ignored and untouched" || bad "the install folder changed"
cmp -s "$lw" "$T/mirror/$asset" && ok "installed binary is the verified new host" || bad "installed binary differs from the release asset"
if [ "$os" = windows ]; then
  [ -f "$lw.old" ] && ok "windows: running exe was renamed aside to .old" || bad "windows: no .old after swap"
fi

echo "=== new host reports its release; .old is cleaned up ==="
out="$("$lw" version 2>&1)"; echo "$out"
case "$out" in *"host: $ver "*"(self-contained)"*) ok "new executable reports self-contained $ver" ;; *) bad "unexpected version: $out" ;; esac
[ ! -e "$lw.old" ] && ok "no .old leftover after the next start" || bad ".old still present"

echo "=== second self-update is a no-op for the host ==="
out="$("$lw" self-update 2>&1)"; code=$?; echo "$out"
[ $code -eq 0 ] && ok "exits 0" || bad "exit $code"
case "$out" in *"already up to date ($ver)"*) ok "already up to date" ;; *) bad "not reported current" ;; esac

echo "=== an older --version without --force is skipped ==="
cp "$lw" "$T/cur-copy"
out="$("$lw" self-update --version "$oldver" 2>&1)"; code=$?; echo "$out"
[ $code -eq 0 ] && ok "exits 0" || bad "exit $code"
case "$out" in *"not downgrading"*) ok "says it does not downgrade" ;; *) bad "no downgrade note" ;; esac
cmp -s "$lw" "$T/cur-copy" && ok "executable unchanged" || bad "downgraded without --force"

echo "=== a development build (no release version) never replaces itself ==="
cp "$T/devbuild/$exe_name" "$T/devbuild/copy"
out="$("$T/devbuild/$exe_name" version 2>&1)"; echo "$out"
case "$out" in *"dev build"*) ok "reports a dev build" ;; *) bad "dev build version line: $out" ;; esac
out="$("$T/devbuild/$exe_name" self-update 2>&1)"; echo "$out"
cmp -s "$T/devbuild/$exe_name" "$T/devbuild/copy" && ok "dev build left unchanged" || bad "self-update replaced a dev build"
out="$("$T/devbuild/$exe_name" self-update --force 2>&1)"; echo "$out"
cmp -s "$T/devbuild/$exe_name" "$T/devbuild/copy" && ok "dev build left unchanged by --force" || bad "self-update --force replaced a dev build"

# Transitional: a bootstrap-only host (main.lua + boot/ only, as releases
# before self-contained executables) updates to the self-contained executable.
# Without system Lua (no bundle installed) it is also the only host that still
# takes the host's no-bundle paths: version, help, the pinned-repo hint.
echo "=== a bootstrap-only host with no bundle: version and help ==="
mkdir -p "$T/bootstage" "$T/bootonly" "$T/unversioned"
cp "$repo/lua/main.lua" "$T/bootstage/main.lua"; cp -R "$repo/lua/boot" "$T/bootstage/boot"
fuse_dir() {  # <dir> <out>: fuse a directory as-is (not the full tree)
  if [ "$os" = windows ]; then
    "$luvi" "$(cygpath -w "$1")" --output "$(cygpath -w "$2")" >/dev/null
  else
    "$luvi" "$1" --output "$2" >/dev/null
  fi
}
# With the checkout's boot/verify.lua (no release version): a release host from
# before version identity, which never guesses one.
fuse_dir "$T/bootstage" "$T/unversioned/$exe_name"
out="$("$T/unversioned/$exe_name" version 2>&1)"; echo "$out"
case "$out" in *"host: unknown release"*) ok "unversioned bootstrap-only host reports an unknown release" ;; *) bad "unexpected version: $out" ;; esac
# Its boot/verify.lua from the old executable: the TEST key, release $oldver.
python3 -c 'import sys, zipfile; open(sys.argv[2], "wb").write(zipfile.ZipFile(sys.argv[1]).read("boot/verify.lua"))' \
  "$T/old-copy" "$T/bootstage/boot/verify.lua"
fuse_dir "$T/bootstage" "$T/bootonly/$exe_name"
bl="$T/bootonly/$exe_name"
# The version line must not claim a bundle (every other command says "no
# loomworks release is installed").
out="$("$bl" version 2>&1)"; echo "$out"
case "$out" in *"host: $oldver (v"*) ok "bootstrap-only host reports release $oldver" ;; *) bad "unexpected version: $out" ;; esac
case "$out" in *"bundle: none installed (run \`lw self-update\`)"*) ok "no bundle: version says none installed" ;; *) bad "no-bundle version line: $out" ;; esac
# Help must work before any bundle exists — it is how a user learns what
# install / self-update do (spec §16.7).
for h in "help" "--help" "-h" "install --help" "help self-update" "build --help"; do
  # shellcheck disable=SC2086
  out="$("$bl" $h 2>&1)"; code=$?
  [ $code -eq 0 ] && ok "bootstrap-only lw $h exits 0" || bad "bootstrap-only lw $h exit $code: $out"
  case "$out" in *"no loomworks release is installed"*) bad "bootstrap-only lw $h: bundle error instead of help" ;; esac
  # A host command's help is its complete help (no "needs the bundle" note);
  # the usage and a bundle command's help name self-update.
  case "$h" in
    "install --help"|"help self-update")
      case "$out" in *"Full help needs"*) bad "bootstrap-only lw $h: host-command help carries the bundle note: $out" ;; *) ok "bootstrap-only lw $h: complete, no bundle note" ;; esac ;;
    *)
      case "$out" in *"run \`lw self-update\`"*) ok "bootstrap-only lw $h: names self-update" ;; *) bad "bootstrap-only lw $h: no self-update hint: $out" ;; esac ;;
  esac
done
# Inside a pinned repository the note names the launcher, not self-update.
mkdir -p "$T/pinned-repo"; printf 'version = 0.0.0-test\n' > "$T/pinned-repo/lw.pin"
out="$(cd "$T/pinned-repo" && LW_ROOT= "$bl" help build 2>&1)"
case "$out" in *"./lw.sh help <command>"*) ok "pinned repo: bootstrap-only help names the launcher" ;; *) bad "pinned repo help: $out" ;; esac
[ ! -e "$T/home/loomworks/pinned" ] && [ -z "$(ls -d "$T/home/loomworks/lua-"* 2>/dev/null)" ] \
  && ok "version and help installed nothing" || bad "version or help installed something"

echo "=== a bootstrap-only host updates to the self-contained executable ==="
out="$("$bl" self-update 2>&1)"; code=$?; echo "$out"
[ $code -eq 0 ] && ok "exits 0" || bad "exit $code"
cmp -s "$T/bootonly/$exe_name" "$T/mirror/$asset" && ok "replaced by the verified self-contained executable" || bad "bootstrap-only host not replaced"
out="$("$T/bootonly/$exe_name" version 2>&1)"; echo "$out"
case "$out" in *"host: $ver "*"(self-contained)"*) ok "now self-contained $ver" ;; *) bad "unexpected version: $out" ;; esac

echo "=== a replayed hash list (another release's, validly signed) is refused ==="
cp "$T/old-copy" "$lw"
sign_sums 0.2.0-older
out="$("$lw" self-update --version "$ver" 2>&1)"; code=$?; echo "$out"
[ $code -ne 0 ] && ok "replayed list exits non-zero" || bad "replayed list accepted (exit 0)"
case "$out" in *"lw-$ver-descriptor.json"*) ok "names the missing descriptor" ;; *) bad "replay error: $out" ;; esac
cmp -s "$lw" "$T/old-copy" && ok "original host untouched" || bad "host changed despite a replayed list"

echo "=== a signed list without the descriptor is refused ==="
sign_sums none
out="$("$lw" self-update --version "$ver" 2>&1)"; code=$?; echo "$out"
[ $code -ne 0 ] && ok "integrity error exits non-zero" || bad "accepted a list without the descriptor (exit 0)"
cmp -s "$lw" "$T/old-copy" && ok "original host untouched" || bad "host changed without a descriptor"
out="$("$lw" self-update 2>&1)"; code=$?; echo "$out"
[ $code -ne 0 ] && ok "no descriptor and no manifest.json: no newest release (exit $code)" || bad "resolved a release from nothing"
sign_sums

echo "=== a tampered host asset is refused; the original stays ==="
cp "$T/old-copy" "$lw"
printf 'TAMPER' >> "$T/mirror/$asset"   # hash list (signed) no longer matches
out="$("$lw" self-update 2>&1)"; code=$?; echo "$out"
[ $code -ne 0 ] && ok "integrity failure exits non-zero" || bad "tampered asset accepted (exit 0)"
cmp -s "$lw" "$T/old-copy" && ok "original host untouched" || bad "host changed despite a bad hash"
[ ! -e "$lw.new" ] && ok "no staged leftover" || bad "staged .new left behind"

# The boot modules must come from the fused host even when a `lua/` directory
# sits next to the executable: LuaJIT's Windows default package.path searches
# `!\lua\?.lua` (the exe's own directory) — the v0.1.29 release check caught a
# host in the repo root loading the checkout's unversioned boot/verify.lua.
echo "=== boot modules load from the fused host, not a lua/ dir beside it ==="
mkdir -p "$T/shadow/lua/boot"
cp "$T/new-copy" "$T/shadow/$exe_name"
printf 'local M = {}\nM.RELEASE_VERSION = "shadowed"\nM.HOST_VERSION = 1\nreturn M\n' \
  > "$T/shadow/lua/boot/verify.lua"
out="$("$T/shadow/$exe_name" version 2>&1)"; echo "$out"
case "$out" in *"host: $ver "*) ok "fused boot.verify wins over lua/ beside the exe" ;; *) bad "boot module shadowed: $out" ;; esac

# Embedded code runs in pinned context only as the pinned release, in-process,
# provisioning nothing (spec §16.22), and never loads a bundle a repository
# ships under .nvim/cache.
echo "=== pinned context: the pinned release runs embedded; a repo-shipped bundle is never loaded ==="
mp() { if [ "$os" = windows ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
export LOOMWORKS_RELEASE_URL="$(mp "$T/mirror")"
pr="$T/pinrepo"
mkdir -p "$pr/.nvim/cache/lua-$ver/loomworks" "$T/pinhost"
cp "$T/new-copy" "$T/pinhost/$exe_name"
printf 'version = %s\nsha256_%s = %s\n' "$ver" "$asset" "$(sha_of "$T/new-copy")" > "$pr/lw.pin"
marker="$T/PLANTED_BUNDLE_RAN"
for f in shim.lua cli.lua; do
  printf 'local f = io.open([[%s]], "w") f:write("x") f:close()\nreturn {}\n' "$(mp "$marker")" \
    > "$pr/.nvim/cache/lua-$ver/loomworks/$f"
done
out="$(cd "$pr" && LOOMWORKS_PINNED="$ver" LW_ROOT="$(mp "$pr")" "$T/pinhost/$exe_name" status 2>&1)"; echo "$out" | head -3
[ ! -e "$marker" ] && ok "repo-local planted bundle was not executed" || bad "planted .nvim/cache bundle ran"
[ ! -e "$T/home/loomworks/pinned" ] && ok "nothing provisioned for the pinned release" || bad "a pinned bundle was provisioned"
out="$(cd "$pr" && LOOMWORKS_PINNED="0.0.0-other" LW_ROOT="$(mp "$pr")" "$T/pinhost/$exe_name" status 2>&1)"; code=$?
[ $code -ne 0 ] && ok "another pinned version: refused" || bad "another pinned version ran (exit 0)"
case "$out" in *"refusing to run in pinned context"*) ok "names the refusal" ;; *) bad "unexpected pinned refusal: $out" ;; esac
[ ! -e "$marker" ] && [ ! -e "$T/home/loomworks/pinned" ] && ok "refusal provisioned and ran nothing" || bad "refusal ran or provisioned something"

no_bundles && ok "no lua-* created by any run" || bad "a bundle appeared"
[ "$(cd "$T/instdecoy" && find . | sort)" = "$decoy_before" ] && ok "the install folder is still untouched" || bad "the install folder changed"

echo
echo "host self-update e2e: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
