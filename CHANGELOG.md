# Changelog

What changed in each release of loomworks (the `lw` command-line tool, the
workspace daemon and its protocol). `lw release-notes` shows these notes
offline, from the release you run; after an update, the new `lw` points at
what changed since your previous version.

<!--
How to write an entry (lua/loomworks/release_notes.lua defines the grammar;
tests/release_notes_spec.lua and scripts/release/release_notes.py check it):

* Every change adds its items under `## Unreleased`, in the section that fits.
* Sections, each at most once per entry, in this order:
  Breaking, Upgrade notes, Added, Changed, Fixed, Security, Removed.
  Breaking and Upgrade notes are what a user must act on; lw shows them even in
  its shortest summaries.
* An item is one `- ` bullet (continuation lines indented by two spaces) that
  says what changed for the user, ending with the PR number: `(#79)`.
* ASCII only; Markdown only for `code spans`.
* Cutting a full release: rename `## Unreleased` to `## <version> - <YYYY-MM-DD>`,
  add a one- or two-sentence summary paragraph under the heading, and put an
  empty `## Unreleased` back on top. The release workflow refuses a full-release
  tag without its entry. Pre-releases have no entry of their own: they ship
  the Unreleased entry.
* A development build takes its version from the newest released entry
  (`<version>+dev`), so the file always keeps at least one.
-->

## Unreleased

### Upgrade notes

- The first build of each profile after the move from `.nvim/` to `.lw/` is a
  full rebuild: the old build trees in `.nvim/build/` are not reused (a
  configured CMake or Meson tree records its own location). The migration
  message now says so, and while `.nvim/build/` remains and a profile is
  unconfigured, the `Old state` line of `lw status` says it too. The README
  section "Upgrading from 0.1.x" explains it; delete `.nvim/build/` by hand
  once no older lw is pinned in the repository. (#190)

## 0.2.1 - 2026-11-23

A fix for Windows: an `lw.cmd` of any earlier release, replaced by
`bootstrap install` or `bootstrap upgrade` while it runs, now ends cleanly
with lw's exit status instead of looping.

### Upgrade notes

- On Windows, with a pin of 0.2.0, do not run `bootstrap install` or
  `bootstrap upgrade` through a `.\lw.cmd` older than 0.2.0's: lw 0.2.0 leaves
  cmd looping after it finishes. Run them with an installed `lw` (`lw bootstrap
  upgrade` in the repository) or as `./lw.sh` from Git Bash; the README's
  "Upgrading from 0.1.x" describes each route. (#188)

### Fixed

- An `lw.cmd` of any earlier release, replaced by `bootstrap install` or
  `bootstrap upgrade` while it runs, now ends with lw's exit status and prints
  nothing. cmd.exe resumes the old launcher in the middle of the new file,
  and with 0.2.0's `lw.cmd` it ran whatever it landed on: from the launcher
  0.1.51 writes it looped forever retrying a download, deleting the files in
  `%TEMP%` on every round when the pinned lw was already cached. The new
  `lw.cmd` begins with a landing zone that catches every earlier launcher, and
  the "lw.cmd is replaced while it runs" note now appears only for a
  hand-edited `lw.cmd` replaced with `--force`. (#188)
- The README's "Upgrading from 0.1.x" names the commands that exist
  (`lw bootstrap`, not `lw bootstrap status`), says that `lw self-update` never
  moves a pin, and covers a repository with only the launchers. (#188)

## 0.2.0 - 2026-11-23

The first release of lw from samienne/loomworks, where `lw`, the workspace
daemon and its protocol now live: each `lw` is one self-contained, signed
executable that `lw self-update` replaces alone, a workspace's state moves
from `.nvim/` to `.lw/`, and `lw pin ignore` lets one checkout run a newer lw
than its pin. Coming from 0.1.x, an `lw` of 0.1.51 or later reaches 0.2 with
`lw self-update` (an older one updates to 0.1.51 first); read the Breaking
and Upgrade notes below before upgrading.

### Breaking

- `lw self-update --no-host` is a usage error (exit 2): self-update replaces
  only the `lw` executable, so there is no separate bundle step to skip
  (#135).

### Upgrade notes

- Cross over from 0.1.x before 2027-01-23. Until then every release still
  publishes the `loomworks-lua-<version>.zip` bundle and `manifest.json`, which
  a 0.1.x `lw` (0.1.51 included) needs to find and install a newer release;
  releases from that date on publish only the executables, so a 0.1.x `lw`
  can no longer self-update and must be reinstalled with the README install
  command. Run `lw self-update` (and `lw bootstrap upgrade` in pinned
  repositories) before then (#116).
- Upgrading from 0.1.x, for the installed `lw` and for a pinned repository
  (`lw bootstrap upgrade`, then commit `lw.pin`, `lw.sh` and `lw.cmd`), is
  described step by step in the README section "Upgrading from 0.1.x"
  (#186). Through the repository's launcher from an `lw` below 0.1.51, run
  `bootstrap upgrade` a second time: that `lw`'s report suggests a single
  `bootstrap install`, which does not finish the move.
- lw now keeps a workspace's state in `.lw/` instead of `.nvim/`, with
  shorter names (`.lw/user.json`, `.lw/cache.json`, ...); builds go to
  `.lw/build/`. The first command in a workspace of an earlier release copies
  the working copy over and says so; `.nvim/` is left as it was for older lw
  versions, and its build trees are not reused (the first build configures
  afresh). `.lw/` ignores itself (`.lw/.gitignore`), so no `.gitignore` line is
  needed. Launchers written by `lw bootstrap install` cache a 0.2.0+ pin's
  binary in `.lw/cache/`; launchers of earlier releases keep working. If an
  older lw is still running in the workspace, the copy waits for you to stop
  it and retry. Until you delete them, `lw status` shows an `Old state` line
  naming the files an earlier lw left in `.nvim/` that are no longer used
  (such as `.nvim/build/` and `.nvim/loomworks.user.json`), and `lw health`
  lists them all. lw never deletes them: delete them by hand once no older lw
  is pinned in the repository. A workspace created with `lw init` is marked
  as native, so `.nvim/` state an older lw writes there later is a `lw health`
  warning, not a stop; when an older lw writes `.nvim/` state into a migrated
  workspace, lw stops, names both copies and the older lw as the usual
  cause, and says how to keep either one (#162, #176, #177, #179).
- The build cache (`.lw/cache.json`, formerly
  `.nvim/loomworks.cache.json`) is now version 9. A version 8
  cache is migrated when it loads and written as version 9 by the next save;
  after that an older `lw` or editor (including a pinned one) refuses the
  workspace as a newer schema until it is updated. Each configuration of a
  CMake multi-config build directory (Ninja Multi-Config, Visual Studio)
  builds once more after the upgrade, incrementally, because its old state
  could have come from another configuration's build. Running such a
  configuration on a device stages it under a new directory on the device;
  `lw device clean` removes the old one. (samienne/loomworks.nvim#357)
- In a repository whose `lw.pin` names a release before 0.2.0-beta.7 (every
  0.1.x release, which keeps its state in `.nvim/`), a global 0.2 `lw` does
  not create or migrate `.lw/` for the commands it runs itself (`lw init`,
  profile and config edits, `lw status`, `lw health`, `lw pull`, `lw trust`,
  `lw nuke`, `lw unlock`): it refuses with one line naming the launcher form
  (`./lw.sh <command>`, or the pinned version when the repository has no
  launcher) and `lw bootstrap upgrade`. `lw worktree add` creates the
  worktree but does not seed it (its note names the pinned lw's pull), shell
  completion stays silent, and the daily housekeeping and `lw cleanup` leave
  the pinned lw's files in the workspace alone (`lw cleanup` cleans up only
  outside the workspace there, and says so). A build
  redirected to such a release while `.lw/user.json` exists says once that
  the pinned lw ignores it. `--no-pin` (or `lw pin ignore`) still runs the
  newer lw (#170, #176, #178).

### Added

- `lw` is now built for Linux arm64 (`lw-linux-arm64`) and Intel macOS
  (`lw-macos-x86_64`), from this release on. A repository's `lw.sh` written
  by an earlier release does not select them: run `lw bootstrap upgrade`
  there, which `lw health` now also suggests. A pin of an earlier release
  still has no build for these platforms (#155).
- `lw launch set` takes `--description <para>` (repeatable), like
  `lw launch add`; it replaces the whole description, and
  `--description ""` clears it. `--working-dir ""` clears the working
  directory (samienne/loomworks.nvim#290).
- `lw pin ignore` makes one checkout of a pinned repository run the lw you
  invoke (a newer release, or a development build) instead of the pinned
  release, as `--no-pin` would on every command; `lw pin follow` follows the
  pin again and `lw pin` shows the mode. The setting is `.lw/local`, never
  committed. With the pin ignored, the editor's daemon relay runs the lw on
  your search path, so the editor and the shell run one binary; `lw status`
  shows a `Pin` line and `lw health` and `lw bootstrap` report it. Switching
  stops an idle workspace daemon of the previous build, or asks a busy one to
  restart when idle. Moving a checkout to an older lw (following the pin
  again, or a redirect to a pinned release older than the working copy's
  last writer) prints a one-line warning: an older lw may drop settings it
  does not know (#173).
- `lw reset --state` deletes only the build cache and the health cache,
  without loading the workspace: the way out when the build cache was
  written by a newer lw. It keeps your working copy, `.lw/local`, the pin and
  the build directories (the next build configures them again in place),
  lists what it deletes and keeps, and confirms first (`-y` in CI). Under a
  pin of a release before 0.2.0-beta.7 it deletes that release's
  `.nvim/loomworks.cache.json` and `.nvim/loomworks.health.json`, and it
  does not suggest `lw unlock --journal` for such a release's journal.
  `--builds` also deletes the build state, listed per profile; `lw nuke` is
  now its alias (#173, #178).

### Changed

- `lw`, the workspace daemon and its protocol moved here from loomworks.nvim,
  which is now a client of the daemon. The history of the 0.1.x releases is in
  the CHANGELOG of loomworks.nvim.
- lw 0.2 and later is published in samienne/loomworks. `lw` now fetches a
  release from the repository it was published in: 0.0.x/0.1.x from
  samienne/loomworks.nvim, 0.2 and later from samienne/loomworks, in
  `lw self-update`, `lw bootstrap install` / `upgrade`, pinned provisioning and
  the `lw.sh` / `lw.cmd` launchers. The newest release (both channels) is
  looked up in samienne/loomworks only. `LOOMWORKS_RELEASE_URL` /
  `release-url` is still one mirror for all versions. `lw bootstrap` and
  `lw health` report earlier launchers as broken only for a pin of 0.2 or
  later (samienne/loomworks.nvim#389).
- Release `lw` executables carry all of loomworks (the code, the release
  notes and the protocol documents), so a freshly installed `lw` works
  without downloading a release bundle, and `lw self-update` replaces only
  the executable (#132).
- An `lw` executable that embeds the loomworks code runs that code and
  nothing else: it never loads a release bundle installed beside it, and
  `lw version` reports its release and "self-contained", or "dev build". In
  a repository's pinned context it runs only as the pinned release and
  otherwise refuses with an error naming both versions, instead of
  provisioning another release (#131).
- `lw self-update` replaces only the `lw` executable: it installs no release
  bundle and removes no installed one. The newest release is read from the
  `latest` signed `SHA256SUMS` (from its `lw-<version>-descriptor.json` entry;
  `manifest.json` only while the newest release predates the descriptor, and
  only when the signed list names that release's bundle), and
  the replacement must match the target release's signed list, which must name
  that release's descriptor. `--version <x.y.z>` installs an exact release and
  `--force` replaces the executable with an equal or older one too (saying
  `downgrading <running> -> <target>` first; for a release before
  self-contained executables it notes that the new `lw` downloads its code
  bundle on its next `lw self-update`). When the
  executable cannot be replaced (an unwritable location, a missing asset) it
  exits non-zero. `lw install` installs only the executable; `--no-bundle` is
  accepted and ignored (#135).
- A global `lw` in a repository that pins another release runs that
  release's executable from a cache in the per-user data directory
  (`exe/<sha256>/`), verified against the pin before every run, and no
  longer downloads or unpacks a release bundle for it. A pin to a release
  from before self-contained executables is still honoured: that release
  provisions its own bundle. A pin to a release before 0.1.32, which loads
  code from the repository, is refused, naming the version and
  `lw bootstrap upgrade`; nothing is deleted (#133).
- `lw bootstrap install` pins a self-contained release by its executables
  alone: the bundle's hash is written only while the release still publishes
  a bundle, and a pin without it is complete (`lw bootstrap` and `lw health`
  note that a global `lw` older than 0.2.0-beta.3 cannot follow such a pin).
  A release from before self-contained executables must still list its
  bundle. A self-contained release's signed hash list must name its own
  descriptor, so another release's list is refused; an older release's list,
  which has no descriptor, is bound to it by its bundle entry, so pinning or
  repairing a pin to 0.1.4x keeps working (#134).
- `LOOMWORKS_PINNED` and `LW_ROOT` no longer leak into what `lw` starts: a
  build, run or test step (and an `lw` it runs) no longer inherits the
  pinned context or the launcher's workspace root, so a nested `lw` resolves
  its own workspace and pin, and the daemon no longer receives them with a
  request's environment (#131).
- The workspace daemon protocol restarts at transport 1 for 0.2.0, and the
  interface versioning policy is written down. Pre-0.2.0 pre-releases used
  transport numbers up to 11 and are incompatible: an editor or `lw` of this
  release treats such a daemon as incompatible, and the request kinds of
  transport 10 are gone. The daemon refuses an interface call from a client
  it shares no transport with (`no_transport`), and `lw` says plainly that
  no protocol version was agreed (#161).
- `lw module list | install | update` read the module index from
  `modules.json` in samienne/loomworks instead of samienne/loomworks.nvim.
  `lw settings set module-index` and `LOOMWORKS_MODULE_INDEX` still override
  it (#144).
- On a platform without an lw build, such as Windows arm64, `lw self-update`,
  a pinned `lw` and the `lw.sh` / `lw.cmd` launchers say
  `no lw build for <os>-<arch>` and name the supported platforms
  (linux-arm64, linux-x86_64, macos-arm64, macos-x86_64, windows-x86_64).
  `lw health` reports older launchers as missing this (#147).
- Every usage error now exits 2 (it was 1 for many of them): an unknown,
  repeated or misplaced option, a missing or malformed value (`--timeout 0`,
  an invalid launch name, an unknown `lw config set` parameter or health
  area), an empty value, an extra operand, and a missing operand lw cannot
  ask for, such as no profile named in non-interactive mode. An error about
  the workspace's state, such as no unambiguous default profile, still exits
  1 (samienne/loomworks.nvim#290).
- Every option that takes a value now also accepts it joined with `=`, on
  every command: `--working-dir=build`, `--env=PORT=8080`, `--cwd=out`
  (the split is at the first `=`) (samienne/loomworks.nvim#290).
- An option that holds one value is refused (exit 2) when it is given twice,
  instead of the last one winning. This includes `--cwd` with `--working-dir`,
  `--working-dir` with `--clear-working-dir`, and `--command` with
  `--from-target` on `lw launch set`. `--env`, `--unset-env`, `--description`,
  `-m`, `--prefix`, `--target` and `--log` may still repeat (samienne/loomworks.nvim#290).
- An empty option value is refused (exit 2), as in `lw run --cwd= app`, except
  where `""` clears: `--working-dir ""` and `--description ""` on
  `lw launch set`, `--working-dir ""` on `lw launch add` (no working
  directory), and `-m ""` on `describe` (samienne/loomworks.nvim#290).
- A value that starts with `--` must now be joined with `=`
  (`--working-dir=--odd`, `lw run --prefix gdb --prefix=--args`): a valued
  option followed by `--`, by another `--` token or by nothing is a missing
  value (exit 2) (samienne/loomworks.nvim#290).
- On `lw launch add <project> <name> <command>`, every token after the command
  is the program's, including lw's own options: `--env`, `--working-dir` and
  `--description` go before the command (samienne/loomworks.nvim#290).
- `lw launch set` no longer turns an unknown option into an argument: an
  unknown option before `--` is a usage error (exit 2) and nothing changes.
  An argument starting with `-` now goes after `--`
  (`lw launch set app run -- --port 1`); bare arguments still work as before
  (samienne/loomworks.nvim#290).
- A working copy or build cache written by a newer lw now names the fixes:
  `lw pin ignore` and `lw bootstrap upgrade` in a pinned repository (else
  "update lw"), and for the build cache `lw reset --state`. The warning for
  one that still loads names the same fixes instead of "update loomworks".
  A newer lw about to redirect to a pinned release that cannot read the
  state prints them first (#173, #176).
- `lw run` with no target named needs the profile's default target and no
  longer falls back to its only launchable target: without a stored default
  it refuses before configuring or building anything, naming both fixes
  (`lw run <profile> <target>`, or `lw target set <profile> <target>`).
  A project with a single executable needs `lw target set` once.
  A debug launch or launch target build naming no target is refused the
  same way, before any task. The target listing marks only a stored
  default (#169).

### Fixed

- On Linux and macOS, removing a test run's results file now refuses a
  path containing `\`: it was checked as if `\` were a separator but removed
  as written, so a file named with a backslash in `.lw` could pass the
  `.lw/tmp` check (#185).
- `.\lw.cmd bootstrap install` or `upgrade` no longer makes cmd print
  `'"!bin!"' is not recognized` and exit 9009 after lw rewrote `lw.cmd`: the
  new `lw.cmd` runs lw and exits on one line, so nothing after lw is read
  from the rewritten file. Replacing an `lw.cmd` of an earlier release through
  itself still can, so lw now says so as the report's last line; the files
  are correct (#186).
- `lw bootstrap` on a pin from before 0.2.0-beta.7 (state in `.nvim/`) now
  offers `lw bootstrap upgrade`, which moves the repository to lw 0.2 and its
  state to `.lw/`, even when the channel has nothing newer than the pin
  (#186).
- `lw worktree add --no-pull` said to run `lw pull` "here", the directory
  you ran it in; it now says to run it in the new worktree (#178).
- `lw module install harmony` installs harmony module v0.1.5: a device run
  now refuses an unsigned HAP before installing it, naming the missing
  `signingConfigs` in `build-profile.json5`, instead of failing on the device
  with "no signature file"; a signed build's HAP is preferred over the
  unsigned one it leaves next to it. Run `lw module update harmony` to get
  it. (#183)
- `lw run` on a profile whose module offers device targets (such as the
  HarmonyOS `run-device`) now says they launch from the editor only, listing
  them, instead of a bare `available: (none)`; naming one, or a project, is
  refused at once rather than after reconfiguring every project, and so is
  a bare `lw run` whose stored default target is a device target.
  `lw target list` shows them in their own editor-only group. (#182)
- clangd no longer floods MSVC projects that build with `/Wall` with
  `-Wc++98-compat`, `-Wpadded` and similar warnings: clangd reads a cl-style
  `/Wall` as `-Weverything`, so the compile database lw writes for clangd now
  carries `/W4` (clang's `-Wall -Wextra`) instead. The build and the build
  directory's own `compile_commands.json` are unchanged. Existing databases
  are rebuilt automatically (#181).
- `lw run` resolves its launch target before it builds: it configures what
  is not configured yet, then fails at once when the named target does not
  exist instead of after a full build (with no target named and no default
  target set it refuses before configuring, see Changed),
  and builds only the resolved target and the projects it depends on
  (directly or transitively), not the whole profile. A named target that is
  not in the configured tree, such as one just added to the build files,
  first has its project's configure step re-run once (no wipe, unlike
  `lw build --reconfigure`). A command launch configuration still builds the whole profile
  (#164).
- `lw run <profile>` works in non-interactive mode (`--no-input`, CI): the
  one operand names the profile and runs its default target, matched as for
  `lw build` (a unique substring works). Before, no non-interactive form ran
  a profile's default target. In an interactive terminal one operand is
  still a target on the active profile. A bare non-interactive `lw run` now
  names both forms, `lw run <profile>` and `lw run <profile> <target>`
  (#168).
- When the release origin has no stable release yet, `lw self-update`,
  `lw bootstrap install --latest` / `upgrade` and `lw release query` say that
  no stable release was found there instead of a bare "fetch SHA256SUMS"
  error, and `lw bootstrap` and `lw health` say there is no stable release yet
  instead of "offline or release server unreachable". Each names a command
  that selects the unstable channel (`lw settings set channel unstable`, or
  `--channel unstable` on the commands that take it). A release mirror with
  no release says so too. The `--json` `update` object of `lw bootstrap` and
  `lw health` carries `reason: "no-release"`, and any other failed release
  check in `lw bootstrap` shows its real reason (#143, #171).
- A failed `lw self-update --channel <c>` (no release on that channel, a
  download or verification failure, an unwritable install) no longer saves
  the channel, so you are no longer recorded on a channel the update never
  reached; it says "The update channel was not changed." The channel is saved
  once the update completes (replaced, already up to date, or left in place
  by design) (#175).
- On Linux the workspace daemon no longer dies, leaving its running step
  behind, when a client disconnects while the daemon is writing to it: a
  write to a closed connection is a disconnect, never a signal that ends lw.
  When the reader of lw's output goes away (`lw build | head`), lw now runs
  its cleanup, releasing its build and device locks and stopping a device
  run, before it exits with status 141; before, SIGPIPE killed it outright.
  (#123)
- A workspace load still reading its files when the workspace was closed no
  longer replaces the next workspace loaded, or refuses it with the first
  one's error. (#15)
- A change to `loomworks.json`, the working copy or the build cache written
  while a workspace was loading is no longer missed until the file changes
  again. (#16)
- `lw build`, a configure and a launch build refuse a configuration whose
  build directory state is `unknown` (an interrupted delete or reset) instead
  of building in a directory whose contents are untrusted; run `lw clean` or
  `lw reset` first (#20).
- The workspace daemon no longer refuses to delete an orphaned build
  directory by the id its workspace view served, after a request under
  another environment reloaded the workspace. (#105)
- Deleting a profile or a configuration from the status page no longer
  reports it removed when a build directory could not be removed; only the
  error is shown. Scripts and plugins calling the deletion now get `false`
  in that case instead of `true`. (samienne/loomworks.nvim#364)
- With a CMake multi-config generator (Ninja Multi-Config, Visual Studio),
  Debug and Release are separate configurations again, each with its own
  state, artifacts and status line, although they share one build directory.
  They were one unit, so building Debug made Release show as built and a
  build of Release could be skipped. Deleting one of them keeps the shared
  directory while the other still uses it. (samienne/loomworks.nvim#357)
- Renaming a project no longer throws away its configured and built build
  directories' state on the next reload: the project's configurations keep
  their build state and are not reconfigured from scratch (samienne/loomworks.nvim#342).
- Rebuilding a configuration from the status page (`R`) built even when its
  clean failed; it now stops and reports the failed clean (samienne/loomworks.nvim#328).
- A failed, stopped or refused clean no longer leaves the config shown as
  "cleaning" for the rest of the session (it also blocked removing or
  renaming that config); the same holds for a deletion that errors before it
  finishes (samienne/loomworks.nvim#330).
- A profile created from an SDK in the status page's tool picker lost its
  SDK on the next load: it was saved without toolchains, came back as the
  configuration set's toolless profile, and its key clashed with an existing
  toolless profile of that set. It now stores the SDK's kit toolchains as
  its tools, as picking the kit does. The picker offers an SDK only when it
  yields a kit for the set's project types. (samienne/loomworks.nvim#312)
- Orphan cleanup could delete a live build directory when the workspace was
  reached through a different spelling of the same path (e.g. a Windows 8.3
  short name like `RUNNER~1`): its parent under `.nvim/build` was listed as a
  stray directory. Stray detection now compares directory identity, and
  cleanup refuses any directory that holds a live build dir (samienne/loomworks.nvim#293).
- Orphan cleanup on the status page dropped the orphaned entries even when
  removing their build directories failed, and reported success. It now marks
  the entries `unknown` before removing anything, keeps them when a removal
  fails, never removes a directory a live configuration still uses, reports a
  failed stray-directory removal (the status page no longer says "cleaned"
  after a failure), and also removes the owned LSP database of each orphan it
  deleted. Deleting or cleaning an ordinary configuration also
  left its cache entry in its old state on disk while the build directory was
  being removed, so a crash mid-removal could not be recognized; the entry is
  now `unknown` on disk first (samienne/loomworks.nvim#298).
- Deleting a single orphaned configuration on the status page (`D`) could
  remove a live build directory: when the build-dir template gained a level
  (`.nvim/build/App` -> `.nvim/build/App/Debug`) the orphan's directory
  contained the live one, and an orphan naming a live directory by another
  spelling (a Windows 8.3 short name) was removed outright. It also dropped
  the entry before removing anything, so a failed removal lost it. It now
  follows the same rules as Clean all: such a directory is kept (only the
  entry is dropped), the entry is `unknown` on disk before a removal and kept
  when the removal fails, and the notification says what actually happened
  instead of always "removed" (samienne/loomworks.nvim#304).
- Deleting, cleaning or resetting a configuration went on to remove its build
  directory even when the cache could not be saved first (a failed write, or
  a save refused because another process changed the cache), so a crash
  mid-removal could not be recognized. Now nothing is removed, the entries
  keep their state, and the deletion is reported as failed (samienne/loomworks.nvim#304).
- Deleting, cleaning or resetting a configuration on Windows could remove a
  build directory another configuration still used, when the two recorded it
  under different spellings (a long path and its 8.3 short name, such as
  `C:/Users/RUNNER~1/...`). Shared build directories are now recognized by
  the directory itself, not its spelling, and are kept (samienne/loomworks.nvim#308).
- `lw launch add <project> <name> --from-target <target> ... -- <args>` stored
  the `--` as the first argument. A target-backed add has no command token, so
  its `--` is lw's separator and is dropped; before it an unknown option or a
  bare argument is a usage error instead of becoming an argument (samienne/loomworks.nvim#290).
- `lw launch set <project> <name> --description text` replaced the config's
  arguments with `--description text`; it now sets the description (samienne/loomworks.nvim#290).
- `lw launch describe -m <para> --project P --launch N` took the paragraph as
  the project name when `-m` came before the address (samienne/loomworks.nvim#290).
- `lw launch set ... --working-dir` with no value cleared the working
  directory, and `--command` / `--from-target` with no value stored none; a
  missing value is now a usage error and nothing changes (samienne/loomworks.nvim#290).
- `lw <kind> describe <item> -- <text>` refused the `--`; it now ends lw's
  options, so a description may start with `-` (samienne/loomworks.nvim#290).
- `lw launch show --json <project> <name>` refused `--json` before the
  address (samienne/loomworks.nvim#290).

### Removed

- `LOOMWORKS_INSTALL_DIR` is no longer read: `lw` keeps its pinned and
  executable caches in the per-user data directory, never installs a bundle,
  and leaves a folder the variable names untouched (#135).

## 0.1.49 - 2026-10-19

The last release made from loomworks.nvim. Its notes, and those of every
earlier 0.1.x release, are in the CHANGELOG of loomworks.nvim.

### Added

- `-v` / `--verbose` on `lw build`, `lw run`, `lw test` and `lw clean` prints
  every command a step runs under its header. (#273)
