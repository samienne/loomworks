# loomworks

`lw` builds, runs and tests multi-project workspaces from one consistent
command line. You describe the workspace once in a `loomworks.json`: its
projects (cmake, meson, plain shell commands), their configurations (Debug,
Release, ...) and how they combine. `lw` then resolves each combination into
a buildable **profile**, finds the toolchains on the machine, runs configure,
build, test and clean in the right build directories, and remembers the state
of every build.

- Non-invasive: `lw` never edits your project files. Collaborators who do not
  use it see one extra `loomworks.json`, or nothing at all.
- One self-contained binary for Linux, macOS and Windows. It needs no Lua or
  other runtime, and it updates itself from signed releases.
- Scriptable: `--no-input` for CI, `--json` output for many commands, JUnit
  test reports.
- A workspace daemon serves editors and other tools over a documented
  protocol. The Neovim plugin
  [loomworks.nvim](https://github.com/samienne/loomworks.nvim) is one such
  client.

## Install

`lw` installs itself: download the binary for your platform, **verify it**,
then run its `install` command. It copies itself to a per-user location on
`PATH` (`~/.local/bin/lw`, or `%LOCALAPPDATA%\Microsoft\WindowsApps\lw.exe`)
and fetches the verified release bundle. No admin rights are needed.

There are two ways to verify the binary before its first run.

**Build provenance (recommended).** Every release binary is attested by
GitHub Actions and recorded in Sigstore's public transparency log. This needs
an authenticated `gh`:

```sh
gh release download --repo samienne/loomworks -p lw-linux-x86_64
gh attestation verify lw-linux-x86_64 --repo samienne/loomworks
chmod +x lw-linux-x86_64 && ./lw-linux-x86_64 install -y
```

**Release-key signature (no `gh` needed).** Each release publishes a
`SHA256SUMS` list signed with the release key below. Verify the signature,
then check the binary against the list. These commands do not change between
releases.

Linux / macOS:

```sh
base=https://github.com/samienne/loomworks/releases/latest/download
bin=lw-linux-x86_64          # or lw-macos-arm64
d="$(mktemp -d)" && cd "$d"
curl -fsSLO "$base/$bin" && curl -fsSLO "$base/SHA256SUMS" \
  && curl -fsSLO "$base/SHA256SUMS.sig"
cat > lw.pub.pem <<'PEM'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8MhoZlT5ww82JmplPiRyta32R8HY
meq3+ZL1wAo7PHHBnHHzXIE+Kab49ClyLvDUGsOR3LG+kU1lH6nxunmO2A==
-----END PUBLIC KEY-----
PEM
# macOS ships `shasum`, not GNU `sha256sum`.
if command -v sha256sum >/dev/null; then check="sha256sum -c -"
else check="shasum -a 256 -c -"; fi
openssl dgst -sha256 -verify lw.pub.pem -signature SHA256SUMS.sig SHA256SUMS \
  && grep -E "[ *]$bin\$" SHA256SUMS | $check \
  && chmod +x "$bin" && "./$bin" install
```

Windows (PowerShell 7):

```powershell
$base = "https://github.com/samienne/loomworks/releases/latest/download"
$bin  = "lw-windows-x86_64.exe"
$d = New-Item -ItemType Directory (Join-Path $env:TEMP (New-Guid))
"$bin","SHA256SUMS","SHA256SUMS.sig" | ForEach-Object {
  Invoke-WebRequest "$base/$_" -OutFile (Join-Path $d $_)
}
$pub = @"
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8MhoZlT5ww82JmplPiRyta32R8HY
meq3+ZL1wAo7PHHBnHHzXIE+Kab49ClyLvDUGsOR3LG+kU1lH6nxunmO2A==
-----END PUBLIC KEY-----
"@
$ec = [System.Security.Cryptography.ECDsa]::Create()
$ec.ImportFromPem($pub)
$sums = [IO.File]::ReadAllBytes((Join-Path $d "SHA256SUMS"))
$sig  = [IO.File]::ReadAllBytes((Join-Path $d "SHA256SUMS.sig"))
if (-not $ec.VerifyData($sums, $sig,
      [Security.Cryptography.HashAlgorithmName]::SHA256,
      [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)) {
  throw "SHA256SUMS signature does not verify"
}
$want = ((Get-Content (Join-Path $d "SHA256SUMS") |
  Select-String " $bin$") -split '\s+')[0]
$got = (Get-FileHash (Join-Path $d $bin) -Algorithm SHA256).Hash
if ($got -ine $want) { throw "hash mismatch for $bin" }
& (Join-Path $d $bin) install
```

`ImportFromPem` needs PowerShell 7 (.NET 5 or later); on Windows PowerShell
5.1 use the provenance route.

The signature route trusts the key printed in this README, so for a first
install it rests on the same GitHub account that serves the binary. After
that, `lw self-update` verifies every update against the key built into your
installed `lw`.

**Updating.** `lw self-update` fetches, verifies and installs the newest
release (bundle and binary). `--channel unstable` follows pre-releases as
well; `lw version` shows what you run. To pin a release in CI, download a
versioned URL instead of `latest`, or use the repo-local launcher below.

## Quick start

From the root of a repository:

```sh
lw init                                  # create the workspace (.nvim/ holds machine-local state)
lw project add path/to/app               # register a project; its type is detected
lw configset create debug app=Debug      # map each project to a configuration
lw tools                                 # list the toolchains found on this machine
lw profile create debug ninja-gcc-14     # a buildable profile: config set + toolchain
lw build debug:ninja-gcc-14              # configure if needed, then build
lw publish                               # write the shared loomworks.json
```

Add `.nvim/` to the repository's `.gitignore`: it holds the working copy, the
build cache and the default build trees, all machine-local. Only
`loomworks.json` is shared.

Day to day:

```sh
lw status                  # the workspace, its profiles and their build state
lw profile select debug    # make a profile active (a unique substring works)
lw build                   # build the active profile
lw run                     # build, then run the profile's default target
lw run my-tool -- --flag   # run a named target with arguments
lw test                    # build what the tests need, then run them
lw clean                   # clean the profile's build directories
lw help <command>          # details of any command
```

In scripts and CI, pass `--no-input` (or set `LW_NO_INPUT=1`; a `CI`
environment implies it). `lw` then never prompts and never uses the active
profile, so name the profile explicitly:

```sh
lw --no-input build debug:ninja-gcc-14
lw --no-input test debug:ninja-gcc-14 --junit results.xml
```

## Repo-local launcher (`lw bootstrap`)

For a project where every contributor and CI runner should use the same `lw`,
with no prior install, commit a pinned launcher:

```sh
lw bootstrap               # status: the pin, the launchers, what to do
lw bootstrap install       # write lw.pin, lw.sh and lw.cmd (pins this lw's release)
lw bootstrap upgrade       # move the pin to the newest release
```

`lw.pin` records a release version and the SHA-256 of every host binary and
of the bundle, taken from that release's signed `SHA256SUMS`. `lw.sh` (Linux,
macOS, Git Bash) and `lw.cmd` (Windows) download the pinned binary, check it
against the pin, cache it under `.nvim/cache/` and run it:

```sh
./lw.sh --no-input build debug:ninja-gcc-14
.\lw.cmd --no-input test debug:ninja-gcc-14
```

An installed `lw` also honours the pin: in a pinned repository it runs the
pinned release for workspace commands. `install` also sets the line-ending
attributes of the launchers, the ignore rule for the cache and the executable
bit of `lw.sh`; commit what it reports.

## The workspace daemon

`lw daemon run` keeps a workspace loaded and serves it to clients: one daemon
per workspace and user, started on demand and stopped when idle. Clients
connect over a local, owner-only endpoint (a Unix socket or a Windows named
pipe), authenticate, call the workspace's interfaces (build, test, launch,
profiles, views, ...) and receive task output as a stream. Editors use it
through `lw daemon run --stdio`; the CLI uses it when `runtime-mode` is set to
`daemon` (`lw settings set runtime-mode daemon`) and otherwise runs each
command in its own process. `lw daemon status` and `lw daemon stop` manage it.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): how the code is organised, for
  contributors.
- [spec/core/](spec/core/README.md): the behavioural specification (data
  model, lifecycle, modules, headless `lw`, trust, devices, the daemon).
- [spec/protocol/PROTOCOL.md](spec/protocol/PROTOCOL.md): the workspace
  protocol (transport, handshake, envelope, tasks, schemas).
- [spec/protocol/API.md](spec/protocol/API.md): the interfaces a daemon
  offers over that protocol.
- [spec/formats.md](spec/formats.md): `loomworks.json` and the other files
  `lw` reads and writes.
- [CHANGELOG.md](CHANGELOG.md), or `lw release-notes`: what changed in each
  release.

## Release public key

Releases are signed with this ECDSA P-256 key (also in
[`keys/loomworks-release.pub.pem`](keys/loomworks-release.pub.pem)). Every
`lw` binary carries it and checks every update against it.

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8MhoZlT5ww82JmplPiRyta32R8HY
meq3+ZL1wAo7PHHBnHHzXIE+Kab49ClyLvDUGsOR3LG+kU1lH6nxunmO2A==
-----END PUBLIC KEY-----
```
