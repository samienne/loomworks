#!/usr/bin/env bash
# The publish gate's asset check: verify a draft release's downloaded assets
# before release.yml un-drafts it. Never builds or downloads anything.
#
#   verify_draft.sh <version> <dir> <public_key.pem>
#
# <dir> holds the draft's SHA256SUMS, SHA256SUMS.sig and every asset that
# SHA256SUMS lists. Checks, failing on the first problem:
#   - SHA256SUMS.sig verifies under <public_key.pem> (the committed release key);
#   - every asset listed in SHA256SUMS is present and matches its hash;
#   - SHA256SUMS lists every asset a release must carry (the host binaries,
#     the bundle, its signed manifest and the descriptor);
#   - every host asset (lw-*, not the descriptor) is a self-contained
#     executable: its fused zip carries loomworks/cli.lua (spec §16.11);
#   - manifest.json.sig verifies, and the manifest names <version> and the bundle;
#   - the descriptor names <version> as a release (not a development build).
#
# Needs openssl, python3 and sha256sum or shasum.
set -euo pipefail

die() { echo "verify_draft.sh: $*" >&2; exit 1; }

version="${1:-}"; dir="${2:-}"; key="${3:-}"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || die "version '$version' is not <n>.<n>.<n>[-pre]"
[ -d "$dir" ] || die "no directory '$dir'"
[ -f "$key" ] || die "no public key '$key'"

sums="$dir/SHA256SUMS"
[ -f "$sums" ] || die "no SHA256SUMS in $dir"
[ -f "$sums.sig" ] || die "no SHA256SUMS.sig in $dir"
openssl dgst -sha256 -verify "$key" -signature "$sums.sig" "$sums" >/dev/null \
  || die "SHA256SUMS.sig does not verify under $key"
echo "SHA256SUMS signature verifies under $key"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

listed=" "
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  [ -n "$line" ] || continue
  hash="${line%% *}"
  name="${line#* }"; name="${name# }"; name="${name#\*}"
  printf '%s' "$hash" | grep -Eq '^[0-9a-f]{64}$' || die "bad SHA256SUMS line: $line"
  printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die "bad asset name in SHA256SUMS: '$name'"
  [ -f "$dir/$name" ] || die "asset $name (listed in SHA256SUMS) is missing"
  [ "$(sha_of "$dir/$name")" = "$hash" ] || die "asset $name does not match SHA256SUMS"
  listed="$listed$name "
done < "$sums"

bundle="loomworks-lua-$version.zip"
descriptor="lw-$version-descriptor.json"
# The host binaries: every platform of boot.pin.HOST_ASSETS (the release being
# drafted is the newest, so it publishes all of them; spec §16.11).
for need in lw-linux-x86_64 lw-linux-arm64 lw-macos-arm64 lw-macos-x86_64 lw-windows-x86_64.exe \
            "$bundle" manifest.json manifest.json.sig "$descriptor"; do
  case "$listed" in
    *" $need "*) ;;
    *) die "SHA256SUMS does not list $need" ;;
  esac
done
echo "every asset matches SHA256SUMS"

# Self-contained executables (spec §16.11): each host asset's fused zip carries
# the full tree, not only the bootstrap.
for name in $listed; do
  case "$name" in
    "$descriptor") ;;
    lw-*)
      python3 - "$dir/$name" <<'PY' || die "host asset $name does not carry loomworks/cli.lua (not a self-contained executable)"
import sys, zipfile
try:
    names = zipfile.ZipFile(sys.argv[1]).namelist()
except Exception:
    sys.exit(1)
sys.exit(0 if "loomworks/cli.lua" in names else 1)
PY
      ;;
  esac
done
echo "every host asset is self-contained"

openssl dgst -sha256 -verify "$key" -signature "$dir/manifest.json.sig" "$dir/manifest.json" >/dev/null \
  || die "manifest.json.sig does not verify under $key"

python3 - "$dir/manifest.json" "$dir/$descriptor" "$version" "$bundle" <<'PY'
import json, sys
manifest, descriptor, version, bundle = sys.argv[1:5]
m = json.load(open(manifest))
if m.get("version") != version:
    sys.exit("verify_draft.sh: manifest.json names version %r, not %s" % (m.get("version"), version))
if m.get("bundle") != bundle or bundle not in (m.get("artifacts") or {}):
    sys.exit("verify_draft.sh: manifest.json does not name the bundle %s" % bundle)
d = json.load(open(descriptor))
b = d.get("binary") or {}
if b.get("lw_version") != version or b.get("dev") is not False:
    sys.exit("verify_draft.sh: the descriptor names %r (dev=%r), not release %s" % (b.get("lw_version"), b.get("dev"), version))
print("manifest and descriptor name release %s" % version)
PY
echo "draft assets for $version verified"
