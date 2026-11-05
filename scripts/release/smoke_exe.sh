#!/usr/bin/env bash
# Smoke-test a fused release executable (spec §16.11): it is self-contained.
#
#   smoke_exe.sh <exe> <version>
#
# In a sandbox (empty data dir, every per-user location redirected) with a
# decoy LOOMWORKS_INSTALL_DIR holding a `lua-<version>/` release bundle whose
# code would leave a marker if it ever ran, checks that:
#   - `lw version --json` names <version> as a release (not a dev build);
#   - `lw version` reports it self-contained;
#   - `lw help` works;
#   - the decoy bundle never ran and the install folder is untouched.
# Prints the executable's size and a cold-start time (`lw version`), and adds
# them to $GITHUB_STEP_SUMMARY when that is set. Needs python3.
set -euo pipefail

exe="${1:?usage: smoke_exe.sh <exe> <version>}"
version="${2:?missing version}"
[ -f "$exe" ] || { echo "smoke_exe.sh: no executable $exe" >&2; exit 1; }
exe="$(cd "$(dirname "$exe")" && pwd)/$(basename "$exe")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data" "$T/home" "$T/work" "$T/install"

native() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The decoy: a well-formed installed bundle (newer than any release) that
# records it ran. A self-contained executable never loads it.
marker="$T/DECOY_RAN"
decoy="$T/install/lua-999.0.0/loomworks"
mkdir -p "$decoy"
for f in cli.lua shim.lua _release_marker.lua; do
  printf 'local f = io.open([[%s]], "w") if f then f:write("x") f:close() end\nreturn {}\n' \
    "$(native "$marker")" > "$decoy/$f"
done
listing() { ( cd "$T/install" && find . -print | LC_ALL=C sort && cat lua-999.0.0/loomworks/* ); }
before="$(listing)"

unset LOOMWORKS_LUA LOOMWORKS_PINNED LOOMWORKS_LW LW_ROOT LOOMWORKS_CHANNEL LOOMWORKS_RELEASE_URL
export LOOMWORKS_DATA_DIR="$(native "$T/data")" LOOMWORKS_INSTALL_DIR="$(native "$T/install")" \
  LOOMWORKS_NO_HOUSEKEEPING=1 HOME="$T/home" XDG_DATA_HOME="$T/home" XDG_CONFIG_HOME="$T/home" \
  LOCALAPPDATA="$(native "$T/home")" APPDATA="$(native "$T/home")"
cd "$T/work"

fail() { echo "smoke_exe.sh: $*" >&2; exit 1; }

# Cold start: the first run of this executable in a fresh sandbox.
cold_ms="$(python3 -c '
import subprocess, sys, time
t = time.perf_counter()
subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL, check=True)
print(int((time.perf_counter() - t) * 1000))' "$exe" version)" || fail "lw version failed"

"$exe" version --json > "$T/version.json" || fail "lw version --json failed"
python3 - "$T/version.json" "$version" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
b = d.get("binary") or {}
if b.get("lw_version") != sys.argv[2] or b.get("dev") is not False:
    sys.exit("smoke_exe.sh: version --json names %r (dev=%r), not release %s"
             % (b.get("lw_version"), b.get("dev"), sys.argv[2]))
print("version --json: release %s" % sys.argv[2])
PY

out="$("$exe" version)" || fail "lw version failed"
echo "$out"
case "$out" in
  *"host: $version "*"(self-contained)"*) ;;
  *) fail "lw version does not report a self-contained release $version" ;;
esac

"$exe" help > "$T/help.txt" 2>&1 || { cat "$T/help.txt" >&2; fail "lw help failed"; }
grep -q "self-update" "$T/help.txt" || fail "lw help does not list the commands"
echo "help: ok"

[ ! -e "$marker" ] || fail "the decoy bundle in LOOMWORKS_INSTALL_DIR ran"
[ "$(listing)" = "$before" ] || fail "the decoy install folder was modified"
echo "decoy install folder: ignored and untouched"

size="$(wc -c < "$exe" | tr -d ' ')"
echo "size: $size bytes; cold start (lw version): ${cold_ms} ms"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '| %s | %s | %s bytes | %s ms |\n' "$(basename "$exe")" "$version" "$size" "$cold_ms" \
    >> "$GITHUB_STEP_SUMMARY"
fi
echo "smoke: $(basename "$exe") is a self-contained release $version"
