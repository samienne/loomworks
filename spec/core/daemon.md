> Part of the loomworks core specification -- see [`README.md`](README.md) for the index and the section-range table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.
>
> **Target design, implemented in steps.** This section specifies the end state
> of the workspace runtime and the order in which it is reached. It does not
> claim behaviour master has: every subsection carries a **status** line, and
> only parts marked *master* are in effect. The rationale, the superseded
> decisions and the step plan live in [`DAEMON.md`](https://github.com/samienne/loomworks.nvim/blob/7b7d1f9f07a3ec55845b65f6ded5972bbbdceba8/DAEMON.md) in the history of
> samienne/loomworks.nvim.
>
> Status legend: **master** — in effect; **#88** — implemented on the
> experimental daemon branch (draft PR samienne/loomworks.nvim#88), to be carried over; **re-cut** —
> exists on #88 but must change to match this section; **future** — not
> implemented anywhere.

## 19. Workspace Runtime and Daemon

**End state.** Each workspace has **exactly one runtime**: a single process
that owns the workspace model, its `.lw/` files and the operations that
change them. Every operation of §1–§18 executes in that runtime; the
non-interactive host and the editor are **clients** of it. The runtime is the
host binary itself, run in **daemon mode** (`lw daemon run`) — there is no
separate daemon program, and one implementation of every operation, reached
through one protocol, whether the runtime is a background process or runs
inside the client (§19.1).

**Transition.** Until every operation has moved into the runtime, hosts still
load the workspace and execute operations themselves (the **in-process
path**, §1–§18 as written). The in-process path, an attached run and a daemon
coexist safely because all of them take the same **operation locks** (§19.3)
and commit multi-file changes the same way (§19.4). §19.19 lists the order.

### 19.1 Runtime modes

*Status: master for the transition values — the host setting `runtime-mode`
(`in-process` | `daemon`), `LOOMWORKS_RUNTIME`, the editor option
`runtime.mode` (the editor observes the daemon in `daemon` mode, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)) — and the selection of
attached by `--no-daemon`, `LOOMWORKS_NO_DAEMON` and `CI`
(`daemon/runtime.lua`), and the editor's selection with lw's `runtime-mode`
setting and the source on its Runtime line (`runtime.editor_select`,
`observer.runtime_line`) — the editor's `daemon` default and
deprecated `in-process` mode below are step 5s (done), its single mode step
6b-β; the loopback transport and the attached server
(`daemon/loopback.lua`, `Server:start_attached` / `Server:adopt`,
`client.loopback_session`, `command.start_attached`) and the CLI's attached
routing of step 5e (`cli._attached_selected`, `cli._delegate_attached`)
implemented; the end-state values future.*

A command runs its operation in one of two ways:

- **Shared** — the client finds the workspace's daemon (§19.6) or launches one
  (§19.10), sends the request, renders the reply and streamed output, and
  exits. The daemon keeps running (§19.11).
- **Attached** (`--no-daemon`) — the client process runs the daemon code
  itself, over an in-memory **loopback transport** that carries the same
  messages through the same encoder/decoder and handlers as the pipe ([PROTOCOL.md §3–§4](../protocol/PROTOCOL.md)),
  minus endpoint and authentication. Nothing keeps running after the command.

Attached is selected, in this precedence: the `--no-daemon` flag; the
environment variable `LOOMWORKS_NO_DAEMON` (`1` selects attached, `0` selects
shared even in CI); `CI=true` in the environment; and, at run time, a failed
background launch (§19.10) — also the launch step itself failing with an error. Otherwise the command runs shared. An invalid configured value is
reported and ignored (falls through to the next source). There is no
`no-daemon` setting: during the transition `runtime-mode` takes only
`in-process` or `daemon` (below), and `in-process` uses no daemon at all
rather than selecting attached.

From step 6b-β the editor has one mode: it is a client of the workspace daemon
([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)). It never loads the workspace or runs an operation itself.
`LOOMWORKS_RUNTIME`, `LOOMWORKS_NO_DAEMON`, `CI`, lw's `runtime-mode` setting
and the former setup option `runtime.mode` do not apply to the editor; from
6b-β a setup value `runtime.mode` is reported once as ignored. *(Transition,
until step 6b-β: `daemon` is the editor's default, and of `runtime.mode` only
`"in-process"` is honoured — it selects the deprecated in-process editor, with
a deprecation note on the Runtime line. From step 6b-α the `daemon` mode
editor already loads no workspace of its own: what it shows and does comes
only from the daemon, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "End state".)*

**During the transition**, for the CLI, the setting `runtime-mode` takes `in-process` (the
default) or `daemon`, with `LOOMWORKS_RUNTIME` as the environment override. In
`in-process` mode no daemon is launched or used. In `daemon` mode every
workspace command ensures the daemon is running (launching it if absent)
— except read-only commands (§19.14), which never launch, stop or restart a
daemon; they use a live compatible one or read in-process — and routes the
operations that have moved (§19.19); all other operations run on the
in-process path. When the default flips, `in-process` is accepted as a
synonym of `no-daemon`.

**Loopback during the transition (§19.19 step 5e).** In `daemon` mode, an
attached selection — `--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI=true`, or a
failed background launch — runs the routed
operations (`lw build`, `lw test`, the preparation of `lw run`, `lw clean`,
`lw reset`; §19.15) attached: the client starts the daemon's server and build
service in its own process, holds the runtime lock in `attached` mode for the
command (§19.2), and sends the same request over the loopback transport. The
read-only commands (`lw status`, `lw profile show` / `query`, the read form of
`describe`, `project` / `config` / `configset` / `launch` list and show,
`config get`, `lw tools`; §19.13, §19.14) read the projection of a live
shared daemon when one is compatible (it authenticates and runs this lw's
version), and otherwise read in-process; never through the loopback. A read
never launches, stops or restarts a daemon and never takes the runtime lock;
a daemon that does not answer in time (a bounded wait, unanswered keepalive
pings) is left alone and the command reads in-process after a one-line note.
The
operations not yet routed (profile and project mutations, publish / import /
pull, devices — they need the command machinery of §19.14) and every
operation in `in-process` mode (still the default) run on the in-process path
and take no runtime lock. Three rules differ from a shared run:

- An attached `lw run` releases the runtime lock when its preparation task
  ends, not while the program runs (the program is the client's, §19.15 Run).
- `--break-locks` given with an attached selection runs attached too: its
  ask-and-kill recovery stays with the client process, which is the runtime.
  (When a live daemon holds the runtime lock, no attached runtime starts: the
  operation keeps its in-process path and its one `--break-locks` line,
  §19.15. In a shared selection `--break-locks` keeps its in-process path
  beside the daemon, as before step 5e.)
- An attached operation prints no `… through the workspace daemon (pid N)`
  line (§19.15): no daemon is involved.

The editor runs no loopback runtime during the transition ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)); its
attached mode arrives with the thin-client step (§19.19 step 5).

### 19.2 One runtime per workspace: the runtime lock

*Status: master for daemons (`daemon/rlock.lua`, the §19.5 record plus
`mode`, `command`, `host_version`; held by `daemon/server.lua` for its
lifetime, a held lock makes `lw daemon run` exit with status 3, a replaced
record makes the daemon exit 1); the attached runtime's side
(`Server:start_attached`: R in `attached` mode with the command, released on
stop without ending the process), its use by the CLI and the busy wait
(`cli._delegate_attached`, setting `runtime-busy-wait`) implemented.*

The **runtime lock** `<root>/.lw/daemon-<S>.lock` designates the
one runtime of a workspace for a slot (§19.7.1). It uses the build-directory lock primitive (§16.6): an
exclusive create and an mtime heartbeat (about 5 s); a dead or hung holder is
handled per §19.5. Its record is [formats.md](../formats.md) §6.2.

- A **daemon** acquires it before binding its endpoint and holds it for its
  lifetime. A daemon whose start finds the lock held by a live holder exits
  without side effects (the launching client then connects to the holder).
- An **attached** run acquires it for the duration of its command. If a live
  daemon holds it, the attached run does not start a runtime of its own: it
  connects to that daemon as a shared client (§19.1 decides only that nothing
  is *launched*), after the same version handshake as any client (§19.9): a
  busy daemon of another version makes the command a version-bypass run, and
  an idle one is stopped, but nothing is launched in its place — the command
  then runs attached. If another attached run holds it, the client waits briefly
  (setting `runtime-busy-wait`: `0`, seconds, or a number with `ms`, `s` or
  `m`; default 5 s) and then fails cleanly:

  ```
  lw: workspace busy: lw build (pid 4242 on HOST) is running here without a daemon — retry when it finishes
  ```

  Exit status 1. Never a second writer. Parallel jobs that must not wait for
  each other use separate checkouts. A hung daemon holder is reported as hung,
  not busy (§19.5). An attached holder whose process exists is reported busy
  even when its heartbeat is stale: a confirmation prompt (`lw reset`) blocks
  its event loop. Like any hung holder it is never reclaimed automatically,
  and `lw daemon stop` refuses it (no daemon).
- A **shared** selection (a routed operation in `daemon` mode) that finds the
  lock held by an attached run waits for it the same `runtime-busy-wait`, then
  fails with the same `workspace busy` line, exit status 1; when the attached
  run ends in time, the client launches or uses the daemon as usual. It never
  runs the operation beside the attached runtime.
- A holder that finds its lock record replaced (its lock was reclaimed while it
  was suspended) has lost authority: it stops at once, writes no workspace
  file, and exits nonzero. From the moment it notices, its workspace saves
  neither the cache nor the working copy — also a clean's wipe or a reset's
  deletion still stopping between entries (what such a deletion wrote before
  it started, its entries `unknown`, stays for the next runtime) — and no
  request not yet accepted starts. An attached run first cancels its running
  operation as Ctrl-C does (its steps' process trees killed), then ends the
  command with exit status 1 (`lw: the workspace runtime lock was taken over
  during the <op> — stopped`; for a root removed meanwhile, §19.11, `lw: the
  workspace root was removed during the <op> — stopped`). It never falls back
  to the in-process path — also not after a `lw reset` confirmation it was
  waiting on: nothing is reset.
- A holder on another host (shared or network drive) is respected while its
  heartbeat is fresh; it cannot be connected to or stopped from here (§19.11).

The in-process path (transition) does not take the runtime lock; it is
serialized against the runtime by the operation locks (§19.3). The single
exception after the transition is a **version-bypass run** (§19.9).

### 19.3 Operation locks

*Status: master — build-directory locks (§16.6), device locks (§18.7),
per-file save locks (§2.7) and the workspace operation lock, all with the
§19.5 record; the lock order R → O → B → D → F (R does not exist yet, §19.2);
`lw nuke` and the editor's deletions taking build locks. This is step 1 of
§19.19 and comes before any lifetime work.*

Every **mutating operation**, on any path (in-process, attached, daemon),
acquires **all** the locks it needs **before its first side effect**, in the
order below. If any lock cannot be acquired, it releases what it took and
refuses, naming the holder; nothing has been changed. Once it holds its locks
it either completes or leaves the state defined by §19.4 — never a mix of two
operations' effects. A daemon takes exactly the same locks as the in-process
path, so during the transition the two paths interoperate, and after it the
locks still guard against older versions and version-bypass runs (§19.9).

**Lock classes, outermost first:**

| # | Lock | Scope / file | Held | Acquisition |
|--|--|--|--|--|
| R | Runtime | `.lw/daemon-<S>.lock` (§19.2) | daemon lifetime / attached command | brief wait, then fail |
| O | Workspace operation | `.lw/op.lock` | one multi-file operation | fail-fast |
| B | Build directory | `<build dir>.loomworks-lock` (§16.6) | one build-directory operation | fail-fast |
| D | Device | per-serial, per-user (§18.7) | one remote operation | waits by default (§18.7) |
| F | File save | `<file>.lock` (§2.7) | the re-read + write, milliseconds | bounded retry (about 2 s) |

**Order.** A process acquires locks only in the order R → O → B → D → F, and
within a class in a canonical order: build directories by normalized identity
(§4.6 resolved real path, §2.3 normalization), devices by serial, files in the order
`loomworks.json`, `.lw/user.json`, `.lw/cache.json`. It never
acquires a lock of an earlier class, or an earlier member of the same class,
while holding a later one. Release order is free. Waiting (R briefly, D by
default, F bounded) is allowed only because it respects this order, so no
cycle — and no deadlock — is possible among compliant processes. An operation
that needs a lock it did not take up front (for example a remote run that
discovers it must rebuild) first releases every lock of a later class.

The **workspace operation lock** O is the O_EXCL + heartbeat primitive with the
common lock record of §19.5 ([formats.md](../formats.md) §6.1). It is taken by every
operation that writes more than one of the three workspace files, or that
removes a workspace file or a build tree as part of a larger change:

- publish and per-item publish (§2.4: published snapshot + working copy);
- import (§16.39) and working-copy pull (§16.25);
- renames that propagate into the cache (project, configuration, set,
  profile — a profile's key derived again when a toolchain is added or
  removed included; a launch configuration's rename writes only the working
  copy and is not one);
- profile / configuration deletion that removes build directories;
- reset, single-profile and all-scope (§16.30);
- nuke (`lw nuke`, the editor's nuke) — which additionally takes the **build
  lock of every build directory** it will remove, so it refuses while any build
  runs instead of deleting under it;
- `lw trust --discard` (§17.10).

Single-file working-copy mutations (profile select, project add, …) and a
build's cache write-back do not take O; the per-file stale-save guard (§2.7)
serializes them against a concurrent O holder, because the O holder's commit
re-checks every file under its F locks (§19.4) and refuses on a stale working
copy.

A refused acquisition is reported with the holder:

```
lw: workspace busy: publish (pid 4242 on HOST, 3s) — retry when it finishes
lw: cannot nuke: a build is running in build/debug (pid 4242) — wait for it, or stop it
```

The CLI exits 1 (the build-directory lock's existing exit codes are
unchanged); the editor shows an error notification. The refusal is one line
with one prefix. Nuke and `lw trust --discard` take (or check) their locks
**before** they list what they would delete or ask for confirmation, so a
refused one prints only its refusal: with `-y` / `--yes` the locks are held
from then until the deletion ends; a confirmation (the CLI prompt, the
editor's dialog) only checks them — taken and released, never breaking a
holder — and the locks are taken again once confirmed (`--break-locks` acts
then). The in-process editor's check passes over its own builds, which its
nuke stops before taking the locks; the daemon's nuke (`Maintenance/1.nuke`,
step 5o) passes over none of its own tasks — while any runs it refuses,
listing them. `lw unlock --workspace`
(and `lw unlock --all`, §16.6) also clears an O lock whose holder is gone, and
`--force` one whose holder runs; dead and hung holders of every class are
handled by §19.5 (`--break-locks`, accepted by every command above).

O is re-entrant within one process: an operation that holds it (`lw reset`,
in the CLI or in the workspace daemon, which takes O and then every build lock
before the workspace's deletion runs) may call another operation that takes it; the lockfile goes
with the outermost holder. Likewise a deletion skips the build locks its own
process already holds.

**Which build locks nuke and deletions take.** A deletion (profile delete or
reset, orphan delete, `lw reset`) takes the build lock of every build
directory its plan removes, after O, as a counted reference within its
process: an editor task on the same directory that the deletion cancels
releases only its own reference, so the lock stays until the removal ends.
`lw nuke` removes the whole `.lw/build/`; it takes the lock of every
directory under it that has a lockfile (`<dir>.loomworks-lock`, found by a
depth-bounded, link-free scan — a lockfile marks a directory some process uses
or used) and of every build directory of the loaded workspace there. Holding
them, it removes the build and health caches first (so nothing claims a
configured or built tree from then on), then renames `.lw/build` to
`.lw/build.nuke-<hex>` in one step and removes that tree, keeping its event
loop running so O keeps heartbeating. A build that starts once the locks are
gone creates a fresh `.lw/build`, never a directory inside the tree being
removed. A tree left aside by a nuke that crashed (a real directory directly
in `.lw/` named exactly `build.nuke-<hex>`) is removed by the next nuke.
Where the rename is impossible (a file in the tree held open on Windows), nuke
refuses after removing the caches, leaving the tree: removing it in place
would let a build that starts once the locks go write into a tree being
deleted. The editor's nuke first stops its own tasks and unloads its
workspace (which then writes nothing), so its own build neither keeps writing
into the tree nor recreates the cache; the operation lock is held until the
removal has really ended.

A build lock that a task of the same process already holds is taken by a
deletion as a counted reference, not acquired again, so the editor's deletion
— which takes O while its own task may hold the directory's build lock — never
waits on itself and cannot deadlock (every cross-process acquisition is
fail-fast). `Workspace:teardown` lets an in-flight deletion finish (bounded)
before it releases that deletion's locks.

### 19.4 Crash-consistent multi-file commits

*Status: master (step 1 of §19.19).*

A multi-file operation commits its file changes with a **journal**, so that a
crash at any point leaves either the old state, the new state, or a marked
state every compliant reader completes to the new state before using the
workspace.

**Commit**, holding O and the F locks of every file involved (in order):

1. **Check.** Re-read each file and apply the stale-save rules of §2.7: a stale
   working copy refuses the whole operation (nothing written); a stale cache is
   merged first.
2. **Stage.** Write each new file content to `<file>.txn-<id>` beside the
   target and flush it to stable storage. A removal has no staged file. The
   staged bytes are final — signed where the file is signed (§17.3).
3. **Commit point.** Atomically write the journal
   `<root>/.lw/txn.json` ([formats.md](../formats.md) §7).
4. **Apply.** For each entry in order, rename the staged file over the target
   (or remove the target), then flush the directory where the platform
   supports it.
5. **Finish.** Remove the journal, then release the locks.

| Crash during | On disk | After recovery |
|--|--|--|
| 1–2 | old files + stray `*.txn-*` | old (stray files removed) |
| 3 (journal write) | old files; journal absent or its temp | old |
| 4 | some targets new, some old; journal present | new |
| 5 | new files; journal present | new (journal removed) |

**Recovery.** A process that loads the workspace, or acquires O, and finds a
journal first checks O: while the journal's writer still holds a live O lock (§19.5)
the commit is in progress, and the reader waits for it (bounded, as for F) or
reports the workspace busy. Otherwise, holding O, it **rolls forward**: per
entry, a target whose hash already equals `sha256_new` (or an absent target
for a removal) is done; a staged file whose hash equals `sha256_new` is renamed
over the target; a removal removes a target whose hash equals `sha256_old`. It
then removes the journal and stray staged files and reports once:

```
lw: completed an interrupted publish (pid 4242 crashed) — .lw/user.json, .lw/cache.json
```

An entry whose target matches neither hash (another writer that ignores
journals changed it) or whose staged file is missing is left untouched; the
workspace is then **refused** (as a §15 invariant 11 refusal) with the journal
named and the remedy to discard it (`lw unlock --journal`). Nuke is not a
remedy: it acquires O, which completes or refuses the journal first, and it
resets only build state — the journal also covers `loomworks.json` and the
working copy.

**Failed apply.** A writer whose apply step (4) fails without crashing rolls
its own journal forward as above at once, still holding O: when that
completes, the operation is committed (and reported so); only when it cannot
be completed does the operation fail, its in-memory change dropped by
reloading the files, and the journal stays for the next O holder. A write
reported as failed thus never lands later unless the files already show it.

**Validation.** Moved to [formats.md](../formats.md) §7: a journal that fails
it refuses the workspace as above. Rolling forward never bypasses trust — the
renamed files are verified on load as any file is (§17.4).

**Implementation notes (master).** The operations that hold O commit through a
transaction: every write of one of the three files during it is staged (and
reads of a staged file in that process see the staged bytes), and the
transaction commits when the operation returns. The F locks of all three
files are held from the transaction's start to its end (they are held for
milliseconds: the operations are synchronous). A commit that touched one file
needs no journal — the rename is the commit point. Before the commit point the
holder checks that the O lockfile still carries its own record (fencing): a
holder whose O was reclaimed while it was suspended, or removed with
`lw unlock --force`, has lost authority — its staged files are removed and
nothing is written. An operation that reports failure commits none of its
staged writes, and a deletion whose working-copy / cache commit fails removes
no build tree. An ordinary save's
`.bak` copy is kept: step 4 renames the target to `<file>.bak` before renaming
the staged file over it, so a crash between the two leaves the target absent,
which recovery completes like a target with the old content. Recovery runs
when a process loads the workspace (the editor and every `lw` command) and
whenever a process acquires O; stray staged files (`<file>.txn-<hex>`, regular
files beside the three targets, and the journal's `.tmp`) are removed only by
an O holder. `lw unlock --journal` takes O without completing the journal and
removes exactly the journal and those stray files.

**Build trees.** Removing build directories (nuke, reset, deletion) is not
journalled; it keeps the existing crash rule — cache entries are marked
`unknown`/deleting before the removal starts and removed only after it
succeeds (§5.7, §15 invariant 1) — and the cache change that follows is then
committed as above.

**Older versions** neither take O nor read the journal; one that reads a
workspace between a crash and the next recovery can see a partially applied
commit. This is the same class of residual race as §2.7 "Remaining race".

### 19.5 Recovery from dead and hung holders

*Status: master for build-directory, device and file-save locks (B, D, F): the
record, the classification, the state recovery, `--break-locks` and
`lw unlock --force`; the operation lock O (step 1 of §19.19); the runtime
lock R (`lw daemon stop --force` / `kill`, `daemon/command.lua`; in `daemon`
mode a workspace command given `--break-locks` recovers a hung daemon the same
way before relaunching it). Kills and forced unlocks are recorded in the
runtime log (§19.10).*

A crashed or killed process must never leave a workspace stuck, and a hung one
must be recoverable with one command. These rules apply uniformly to every lock
of §19.3 (R, O, B, D, F) and to the handle file and socket (§19.6–§19.7).

**Lock record.** Moved to [formats.md](../formats.md) §6.1: the record's
fields, `start_time` and the daemon instance id, and how a lock file is
created, rewritten and read.

**Holder states.** A process that finds a lock held classifies the holder:

| Holder | Test | Handling |
|--|--|--|
| **dead** | same host, and no process with that id **and** start time exists | reclaimed at once, automatically |
| **live** | same host, process exists, heartbeat fresh — or other host, heartbeat fresh | busy: fail-fast / wait per §19.3 |
| **hung** | same host, process exists, heartbeat stale | **not** reclaimed; reported as hung with the recovery command |
| **stale foreign** | other host, heartbeat stale | reclaimed automatically (the host cannot be checked; heartbeat rule of §16.6) |

The heartbeat runs on the holder's event loop, so a blocked or suspended
process stops heartbeating; a hung holder is never reclaimed automatically,
because it can resume and write. This replaces, for same-host holders, the
unconditional stale-heartbeat reclaim of §16.6. Reports:

```
lw: build/debug is locked by a hung lw build (pid 4242, no heartbeat for 2m) — recover with: lw build --break-locks
lw: the workspace daemon (pid 4242) is not responding — recover with: lw daemon stop --force
```

Reclaiming is an atomic rename of the record, done only if the record still
carries the nonce the reclaimer observed. A daemon's handle and socket are
removed by whoever reclaims its runtime lock.

**`--break-locks`.** Every command that acquires a lock of class R, O, B or D
accepts `--break-locks` (and `--break-locks=now`). When an acquisition finds a
**hung** or a **live, responsive** same-host holder, the command recovers right
away instead of refusing — a live holder is asked first and killed if it has not
let go within the wait:

1. **Ask.** A daemon holder is sent `stop` (frozen control subset, [PROTOCOL.md §7](../protocol/PROTOCOL.md), so it
   works across versions); a non-daemon `lw` holder is sent the interrupt it
   handles (§16.6) where the platform allows signalling it. Wait a bounded time
   (about 5 s). `--break-locks=now` skips this step.
2. **Kill** — only once the process the record names is verified to be such
   a holder: its command line (Windows: the process's command line; Linux:
   `/proc/<pid>/cmdline`; macOS: `KERN_PROCARGS2`) is an `lw` host — the `lw`
   binary (a cached executable is named `lw` too, §16.40), a release host under
   its download name (`lw-linux-x86_64`, …) or, *transitionally*, a legacy
   pinned copy `lw-<version>-<asset>` (§16.40); `luvi` running the loomworks
   app (a source directory named `lua`, or *transitionally* `lua-<version>`,
   which when given as an absolute path must hold `loomworks/cli.lua` — a
   `luvi` running any other app is not an `lw` host); or the nvim-hosted
   `nvim … -l …/loomworks/cli.lua` — and, for a daemon holder,
   `lw … daemon run` (for this workspace when it names one with `--root`).
   A record is data from a shared directory: one naming an unrelated process
   of the user is refused (the process is never signalled), as is a holder
   whose command line cannot be read; the remedy is to remove the record
   without stopping anything. Then kill the holder's process tree — the
   daemon's process group, or the holder and its enumerated descendants (on Windows a forced tree
   termination).
3. **Verify** that no process with the holder's id and start time remains;
   otherwise fail and name the process.
4. **Reclaim** each lock whose record still carries the observed nonce.
5. **Recover state.** Roll a journal forward per §19.4. For each build
   directory the killed holder held, by the step its lock record names:
   - **configure** — its units reset to `unconfigured` in the cache (the
     directory is kept), so the next build reconfigures (§5.1): a half-written
     configure cannot be trusted;
   - **build** (configure had completed) — its units are marked not built
     (`configured`); the configure record is kept and the build tool's own
     up-to-date checks decide what to rebuild — no forced reconfigure;
   - **deletion** (clean, reset, delete, nuke) — keeps the `unknown` state its
     deletion already recorded (§5.7).
6. **Run** the requested operation normally, acquiring its locks as usual.

`lw daemon stop --force` is steps 1–5 against the runtime lock;
`lw daemon kill` is the same with step 1 skipped. Plain `lw daemon stop`
never kills (§19.11).

**Limits.**

- **Never another host.** A holder on another host is never signalled or
  killed: the command refuses and names the host (`run lw daemon stop there`).
  `lw unlock --force <lock>` removes a lock record **without** killing anything,
  after printing that the holder may still be running and writing.
- **Never the editor.** A lock held by an editor process (holder kind
  `editor`) is never signalled or killed: `lw: build/debug is held by nvim
  (pid 4242) — cancel the task there, or break the lock without killing it:
  lw unlock --force build/debug`.
- **No bypass.** Breaking locks never bypasses workspace trust (§17) or
  deletion safety (§15 invariant 3); the requested operation is checked as
  usual.
- **Non-interactive.** `--break-locks` works with `--no-input` (CI recovery);
  every kill and every forced unlock is printed on standard error and recorded
  in the runtime log (§19.10).

`--force` is not reused: on `lw build` it already overrides an output-artifact
conflict (§5.9, §16.28), and an unrelated meaning would make one flag do two
dangerous things.

**Known limitations.**

- On Windows an `lw` holder in another console cannot reliably be sent an
  interrupt, so step 1 is effectively skipped there for non-daemon holders and
  recovery goes straight to the kill.
- The process start time needs per-OS code (Windows `GetProcessTimes`, Linux
  `/proc/<pid>/stat`, macOS `proc_pidinfo`); where it is unavailable, holders
  on that host are judged by heartbeat alone (a dead holder is then reclaimed
  only after the heartbeat window, and a hung one is indistinguishable from a
  dead one).
- A process tree is enumerated by parent process id. On Windows that reaches
  native children only: a grandchild started through an MSYS/Cygwin shell
  (for example `sleep` under Git's `sh`) has no Windows parent link to the
  holder and survives the kill.
- A holder is identified by host name, process id and start time. Processes
  in different PID namespaces that report the same host name (containers
  sharing a hostname, or sharing a checkout over a bind mount) are not told
  apart: a holder in another namespace looks dead (its id is unknown here) or,
  if the id is taken, like a different process — its lock is reclaimed. Give
  such containers distinct host names, or do not share one checkout between
  them.
- `--break-locks` never signals the calling process or any of its ancestors;
  descendants are signalled only while they are still the process seen in the
  snapshot (same id and start time).

**Required tests.**

- The daemon killed (`SIGKILL` / forced termination) mid-build: the next
  command reclaims the runtime and build locks automatically; killed during
  configure, the units read `unconfigured` and the next build reconfigures;
  killed during the build step, they read `configured` and the next build does
  not reconfigure.
- The daemon suspended (`SIGSTOP` / suspended threads): the next command
  reports it as hung, not busy; `--break-locks` recovers and the suspended
  process is gone.
- A process killed at each step of §19.4 (after staging, after the journal,
  after each rename, before journal removal): the next load yields the old or
  the new state, never a mix.
- A lock record whose process id now belongs to a different process (start time
  differs): treated as dead, the unrelated process is never signalled.
- A lock record from another host: never killed; refused with the host named;
  `lw unlock --force` removes it with the warning.
- An editor-held lock: never killed; refused with the editor message.

### 19.6 Discovery: the handle file and the Runtime row

*Status: master — the handle (`daemon/handle.lua`, written and heartbeated
by `daemon/server.lua`), the Runtime row and `lw daemon status`; the running-task
lines (`daemon/running.lua`).*

A daemon publishes its handle `<root>/.lw/daemon-<S>.json`
(its slot's, §19.7.1; [formats.md](../formats.md) §8) after binding its endpoint. It
refreshes the file's modification time on its heartbeat and rewrites it when
`clients`/`busy` change. Liveness is judged by the heartbeat, never by probing
the pid (§16.6). The handle is **discovery only**: the runtime lock (§19.2)
decides who the runtime is, and the handshake ([PROTOCOL.md §5](../protocol/PROTOCOL.md)) decides whether a client
may use it. A malformed handle is reported as unreadable, never as a live
daemon. A daemon that finds its handle removed while it runs rewrites it.
A rewrite stages the new file and renames it over the handle; on Windows that
rename fails while another process has the handle open (a client reading it,
an indexer, a scanner — opening it with delete sharing does not help: only a
rename's source may be open), so each rewrite retries it with backoff for a
bounded time (the daemon's own loop for about a quarter of a second). A
rewrite that still fails leaves the previous handle in place, never a partial
one, and removes its staged file; the daemon then rewrites again on a backoff
(up to about a second apart) and on every heartbeat until a rewrite succeeds,
so clients never keep reading an outdated `clients`/`busy`, and notes it in the
runtime log only once it has kept failing for a few seconds. The heartbeat
still refreshes the published file's time meanwhile. A record identical to the
one last written is not rewritten.

**Legacy files.** `.nvim/loomworks.daemon.json`, `.lock` and `.log` (lw before
slots), and this slot's `.nvim/loomworks.daemon-<S>.json`, `.lock` and
`.log` (lw 0.1.x, before the move to `.lw/`), are never read to connect to a
daemon. A legacy runtime lock — the unslotted one, or this slot's
`.nvim/loomworks.daemon-<S>.lock` —
whose holder is a live daemon of this slot (§19.5 identity rules) is a
daemon of another version (§19.9). It is stopped before this slot's daemon
starts, and by `lw daemon stop` (with or without `--force`), `kill` and
`restart`, in the same way (asked, then its tree killed and verified gone).
These commands report it ("stopped the workspace daemon of an earlier lw
(pid N)"), and stopping it alone counts as stopping a daemon. `lw daemon
status` reports it on its own line, `daemon of an earlier lw (pid N,
.nvim/<lock name>) — stop it with: lw daemon stop`, and never connects to
it. A holder of another slot, an attached run, or a hung, dead or foreign
holder is not stopped by these commands. Housekeeping, `lw daemon stop` and `lw cleanup` remove the
unslotted lock and handle only as a reclaimer would (§19.5: holder dead, these exact
regular files) and the unslotted log only as a leftover (these exact regular
files, `.log` and `.log.1`). This slot's `.nvim/loomworks.daemon-<S>.*` files
are never removed, whatever their holder's state: stopping their daemon
needs no removal (the older lw's own exit or reclaim handles them, and the
move to `.lw/` copies none of them). A process removes only its own slot's files
and the unslotted legacy names; another slot's files are never touched.

**Runtime row.** `lw status` shows one `Runtime` line computed **only** from the
handle and the runtime lock — it never launches or connects (the running-task
lines below may connect, never launch):

```
Runtime   daemon pid 4242, 2 clients, idle 12m
Runtime   daemon pid 4242, v0.1.43 (this lw is v0.1.44 — restarts when idle)
Runtime   daemon on OTHERHOST (pid 4242)
Runtime   attached: lw build (pid 4242)
Runtime   no daemon (starts on the next command)
Runtime   in-process
Runtime   stale daemon handle (pid 4242, 3h ago) — the next workspace command recovers it (daemon mode), or lw daemon stop
Runtime   daemon pid 4242 is not responding (no heartbeat for 2m) — lw daemon stop --force
Runtime   daemon pid 4242 (starting)
Runtime   unreadable daemon handle — the next workspace command recovers it (daemon mode), or lw daemon stop
```

`no daemon (starts on the next command)` is shown in `daemon` mode,
`in-process` in `in-process` mode, when neither the runtime lock nor a handle
exists.

**Running tasks.** Under the Runtime line, `lw status` lists the daemon's
running tasks, one line each: the operation (`kind`), the profile, the origin
(`lw` for `cli`, `editor`), the elapsed time since `started_at`, and the
percent when known:

```
Runtime   daemon pid 4242, 2 clients
  build  Debug:ninja-gcc   (lw)      1m12s  43%
  test   Release:msvc-17   (editor)  8s
```

A `reset --all` task (`meta.scope = "all"`, no
profile, §19.15 Reset) shows `--all` in the profile column.

It asks only a daemon the handle shows live, on this host, busy (a running
task makes it busy, §19.11) and with this lw's `key_id` — so an idle daemon
is never contacted — by connecting, authenticating and sending `status`
(§19.11), with a bound of about a second; it never launches one. `status` is
in the frozen control subset (§19.8), so this works across a version
mismatch, and the connection is never a `retire`. A reply without `tasks` (an
older daemon) shows `  running tasks: not reported by daemon lw <version>`; a
failed or timed-out query shows one line, `  running tasks: unavailable
(<reason>)`. The same reply's `tasks` also mark the profiles and units they
resolve to as running in the profile list's build state (§16.18), as the
editor shows an observed task ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client); a task without a profile, a `reset
--all`, marks every profile that has one of its units); nothing else of `lw status`'s output,
and never its exit status, depends on the query. `lw status` has no machine-readable (`--json`) form, so there is none
to extend.

#### 19.6.1 Listing every daemon of this user

*Status: master — `daemon/discover.lua` (the scan), `proc.processes`,
`lw daemon list`, `lw daemon stop --all` / `kill --all [--strays]`, the
`lw health` count line.*

`lw daemon list` lists every workspace daemon of the calling user **on this
host**, in any workspace, run from anywhere (no workspace needed). It is found
by a **process scan** — there is no per-user registry: lw writes nothing
outside the workspaces for it, so a crash or a power loss leaves no file to go
stale. It never launches, connects to or signals a daemon, and writes nothing.

**Scan.**

1. Enumerate the processes of this host with their executable names —
   Windows: one Toolhelp snapshot (`szExeFile`); Linux: `/proc/<pid>` entries
   **owned by the caller's uid** (name from `comm`); macOS: `proc_listallpids`
   + `proc_name` (fallback `ps -x -o pid=,comm=`).
2. Keep the candidates whose executable base name (lowercased, without
   `.exe`) is `lw`, starts with `lw-`, or is `luvi` or `nvim` — the hosts of
   §19.5 step 2. This process is skipped.
3. Read each candidate's command line (§19.5: Windows the process command
   line, Linux `/proc/<pid>/cmdline`, macOS `KERN_PROCARGS2`) and its start
   time; keep those that are `lw … daemon run` by the §19.5 identity rules. A
   command line that cannot be read is skipped, and so is a process of
   another slot (§19.7.1: on Windows its token's user SID or elevation differs,
   or the token cannot be read; on POSIX its effective uid differs) — an
   elevated or root caller can read every process but lists, stops and kills
   only its own slot's daemons. A kept process that is the parent of another kept process with
   the same `--root`, which started no earlier than it, is a pin redirect's
   wrapper (§16.23: the invoked lw waiting on the pinned `daemon run`), not a
   daemon, and is dropped — it is never listed, and never stopped or killed
   as a stray (killing its tree would kill the live daemon).
   *(Step 5i, `discover.is_relay` on the dispatch's own `stdio_form`.)* A
   `lw … daemon run --stdio` process is classified
   by the runtime lock R of its `--root`: when R names it (pid and start
   time), it is still a **runtime** — the attached `--stdio` of a repository
   pinned to a release before 5i (§19.10 "Connections", "Compatibility"), or
   the gated test-only `--stdio --private` runtime, which takes R with its
   pid and start time like any runtime (§19.10 "Tests"; with no handle it is
   listed as `starting`) — and is listed and treated as a daemon like any
   other. Any other `--stdio`
   process (and its pin-redirect wrapper) is a **relay** (§19.10
   "Connections"), never a daemon: it is listed as a connection under the
   daemon of its `--root` (counted in that row's clients, and in `--json` as
   `relays = [ { pid, start_time } ]` on that daemon's entry), never as a
   daemon row or a stray, and never stopped or killed — `kill --all --strays`
   skips it. A relay whose root has no listed daemon (it is connecting,
   launching, waiting on a retiring daemon, or a `--no-launch` relay waiting
   for one) is not listed.
   This is decided on R alone, so an attached `--stdio` runtime of a release
   before 5i that R no longer names — R taken over by another runtime,
   unreadable, or its root deleted — is classified as a relay: it is not
   listed (not as a stray either), and `kill --all --strays` (and
   `kill_stray` on it) refuses it. That is the accepted cost of never acting
   on a connection: end such a process with the operating system's tools.
4. The daemon's workspace is its `--root <dir>` (or `--root=<dir>`) argument —
   every launched daemon has one (§19.10). One run by hand without it is
   listed with **root unknown**.

The scan is bounded by the number of processes; the command lines read are
only the candidates'. It takes tens of milliseconds for a few hundred
processes; `--json` reports the time it took.

**Classification.** For each daemon with a root, its runtime lock R (§19.2)
and handle (§19.6) are read — files only:

| State | Test |
|--|--|
| `live` | R names this process (pid and start time) and the handle names it too; clients, busy, idle time and version come from the handle |
| `starting` | R names it, no handle yet; or R is absent and the process started less than 30 seconds ago (a daemon takes R first thing — until then it is starting, not a stray) |
| `hung` | R names it and its heartbeat is stale (§19.5) |
| `stray` | R names another holder or none, the handle names another process, or the root directory is gone — a daemon that is not its workspace's runtime (it lost its lock, is exiting, or was left over); never connected to |
| `unknown root` | no `--root` on its command line |

A daemon whose handle names it is also marked by its key: `same_key` is false
when the handle's `key_id` (§19.6) is not this lw's — a daemon of another
loomworks data directory — and null when the handle has no `key_id` (an
older daemon) or does not name it. Computing this lw's key id only reads the
machine key; none is created.

A handle or lock record that names a process the scan did not find (dead, or
its pid reused by another program) produces no entry: the list shows
processes, not files. A daemon on another host is not on this host's process
list; its workspace's `Runtime` row shows it (§19.6).

**Output.**

```
PID    UPTIME  STATE           CLIENTS  VERSION  ROOT
4242   2h      live, idle 12m  0        0.1.43   /home/me/src/app
4310   5m      live, busy      1        0.1.43   /home/me/src/lib
4388   1m      stray           -        -        /tmp/old-checkout  (the runtime lock names pid 4401)
4410   3m      live, idle 3m   0        0.1.43   /tmp/test-ws  (other data dir)
4 daemons (2 idle, 1 stray, 1 other data dir) — stop them with: lw daemon stop --all
```

There is one row per daemon — exactly the entries `--json` prints for the
same scan — and the summary counts those rows. Every column is filled: `-`
where the value is unknown (the clients and version of a daemon whose handle
does not name it; an uptime whose start time cannot be converted). STATE is
the state above (`unknown root` for `unknown_root`); a `live` daemon adds
`busy` or `idle <time>` (with clients, plain `live`). A daemon that is not
`live` or `hung` has its reason after the root, and one of another data
directory `other data dir`. A development build's version is shown with its
source fingerprint cut to 8 hex digits (`--json` has it whole).

No daemon: `no workspace daemons are running`. `--under <dir>` keeps the
daemons whose root lies under `<dir>` (separator-bounded, case-insensitive on
Windows); a daemon with an unknown root is then left out. `--json` prints
`{ schema = 1, scan_ms, daemons = [ { pid, start_time, root, state, reason,
uptime_s, started_at, clients, busy, idle_since, lw_version, protocol,
endpoint, same_key, relays } ] }` (absent values are `null`; `relays` is
always an array, step 3), sorted by root.

**Stopping all.** `lw daemon stop --all [--force]` and `lw daemon kill --all`
(each accepting `--under <dir>`) apply `lw daemon stop [--force]` /
`lw daemon kill` (§19.11, §19.5) to the workspace of every `live`, `starting`
or `hung` daemon listed — through that workspace's runtime lock, with all its
rules: never another host, never an editor holder, plain `stop` never kills,
a kill only of the holder its lock record names, identity-verified. One line
per daemon, prefixed with its root. A **stray** or **unknown root** daemon is
not its workspace's runtime and cannot be asked to stop: it is skipped with a
hint, unless `lw daemon kill --all --strays` was given, which kills it — only
after its command line is read again and is still `lw … daemon run` for that
root (or with no `--root`, for an unknown root) with the same start time,
never this process or one of its ancestors; if it held its workspace's runtime
lock, the lock is then reclaimed per §19.5. `--strays` is refused without
`kill --all`. A daemon of **another data directory** (`same_key` false) is not
this lw's: `stop --all` and `kill --all` skip it with `<root>: daemon pid <pid>
belongs to another loomworks data dir (different key) — skipped` and never
connect to it (`kill --all --strays` still kills such a daemon when it is a
stray, as above). A daemon whose handle has no `key_id` and whose handshake
then does not verify is reported and skipped the same way, as one that did not
prove this lw's daemon key. Neither counts as left running: the exit status
is 0 when none of this lw's listed daemons is left running, 1 otherwise.

**Health.** `lw health` (area `lw`) shows one informational line when this
user runs any daemon on this host: `2 workspace daemons running (1 idle) —
lw daemon list`.

### 19.7 Endpoint and access control

*Status: master (`daemon/endpoint.lua`; the DACL through LuaJIT FFI).*

The endpoint is a trust boundary — a peer that can issue commands can run
builds, i.e. execute code as the owner — so it is restricted by the operating
system **and** gated by authentication ([PROTOCOL.md §5](../protocol/PROTOCOL.md)).

- **POSIX:** a Unix-domain socket in a short per-user directory created `0700`
  and verified to be owned by the caller's effective uid
  (`$XDG_RUNTIME_DIR/loomworks`, else `$TMPDIR` / `/tmp` with a
  `loomworks-<euid>` directory). "Owned by the caller" below means by its
  effective uid. The socket is named by
  a short hash of the normalized workspace root, so the path fits the `sun_path`
  limit (about 104 bytes on macOS, 108 on Linux) regardless of repository depth.
  A stale socket file is unlinked by a daemon or client only while holding
  the runtime lock. Outside that, only housekeeping and `lw cleanup` remove a
  socket, under the conditions of §16.40 (it refuses a connection, is older
  than an hour, and is put back if a daemon bound the name meanwhile).
- **Windows:** a named pipe whose name contains a hash of the slot token *S*
  (§19.7.1) and the workspace root. Immediately after creating it, the daemon replaces its
  security descriptor (`SetSecurityInfo` through the host's foreign-function
  interface) with a protected DACL granting full access to the owner's SID and
  `SYSTEM` only and an explicit deny for the `NETWORK` SID. A daemon that cannot
  apply the DACL does not serve and exits with an error.
- **Peer check (Windows).** The daemon checks each accepted connection, and
  a client the pipe it connected to, before any frame: the peer process
  (the pipe's client or server process) must run with this process's user
  SID and elevation. A peer whose token cannot be read is refused. This,
  not *K*, keeps a standard process from an elevated daemon and an elevated
  client from a daemon (or a squatter) of the standard slot. (POSIX needs no
  extra check: the euid-owned `0700` directory admits only that euid and
  root, and a client accepts only a socket owned by its own euid.)
  It is the only barrier between the two slots of one user: both have the
  same owner SID, so the DACL admits both. The check names the peer by its
  process id, and an id can be reused between the connect and the check. If
  the peer exits in that window and another process of the same user gets
  its id, the check judges the new process. The window is accepted: the
  endpoint is local and owner-only, and a reused id must also belong to this
  user.
- **Local only.** An endpoint is a local pipe or Unix-domain socket of the
  caller's slot on this host. The protocol is never served or connected to
  over a network, nor across users or elevation.

Clients read the address from their slot's handle, and use it — for any
connection, including the running-task lines of `lw status` — only when it
is an address a daemon of this workspace and slot binds — on Windows exactly the pipe name
above; on POSIX one of the per-user socket paths of the client's own
environment, or — since the daemon binds the first path of the environment
that launched it, which a client from ssh, cron, `sudo -u` or a container may
not share — any `<dir>/<root hash>.sock` named for this workspace where `dir`
is a real directory (not a link) owned by the caller with mode `0700` and the
file is a socket owned by the caller, whatever the current environment. A
socket is removed only under the same conditions. Any other address (a
remote `\\host\pipe\…`, another user's socket) marks the handle as
untrusted: nothing is connected to, and the command says so. The handle sits
in a `.lw/` other local users may be able to write; connecting to a remote
pipe would hand the user's credentials to that host.

#### 19.7.1 Runtime slot

Runtimes are separated per **slot**: the operating-system user and, on
Windows, whether the process token is elevated. Its identity string *I* is
the user's SID and `elevated` or `standard` (from the token's elevation) on
Windows, and the decimal effective uid on POSIX (root is its own slot). The
**slot token** *S* is the first 16 hex digits of
SHA-256(`loomworks-daemon-slot-v1` ‖ LF ‖ *I*), computed once per process.
*S* is opaque: it is only ever computed and compared, never parsed, listed
or derived from a file name. Two slots never share a runtime lock, handle,
log or endpoint, and never connect to each other; work on one workspace from
two slots is coordinated only by the operation locks (§19.3) and
crash-consistent commits (§19.4). Separation across slots is enforced by the
operating system (§19.7), not by *K*: an elevated and a standard process of
one user share the machine key.

### 19.8 Wire protocol and authentication

*Status: master for framing, authentication, the frozen control subset, the
envelope and the root object (`daemon/protocol.lua`, `daemon/auth.lua`,
`daemon/server.lua`, `daemon/client.lua`, `daemon/interfaces.lua`,
`proto/envelope.lua`); transport 1. Pre-0.2.0 pre-releases used transport
numbers up to 11 and are incompatible; versions share no range, so the client
treats them as incompatible daemons.*

**Wire protocol.** Framing, the mutual authentication handshake
(`hello` / `challenge` / `auth` / `welcome`), the pre-authentication limits
and the private bindings that skip authentication are specified in
[PROTOCOL.md](../protocol/PROTOCOL.md) §3–§5, §7.

**Authentication key.** The shared secret *K* of the handshake and the
endpoint address *E* are [API.md](../protocol/API.md) §2: *K* derived from
the machine key (§17.2), *E* the handle's `endpoint` (§19.6) verbatim. The
`hello.client` and `role` values are [API.md](../protocol/API.md) §2 (an
observer is [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)). The `welcome` fields are `{ header, seq, clients, busy, retiring }` (§19.13) plus
the transport's `objects` (§19.20). New `welcome` fields go inside `header`
if they are model fields, and beside it if they are transport fields (such as
`objects`, or the relay's `daemon`, `via` and `relay` below).

**Private bindings.** The loopback transport (§19.1) is the in-process
private binding of PROTOCOL.md §3; it never leaves the process. The private
standard-I/O transport (`lw daemon run --stdio --private`, tests only, §19.10
"Tests", §19.20) is its standard-I/O binding. Closing the daemon's standard
input ends that connection and stops the runtime: as for any disconnect
(§19.15), the tasks the connection owns are cancelled, and the process exits
once they ended (a process that spawned it and goes away leaves no build
running). The socket transport keeps the challenge.
*(Step 5i, `daemon/relay.lua`: `lw daemon run --stdio` is a **connection**, never a
daemon — §19.10 "Connections". It connects to the workspace's shared daemon
over the socket (starting it first if none runs), authenticates there with the
challenge as any client, and then relays frames opaquely between its standard
input/output and that connection; its own client still sends `hello` first
and gets `welcome`. Closing its standard input closes only that connection:
the tasks it owns are cancelled (§19.15), the daemon keeps running. The
private-pipe server described above then remains only for the conformance
runner's fresh, isolated daemon, behind the hidden, gated `--private` flag
(§19.10 "Connections", "Tests") — never a user-facing attached mode, and
unreachable without that gate.)*

**Relay handshake.** *(Step 5i, `daemon/relay.lua`.)* The relay's client sees the
standard-I/O handshake of [PROTOCOL.md](../protocol/PROTOCOL.md) §3 (`hello` first, then `welcome`, no `challenge`); the
relay runs the socket handshake on its behalf:

1. The relay reads the client's `hello` from standard input **first** —
   before it discovers, launches or connects to anything — so the daemon's
   5 s authentication deadline never covers a launch. Anything other than a
   `hello` first, or none within about 5 s, ends the relay (exit status 15,
   §19.10 "Relay exit status").
2. It then connects (launching first if needed, §19.10) and sends the socket
   `hello` with that hello's `protocol`, `protocol_min`, `lw_version`,
   `schemas`, `client` and `role`, and a nonce of its own (the client's
   nonce is not used).
3. It verifies `server_proof` before forwarding anything; on failure it
   sends nothing more on either side and exits (status 12). It then sends
   `auth`. `challenge` and `auth` never reach its client.
4. It forwards the daemon's `welcome`, adding three fields, and from then on
   copies frames both ways unchanged:
   - `daemon = { protocol, protocol_min, lw_version, schemas,
     session_generation, pid, start_time, exe? }` — the daemon's side of the
     handshake, taken from the `challenge` the relay verified (`pid`,
     `start_time` and `exe` from the handle it connected through, §19.6;
     `pid` and `start_time` identify that daemon instance, as for a lock
     holder, §19.5, so a client can name it to `--skip-instance`, §19.10 "No
     launch"; `start_time` is absent when the handle carries none, and such
     a daemon cannot be named, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Skipping an incompatible daemon";
     `exe` for display only, absent when unknown). The client
     applies its version rules (§19.9) to these, as it would to a
     `challenge`.
   - `via = "relay"`. A client that gets a `welcome` without `via` is
     talking to an attached runtime (a repository pinned before 5i): the
     editor treats it as such and never sends `retire` over it.
   - `relay = { lw_version }`: the relay's own code identity (§19.9), which
     is the identity of the daemon it would launch. A client weighs a
     daemon's identity against it (§19.9 "Editor retirement").

   All three are optional fields added to `welcome`, as the frozen-subset rule
   ([PROTOCOL.md](../protocol/PROTOCOL.md) §7) allows; an attached runtime omits them.
5. When the `welcome` says `retiring`, the relay does not forward it: it
   closes that connection, waits for the retiring daemon's runtime lock to
   be released — at most `RELAY_RETIRE_WAIT` (60 s) — launches the
   successor (§19.10) and repeats from step 2. A daemon still holding the
   lock after that bound ends the relay with status 14, its standard error
   naming that daemon (§19.10 "Relay exit status"). A `--no-launch`
   relay instead keeps waiting without a bound and never launches the
   successor (§19.10 "No launch").

**Frozen control subset and the protocol number.** Which messages never
change shape, and what the `protocol` number versions — the transport only,
with each side stating a range `[protocol_min, protocol]` — and the
versioning policy are specified in [PROTOCOL.md](../protocol/PROTOCOL.md) §6–§7. *(Planned, step 5i.)* The relay's
`welcome.daemon`, `welcome.via` and `welcome.relay` (above) are such additions: optional,
they change no existing field and do not move `protocol`. The transport is
1 with `protocol_min` 1; the pre-0.2.0 pre-releases used transport numbers up
to 11 and are incompatible: versions share no range, so a client treats such
a daemon as an incompatible daemon.

### 19.9 Version handshake

*Status: master (`daemon/version.lua`, `daemon/ensure.lua`), applied by every
workspace command in `daemon` mode. During the transition a version-bypass
run is the in-process path, and a daemon with newer schemas is reported in
one line and not used — the command itself still runs in-process, where the
file-level checks of §2.7 apply. The transport range under "From protocol
11" is step 5g.1 (`version.negotiate`; an editor observes a daemon whose range
overlaps its own); the CLI policy (`ensure.policy`, `describe`) and the
generalised busy rule (`Server:conn_busy`, `status.busy_clients`) are
implemented, step 5g.3; the editor retirement below is implemented, step 5h.5
(`daemon/editor_retire.lua`, `Observer:_weigh_retire`).*

Client and daemon are the same binary, so after a self-update (§16.32) or a pin
change (§16.24) a newer client can meet an older daemon. Both sides send their
protocol version, host version and the working-copy and cache schema versions
in the handshake. A CLI client **matches** a daemon when all of them are equal
(a development build compares its source fingerprint as its version: when it
runs a source tree through the development facility (§16.11), the paths,
sizes and modification times of those sources, so editing a source is a
mismatch; when it runs its embedded code, whose sources cannot change, the
executable itself, identified by its resolved path, size and modification
time, so every spelling of it
(a link, a differently cased name) is the same executable). An editor
client **observing** a daemon ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)) needs less: an equal protocol and schemas
no newer than its own — the daemon's host version may differ (the editor's
code ships with the plugin, the daemon's with the resolved host binary).

On a mismatch, after authenticating:

- **Idle daemon** (no connection other than this one is busy — none owns a
  running task or has a request in flight, "Busy" below) — the client stops
  it (§19.11) and launches its own binary in its place; a connection that
  only observes or subscribes (an editor) never counts as busy.
- **Busy daemon** — the client sends `retire`: the retiring daemon accepts no
  new operations from any client (each is `declined`, and that client runs it
  in-process), finishes the ones already running, and exits once no
  connection is busy; the next command launches the current binary.
  The client runs **this** command as a **version-bypass run**: attached, but
  without the runtime lock (§19.2), holding only its operation locks (§19.3),
  and prints one line:

  ```
  lw: the workspace daemon runs lw v0.1.43 and is busy — running this command without it; it restarts when idle
  ```

A client never stops a busy daemon, and never drives a daemon it does not
match. A daemon whose schemas are newer than the client's is never stopped by
it; the client refuses with the update message of §2.7 "Reading a newer file".

**Transport and policy.** *(Transport: step 5g.1; the CLI policy and the busy rule: step 5g.3; the
editor retirement: step 5h.5.)* The rules above split
into a protocol rule and a client policy:

- **Transport.** Client and daemon agree on a transport version as
  [PROTOCOL.md](../protocol/PROTOCOL.md) §6 specifies; interfaces are chosen per call (PROTOCOL.md §9.4).
- **`lw_version` equality is the CLI's policy** for routed operations — pin
  semantics and behavioural parity, which no interface version expresses. Before
  routing, the CLI compares `describe().binary.lw_version` ([API.md](../protocol/API.md) §3) with its own
  (and the schema versions as above) and applies the idle-restart / busy-retire
  and bypass flow unchanged. The daemon enforces version equality only for
  interfaces flagged `same_build` (§19.20). An editor never requires an equal
  `lw_version` or equal schemas: it needs a transport overlap and, per feature,
  the interface versions it uses ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)).
- **Busy.** A connection counts towards *busy* only while it **owns a running
  task or has a command in flight**. A connection that only subscribes —
  views, task observation, an editor with no operation of its own — never does:
  the observer rule above applied to every connection. A CLI restarting an idle
  daemon is therefore safe for a connected editor, which reconnects,
  re-describes and re-subscribes ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)). The CLI still never stops a busy
  daemon.
- **Editor retirement** (step 5h.5). The editor retires a daemon only when it
  is idle **and** either incompatible with the editor or of another code
  identity than the binary the editor selected ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Retiring an
  incompatible daemon"), and only when that binary is itself compatible.
  The code identity is the host version, or a
  development build's source fingerprint, as above. A daemon computes its
  identity once, at start. The editor takes the identity of the binary it
  would launch from its relay's `welcome.relay` (§19.8); a `welcome`
  without it gives no such identity, and the editor then retires a daemon
  only when it is incompatible. An idle daemon whose identity differs from that binary's is
  retired by the editor too, and the binary is launched in its place. A busy
  one is never retired by the editor: it is observed if compatible and
  checked again when idle. The CLI's busy-retire and bypass are unchanged.
  The once-per-version rule, now keyed by identity, bounds the editor and a
  CLI of another binary restarting each other's daemon. A daemon whose only
  incompatibility is older schemas stays observed while the editor waits for
  it to go idle, and for the whole session when the editor declines to retire
  it.

### 19.10 Launch

*Status: master (`daemon/launch.lua`, `daemon/ensure.lua`,
`daemon/rlog.lua`). In `daemon` mode the workspace commands launch — the
commands that need no workspace (`status`, `health`, `pull`, `worktree`,
`settings`, `help`, `daemon …`) and the recovery commands (`trust`, `nuke`,
`unlock`) never do; the `Runtime` row says the daemon "starts on the next
command". The ensure step of a command waits about a second per step at most
(connect + handshake, `ping`), and for a daemon still starting at most about
a second, once, before running without it. A command the daemon would run (a
routed `lw build`, §19.15) waits up to about 5 seconds instead, for each step
and for the one wait on a starting daemon: under machine load a healthy daemon
can miss the second, and the build would then run in-process exactly when the
daemon helps most. A daemon already classified hung (§19.5: alive, heartbeat
stale) is reported at once either way; the longer bound only applies to a
live-but-slow one. A `lw daemon run` that finds the runtime lock
held exits with status 3, which the launching client reads as "another daemon
won".*

A client that finds no live daemon (no handle, a stale handle, or a lock whose
holder is gone) launches `<own executable> daemon run --root <root>`:

- **Detached**, in a new process group/session, with **no inherited standard
  handles** (on Windows, standard input, output and error are not inherited;
  on POSIX they are `/dev/null`); the daemon writes its own **runtime log**
  inside the workspace, `<root>/.lw/daemon-<S>.log`, capped at a few
  megabytes with one rotated predecessor (`.log.1`). Each line is appended
  with the file opened and closed again, so no process keeps it open, and as
  one atomic append (the system places the write at the end of the file:
  O_APPEND, on Windows append-only access), so lines that a client and the
  daemon it just launched write at the same moment are both kept. A write
  creates `.lw/` only when the workspace root exists, and never creates the
  root: a daemon whose workspace was removed does not bring it back. A file at
  the log's name that is not lw's runtime log is never written, rotated or
  removed (§16.40). `lw daemon status` names the log when it exists. (Earlier versions kept it in the
  per-user state directory; §16.40 removes those files.)
- **Working directory**: the per-user state directory — never the workspace,
  so the daemon never holds the workspace directory open or busy.
- **Environment**: the client's, de-duplicated (on Windows case-insensitively,
  keeping the entry the process itself resolves); when the client uses the
  development facility (§16.11), its opt-in is forwarded so the daemon runs the
  same source.
- **Readiness**: the client waits (about 10 s) for a handle naming a live
  daemon, and watches the child for an **early exit**. A child that exits
  because another daemon holds the runtime lock is not a failure — the client
  connects to that one. Any other early exit, or no handle in time, is a
  **launch failure**: the client runs the command attached (§19.1), printing
  `lw: could not start the workspace daemon (<reason>); running without it`.
  It never retries in a loop.

Concurrent launches resolve on the runtime lock: one daemon wins, the others
exit, all clients connect to the winner.

**Connections.** *(Step 5i: the relay with `--no-launch`, `--skip-instance`
and the gated `--private` is implemented, `daemon/relay.lua`, and so is its
`lw daemon list` / `kill --all --strays` classification (§19.6.1 step 3), and
the idle rule with its background-work cap (§19.11 "Idle exit"), and the
CLI's two-stage Ctrl-C (§19.15 "Task ownership"), and the editor's use of it
([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Through the relay", `daemon/client.lua` `relay`) with the `--retiring`
flag ("A named retiring daemon" below), step 5i PR G1, and the editor's
incompatible-daemon policy over it (`--skip-instance`), PR G2.)* Every client process is a
**connection** to the one shared daemon of its workspace, never a daemon:

- **Connect or start.** Every CLI command that uses the daemon — the
  commands that already do so today, in `runtime-mode daemon` (the ensure
  step and the routed operations above and §19.15); step 5i routes no new
  command, and the `in-process` default does not change — and
  `lw daemon run --root <root> --stdio`, connects to the workspace's daemon
  over its endpoint, or first launches the normal detached daemon above when
  none runs, then connects. `--stdio` then **relays** frames opaquely between
  its standard input/output and that connection (it authenticates on the
  socket like any client, §19.8 "Relay handshake"; it interprets no
  interface, so it never changes for a new one). It replaces the separate
  `lw daemon attach --stdio` bridge planned earlier. Each relay step
  (connect + handshake, the one wait on a starting daemon) is bounded as for
  a routed command (about 5 s). A daemon still starting after that one wait
  ends the relay with status 11 (not responding). Before it connects, the
  relay checks the handle: a `key_id` (§19.6) that is not this lw's, or an
  endpoint that fails the endpoint check (§19.7), ends the relay with status
  12 — nothing is connected to — as a failed `server_proof` does.
- **Lock held by an attached run.** When the runtime lock is held by an
  **attached run** (§19.2: a CLI command running without a daemon), the relay
  neither launches nor fails: it waits — no time bound, for as long as its
  standard input stays open — re-reading the runtime lock about every 2 s,
  until that run ends, and then continues connect-or-start from the start
  (a daemon may have been started meanwhile, or it launches one). The client
  closing standard input (EOF) while it waits ends the relay with status 0.
  No exit status is added for this case.
- **No launch.** `lw daemon run --root <root> --stdio --no-launch` is the
  relay that **never launches** a daemon (the editor's after a drop such as
  `lw daemon stop`, after a relay's status 10 or 11, and while a retiring
  daemon is still busy, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Through the relay"). It reads the client's `hello` first as any relay
  (§19.8 "Relay handshake", status 15), then waits inside lw for a live
  daemon of its root: it re-reads the runtime lock and the handle about every
  2 s (the cadence at which the editor watched the handle before), and
  connects as soon as one is live, with the same discovery, handshake and
  checks as connect-or-start — the handle's `key_id`, the endpoint check
  and `server_proof` (status 12), another host (13), not responding (11). Once connected it
  relays exactly as above. A daemon still starting (lock held, handle not yet
  published) is waited on, as is a retiring one: on a `welcome` that says
  `retiring` the relay closes that connection, forwards nothing, and keeps
  waiting — no `RELAY_RETIRE_WAIT` bound, and no successor launched. When the
  retiring daemon it saw has released the runtime lock and no other daemon is
  live, it exits with status 16 (so the editor launches the successor itself,
  [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Retiring"); a successor another client started first is connected
  to instead. The wait has no time limit: it lasts while standard input stays
  open, and when the client closes standard input (EOF) during the wait the
  relay exits 0, having launched nothing. Statuses 10 and 14 are never a
  `--no-launch` relay's. `--no-launch` without `--stdio`, or with
  `--private`, is usage (status 2).
- **Skip an instance.** `--no-launch --skip-instance <pid>:<start_time>`
  (the editor's after it found that daemon incompatible, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Through the
  relay") names one daemon instance by process id and process start time
  (§19.5; the handle's `pid` and `start_time`, as `welcome.daemon` reports
  them, §19.8 "Relay handshake"). The relay treats that daemon as not
  present: it never connects or relays to it, and while it holds the
  runtime lock (or its handle is the live one) the relay keeps waiting as a
  `--no-launch` relay waits on a starting daemon — no bound, nothing
  launched, status 0 on EOF. Once the lock is released, or held by a
  different instance, the relay proceeds as a plain `--no-launch` relay: it
  connects to a live daemon of another instance when one appears (a
  `retiring` one is waited on as above). It never exits 16 for the skipped
  daemon — 16 is only for a retiring daemon it connected to — so a skipped
  daemon that exits with none other live leaves the relay waiting, as after
  a stop. `--skip-instance` names at most one instance; it is usage (status
  2) without `--no-launch` (an ordinary relay could neither use the skipped
  daemon nor launch while it holds the lock, so it would only wait, which is
  what `--no-launch` is), or when its value is not `<pid>:<start_time>`.
- **A named retiring daemon.** *(Step 5i PR G1.)*
  `--no-launch --retiring <pid>:<start_time>` (the editor's after a relay
  exited 14, with the instance that relay's `retiring` line named, "Relay
  exit status" below and [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Through the relay") names one daemon
  instance (as for `--skip-instance`) that the relay treats as a retiring
  daemon it already saw, as if it had connected to it and got a `welcome`
  that says `retiring`. It closes a race a plain `--no-launch` relay leaves open: a
  retiring daemon that exits after the status-14 relay gave up but before
  this relay first looks is never seen retiring, so a plain `--no-launch`
  relay would wait on as after a stop and never exit 16. With `--retiring`,
  while that instance holds the runtime lock (or its handle is the live
  one) the relay waits on it as on a retiring daemon ("No launch" above: no
  bound, nothing launched); once that instance no longer holds the lock —
  including when it is already gone at the relay's first check — and no
  other daemon is live, the relay exits 16. Otherwise it is a plain
  `--no-launch` relay: a live daemon of another instance is connected to (a
  `retiring` one is waited on as above), status 0 on EOF. `--retiring`
  names at most one instance; it is usage (status 2) without `--no-launch`,
  or when its value is not `<pid>:<start_time>`. The editor never passes it
  together with `--skip-instance`; whether that combination is usage is not
  specified.
- **Relay buffering.** The relay bounds what it buffers in each direction:
  while the queue of frames waiting to be written to one side holds more
  than `RELAY_HIGH_WATER` (4 MiB) it stops reading the other side, and
  resumes once that queue has drained below half of it. A client that stops
  reading therefore stops the relay reading the daemon, so the daemon's
  owner flow control (§19.15 "Task stream") still reaches the running step
  through the relay, and the relay's memory stays bounded. Before the
  daemon's `welcome` the relay keeps what the client pipelines after its
  `hello` (forwarded after `welcome`); more than `RELAY_HIGH_WATER` of it is
  a protocol violation that ends the relay with status 15 — the relay never
  stops reading a client it has not yet relayed for, so it always sees that
  client's EOF.
- **Closing a connection** — killing the `--stdio` process, closing its
  standard input, a CLI command ending or interrupted — closes only that
  connection: the tasks it owns are cancelled (§19.15 "Task ownership"), the
  daemon keeps running under §19.11.
- **Only the daemon owns the workspace runtime**: the runtime lock, the handle,
  the endpoint and the identity are the daemon's. A relay takes no lock,
  writes no handle and registers nothing; `lw daemon list` and
  `kill --all --strays` show it as a connection of its daemon (§19.6.1).
- **Tests.** The conformance runner (§19.20) needs a fresh, isolated daemon
  per case. It gets one through the hidden `--private` flag of
  `lw daemon run --stdio`, which keeps today's attached standard-I/O runtime
  (§19.8: the private pipe, no challenge) for tests only. `--private` is
  refused (status 2, `lw: --private is for tests only`) unless the
  environment variable `LOOMWORKS_TEST_PRIVATE_STDIO` is `1`; it is not in
  `--help` and not in completion. Nothing else reaches the private no-auth
  path: without the flag and the variable, `--stdio` is always the relay.
  A per-case temporary workspace root remains the alternative when a case
  needs the shared-daemon path itself. `--no-launch` is tested on such a
  root: with no daemon it waits and launches nothing (no runtime lock, no
  handle appears); once a daemon is started for the root it connects and
  relays (`welcome` with `via`); closing its standard input while it waits
  ends it with status 0; a retiring daemon is waited on, never relaunched
  over, and its exit with no other daemon live ends the relay with status 16.
  `--skip-instance` is tested on the same root: with the named daemon live
  the relay never connects to it (the daemon sees no connection) and keeps
  waiting; after that daemon stops it stays waiting (no status 16) and
  connects to the next daemon started for the root; a value naming another
  instance (different start time) does not skip the live one; without
  `--no-launch`, or with a malformed value, it is status 2. `--retiring`
  is tested likewise: naming an instance already gone,
  with no other daemon live, it exits 16 at once; naming a live retiring
  daemon it waits, launches nothing, and exits 16 once that daemon has
  released the lock; with another daemon live it connects to that one;
  without `--no-launch`, or with a malformed value, it is status 2. The
  status-14 line is tested with a retiring daemon kept
  busy past `RELAY_RETIRE_WAIT` (the bound shortened for the test): the
  relay exits 14, its standard output is empty, and its standard error is
  its `lw: ...` line followed by exactly `retiring <pid>:<start_time>`
  naming that daemon's handle `pid` and `start_time`; a `--no-launch
  --retiring` relay given that value exits 16 once the daemon has released
  the lock.
- **Compatibility.** A repository pinned to a release from 0.1.43-beta.15 up
  to the one before the release that ships this step still gets that
  release's attached `--stdio` (it works, but is not shared with the CLI; its
  `welcome` has no `via`, §19.8 "Relay handshake", so the editor never sends
  `retire` over it); a pin older than 0.1.43-beta.15 is already refused for
  the daemon commands (§16.23 "A pin older than the command",
  `pin.REDIRECT_SINCE`).

**Relay exit status.** *(Step 5i, `daemon/relay.lua`.)* A relay that fails before
forwarding `welcome` writes nothing to standard output, one `lw: ...` line to
standard error (on status 14 followed by the retiring-instance line below),
and exits with:

| Status | Meaning |
|--|--|
| 0 | the client closed standard input (with `--no-launch`, also while waiting, having launched nothing; for any relay, also while waiting on an attached run's runtime lock), or the daemon closed the connection after `welcome` |
| 1 | standard input or output is unusable, or an internal error |
| 2 | usage: no `--root`, `--private` without `LOOMWORKS_TEST_PRIVATE_STDIO=1` or without `--stdio`, or `--no-launch` without `--stdio` or with `--private`, or `--skip-instance` without `--no-launch` or not `<pid>:<start_time>`, or `--retiring` without `--no-launch` or not `<pid>:<start_time>` |
| 10 | could not start the workspace daemon (launch failure above; never with `--no-launch`) |
| 11 | the daemon is not responding (hung, §19.5; connect/handshake past its bound; or still starting — lock held, handle not published — after the relay's one bounded wait; never with `--no-launch`, which keeps waiting on a starting daemon) |
| 12 | the handle names another loomworks data dir's key (`key_id`, §19.6), its endpoint failed the endpoint check (§19.7), or the endpoint did not prove this lw's key (another loomworks data dir, or not a loomworks daemon) — only the relay's own `hello` (versions and its nonce, no secret) was sent; nothing from the client is forwarded |
| 13 | the workspace daemon runs on another host |
| 14 | a retiring daemon still held the runtime lock after `RELAY_RETIRE_WAIT` (never with `--no-launch`, which keeps waiting); standard error also names that daemon (`retiring <pid>:<start_time>`, below) |
| 15 | the client sent no valid `hello` first (another frame, or a `hello` whose forwarded fields are not of their types or that does not fit the 64 KiB pre-authentication frame cap re-encoded), or none within about 5 s; or it sent more than `RELAY_HIGH_WATER` after `hello` before `welcome` ("Relay buffering") |
| 16 | `--no-launch` only: the retiring daemon it waited on (one it connected to, or the one `--retiring` names, also when already gone at its first check) released the runtime lock and no other daemon is live — the caller decides whether to launch (never for a `--skip-instance` daemon) |

**Retiring-instance line.** *(Step 5i PR G1.)* A relay that exits
14 writes, after its `lw: ...` line, exactly one more standard-error line,
the last it writes: `retiring <pid>:<start_time>` — the literal word
`retiring`, one space, then the retiring daemon's instance in the form
`--retiring` and `--skip-instance` take (§19.10 "A named retiring daemon"):
exactly its instance id (§19.5) — the handle's `pid` in decimal, a colon,
and its `start_time` verbatim (an opaque string that may itself contain
colons, e.g. `win:<creation time>`), as in `retiring 1234:win:5678` — with
no other characters, ending in the platform's newline. It names the daemon whose
runtime lock the relay waited on. A relay that does not know both values
(a handle without `start_time`) writes no such line. No other status writes
it, and nothing else on a relay's standard error starts with `retiring `.
The editor passes the value to `--retiring` ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Through the relay").

Status 3 ("another daemon won", above) is never a relay's: a relay that
loses a launch race connects to the winner. A status 3 from `daemon run
--stdio` therefore comes only from an older pin's attached runtime ("Compatibility"
above), whose runtime lock was held. The editor maps each status, and an
older pin's, to its Runtime-line note and follow-up ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Through the
relay"); a status is only meaningful when the relay exits before forwarding
`welcome`.

### 19.11 Lifetime

*Status: master (`daemon/server.lua`, `daemon/command.lua`). A `lw` command
connects for a moment (handshake, `ping`) and leaves; the keepalive rule
applies to every authenticated connection, except one that owns a running
operation (§19.15). A running build makes the daemon busy (handle `busy`); a
`retire`d daemon exits when no connection is busy (§19.9 "Busy",
`Server:_retire_idle`, step 5g.3).*

- **Attached clients keep it alive.** A connection counts while authenticated
  and open. The editor sends a keepalive `ping` (about every 30 s); a
  connection silent for three intervals is dropped as half-open.
- **Observers and retirement.** A `retire`d daemon broadcasts `retiring` to
  every connected observer ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)), and `welcome` carries `retiring` for one
  that connects later; an observer then disconnects and does not reconnect to
  that daemon. A retiring daemon exits once **no connection is busy** — none
  owns a running task or has a request in flight (§19.9 "Busy"); a connection
  that only observes or subscribes, or an idle client still connected, never
  holds it off. (Every connection still counts for the idle timeout and in
  `clients`.) A request left in flight for a long time (10 minutes) is noted
  once in the runtime log, never cleared: it keeps its connection busy.
  `status` reports `observers`, the number of observer connections, and
  `tasks`: one `{ task_id, name, kind, profile, units, origin, started_at,
  percent? }` per running task — its `start` meta (§19.15), the wall-clock
  time it started, and its last progress percent, absent before the first
  tick. An addition to the frozen `status` shape (§19.8): a daemon of an
  older protocol omits it.
- **Idle exit.** Idle — **no connections and no background work** — for the
  idle timeout (setting `daemon-idle-timeout`; default the idle grace
  `IDLE_GRACE_SECONDS`, 45 seconds, from step 5r — 1 hour before it, see
  "Warm restarts" below), the daemon exits. The idle clock starts when the last connection closes or the last
  background work ends, whichever is later; the handle's `idle_since` is
  absent while background work runs. *(Step 5i, `Server:lifetime`.)*
  **Background work** is work the daemon owns with no connection as
  owner — tool detection, scans, the `compile_commands.json` refresh,
  housekeeping; today the loaded model's tool detection (a `snapshot` or
  `query` load does not wait for it) and a run still settling after its
  owner left or its task ended (a cancellation, a reset's deletion).
- **Background work cap.** Background work has a maximum duration,
  `BACKGROUND_MAX_DURATION` (10 minutes), after which it is stopped (and,
  from step 5r, its interrupted part is not written — "Warm restarts"
  below). The clock counts only
  while the work is ownerless and no connection is open: it starts when the
  last connection closes or the work starts, whichever is later, and a
  connection opening resets it. Past the cap:
  - **Tool detection** cannot be cancelled (it has no handle): it is
    abandoned — with no run active, the daemon unloads the model, so the
    late result is dropped (a torn-down model never applies it, so no
    workspace file records it); the probe subprocesses run to completion on
    their own. The CLI's machine-level tool cache (`tools.json`, §16), which
    a detection fills when it completes, may still record that late result once it
    completes — it is a complete detection, not an interrupted part. The
    next request loads the model afresh.
  - While a request is being processed (a model segment is running, e.g.
    waiting for the model to load for a client that has since gone), the
    cap does not act; it acts on the first lifetime check after the
    segment ends.
  - **A run** still settling — a cancellation killing its step, or a
    reset's deletion — is stopped as on any stop: the daemon stops (it has
    no connection), through the same path as every exit (§19.15) — a
    deletion stops between entries and its cache entries stay `unknown`
    (an entry is reset only after its tree was removed), the run's locks
    are released, the task ends. Background work that can be neither
    abandoned nor stopped otherwise stops the daemon the same way.

  *(Step 5i, `Server:lifetime`, `Service:abandon_background`,
  `Service:in_segment`.)* The
  daemon's lifetime never depends on any client's lifetime: a client keeps
  it alive only through an open connection.
- *(Step 5r: idle grace B, tool cache C, idle deadline D.)* **Warm restarts.** A script running several `lw`
  commands in a row pays one cold start, and a restarted daemon reuses what
  an earlier one already worked out:
  - **Idle grace.** The default of the idle timeout above is the named
    constant `IDLE_GRACE_SECONDS` = **45 seconds**, defined once (the
    runtime's settings code; every other default refers to it). It replaces
    the former 1-hour default; it is not an extra phase before or after the
    idle timeout. The `daemon-idle-timeout` setting still overrides it
    (e.g. `1h`); an invalid value falls back to the grace. An attached
    editor is unaffected: its connection and keepalive keep the daemon
    alive, so only the gap after the last client goes away shrinks.
  - **Idle deadline** *(part D)*. The `status` reply carries
    `idle_timeout`, the idle timeout in effect in seconds, and — when
    nothing but the asking connection keeps the daemon up (no other client,
    no run, no background work) — `idle_deadline`, the wall-clock time
    (epoch seconds) at which the daemon exits if the asker closes now and
    no client connects: the asker is a connection, so its close restarts
    the idle clock, and the deadline is that close plus the timeout. Both
    are additions to the frozen `status` shape (§19.8): a daemon of an older
    protocol omits them, and a client ignores fields it does not know.
    `lw daemon status` shows them on an `idle` line —
    `timeout 45s, exits at 14:03:12 (in 45s) unless a client connects`, or
    `timeout 45s, idle timer not running (<n> other clients | an operation
    is running | background work)` — and no line for a daemon that does not
    report `idle_timeout`.
  - **Persisted background results.** In step 5r the only background result
    is **tool detection**; scans, the `compile_commands.json` refresh and
    housekeeping are not daemon background work yet, and each defines its
    own unit and fingerprint when it becomes one. Tool detection is persisted
    in the machine-level tool cache `tools.json` (§16.43) — never in
    `.lw/cache.json`, which keeps no tool results and whose entries are
    the source of build directories for deletion. The unit is the **module
    type**: each type's result is written with a timestamp and the
    fingerprint of its inputs (§16.43: the `lw` identity including its
    `lw_version`, the normalized search path, `PATHEXT`, the platform, the
    module id and module interface version, and the modification time of
    each search-path directory), so a retired daemon's results are never
    reused by a daemon of another version.
  - **Written per type, atomically, on completion.** A module type's result
    is written as soon as its detection finishes, to a uniquely named
    temporary file renamed over `tools.json` (§16.43). An **interrupted
    part** is a module type whose detection had not finished when the work
    ended — the daemon stopped (`lw daemon stop`, a retirement, the root
    removed, the lock lost) or the work was abandoned at the maximum
    duration above — and it is not written; types that finished before stay
    written. (Idle exit never interrupts background work: the daemon is not
    idle while background work runs.) A type that finishes after its work
    was abandoned is a complete result and may still be written, as above.
  - **Reuse on start.** On the next load the daemon reuses each module
    type's cached result whose fingerprint matches the current inputs and
    detects only the other types; a load whose types all match runs no
    detection, so no background work follows it. There is no time-to-live: a
    fingerprint mismatch reruns only that type, and `lw tools` rescans every
    type (§16.43).
  - **Limits.** Several writers (daemons of other workspaces, in-process
    `lw` commands) share `tools.json`; two that write at the same time can
    lose one of the updates, which costs only a later re-detection of that
    type. On Windows a rename blocked by another process (a reader, an
    antivirus scan) loses only that cache write. Neither ever leaves a torn
    `tools.json`.
- **Root removed.** On each heartbeat the daemon checks its workspace root; if
  it is gone, it cancels running tasks and exits.
- **Lost lock** — §19.2.
- **Exit** of any kind cancels running tasks (their clients see the
  cancellation of §19.15), releases operation locks and the runtime lock,
  removes the handle and (POSIX) the socket, and ends the process — no timer or
  handle may keep it alive.

**Commands.** `lw daemon status` reads the handle and lock and, for a live
same-host daemon, asks it for `status` (clients, running operations, versions,
from step 5r the idle timeout and deadline — "Warm restarts");
it never launches. `lw daemon stop` sends `stop` (the daemon exits as above)
and waits (about 10 s) for the runtime lock to be released; it never kills
(a daemon of an earlier lw holding the legacy lock is the exception,
§19.6 "Legacy files") —
a daemon that does not stop in time is reported as not responding, with
`lw daemon stop --force` as the remedy. A daemon still starting (it holds the
runtime lock, its handle is not published yet) is first given the same
window to publish its handle — a slow start on a loaded machine is not "not
responding". A daemon whose handle's `key_id` (§19.6) is not this lw's is
not asked: `lw daemon stop` says it belongs to another loomworks data dir
(different key) and exits 1 without connecting; one that does not prove this
lw's key in the handshake is reported the same way (it belongs to another data
dir or is not a loomworks daemon), and nothing more is sent to it. `lw daemon
stop --force` and
`lw daemon kill` are the forced recovery of §19.5. Stopping when no daemon runs
succeeds with nothing to do. A daemon on another host is never stopped or
killed from here (the command names the host); a stale one is reclaimed per
§19.5. `lw daemon restart` is stop then launch (`--force` applies to the
stop). None of these require the
workspace to load. `lw daemon list` and `lw daemon stop --all` /
`kill --all` act on every daemon of this user on this host (§19.6.1).

### 19.12 Wire identity and change broadcasts

*Status: master for the coarse change signal, `Workspace/1.changed`
(`daemon/server.lua` `model_changed`, sent after each committed write of a
state file by the daemon — the working copy or the cache,
`Workspace:_record_written`), and for the opaque-id registry and the
current-key → id index (`daemon/snapshot.lua` `registry`, `index`; carried in
a snapshot, §19.13); the id-keyed signals and the re-pull protocol #88.*

The daemon keeps a session-local **opaque-id registry** keyed by object
identity, which provides the ids of [PROTOCOL.md](../protocol/PROTOCOL.md) §12.1: an id survives renames (it
follows the object, not its key), refreshes (the deserializer reuses a
matching object) and an environment reload (§19.15: the reloaded entity
takes over the id of the one it replaces), and is discarded on restart (a new session generation).
Snapshots carry
a current-key → id index from which a client builds its id↔key map, a
transport-layer router that domain logic never consults. *(Step 5g.2 part B
changed the index's ids from integers to these strings, which they share
with the interfaces' ids.)*

Every model change advances a per-workspace revision and sends the
`changed` signal of `loomworks.Workspace/1`, stamped with that revision, to
its subscribers. A client re-pulls the affected scope snapshot (coarse
invalidation); a broadcast at or below its seq is ignored, a newer one
arriving mid-refresh schedules exactly one more re-pull, and a new session
generation forces a full re-hydrate. Per-object deltas are a future
optimization.

**Ids on the interfaces.** *(Step 5g.2: the `changed` signal (part A) and
references in requests (part B: the operations' interfaces and
`Profiles/1.compiler_cache`; ids are opaque strings carrying the session
generation) are implemented; records
of further interfaces land with the steps that land them, §19.19.)* Ids are
the only entity handles on the wire; the ids of this registry are those of
the interface records and references ([API.md](../protocol/API.md) §1). A model change is the
`changed { revision, scopes? }` signal of
`loomworks.Workspace/1` ([API.md](../protocol/API.md) §6), delivered to its subscribers under the
generation rule above. An interface signal's `seq` is counted as [PROTOCOL.md](../protocol/PROTOCOL.md) §12.3
specifies (per object and connection, gapless).

### 19.13 Snapshot and projection

*Status: master for the snapshot (`lw.internal.Snapshot/1.get`), the
projection builder and the `welcome` header (`daemon/snapshot.lua`,
`daemon/service.lua` `_snapshot_answer`, `daemon/core_interfaces.lua`, `workspace.assemble_snapshot`); the
read-only CLI commands read a projection in `daemon` mode (`cli.lua`
`read_workspace`, §19.1). Re-pulls on `Workspace/1.changed` and the
view-scoped model future.*

The daemon is model-authoritative; a client keeps a **projection** for
rendering and integration. The client builds it with the **same deserializer**
the on-disk loader uses, fed by the wire instead of the disk: the daemon sends
the three file-shaped tables (published baseline, working copy, cache) plus
the resolved toolchain detection. Serializing the daemon's model and the
client's projection yields identical bytes (§19.17).

Consumers pick one of three strategies: an **always-warm header** (active
profile, workspace name, error state — carried in `welcome` and kept fresh by
broadcasts, so a status-line redraw never queries); a **view-scoped model**
(the status page hydrates a scope snapshot on open, follows broadcasts, drops
it on close); and **transient queries** (pickers and commands query, act,
discard).

**`snapshot` request.** `snapshot { scope, env }`: `scope` is `all` (the
default), `config`, `user` or `cache`; `env` is the requesting client's
environment, as for a routed operation (§19.15). A loaded model is served as
it is, whatever the requester's environment: a snapshot never reloads it,
runs no file check and waits for no tool detection. With no model loaded the
daemon loads it in the requester's environment, without waiting for tool
detection (it goes on in the background). The reply is `ok` with
`outcome = "ok"` and:

- `config` (scope `config`): the published baseline as the daemon loaded it
  from `loomworks.json` (parsed, program-bearing fields stripped, §17.6);
- `user` (scope `user`): the working copy as the model serializes it for
  `.lw/user.json`, with its schema `_meta`;
- `cache` (scope `cache`): the cache as the model serializes it for
  `.lw/cache.json`, with its schema `_meta`;
- always: `tools` (the toolchain detection the model holds, as tool rows:
  module type → list of `{ key, label, tool_data }`, `key` absent for a
  module whose single toolchain has none; the same shape as the `tools`
  query, §19.14), `shared_ignored` (the stripped program-bearing fields,
  §17.6), `index` (the semantic-key → id index of §19.12: `projects`
  project key → id, `config_sets` name → id, `profiles` profile key → id,
  and `config_units` a list of `{ project, configuration, id }` by project
  and configuration key; an unchanged model keeps its ids across
  snapshots), `seq` and `session_generation`.

A scope the request does not name is absent. A workspace the daemon cannot
load is answered `outcome = "refused"` (`message`), and a request it does not
carry (stopping, malformed, another environment while a build runs)
`outcome = "declined"` (`reason`), as for a routed operation. A snapshot takes
no lock, starts no task and writes nothing to a loaded model; the load it
triggers when none is loaded is the ordinary workspace load (it may complete
a commit journal, §19.4). A client builds its projection
from a snapshot of scope `all` through the deserializer of the on-disk load,
fed these tables instead of the files' bytes (their signatures are not
re-verified: the wire is authenticated). A projection is read-only: it never
saves the working copy or the cache, and it watches no files.

**Header.** `welcome.header` and `Workspace/1.header` — the session fields
and the model's `state` — are [API.md](../protocol/API.md) §2. Sending `welcome` never loads the
workspace; an editor's connection starts a load right after it ("Loaded on
attach" below).

**Loaded on attach.** When an editor connects (`role = "observer"`), the
daemon, after its `welcome`, starts loading the workspace unless it is loaded
or a load is under way — as a `snapshot` loads it, in the daemon's own
environment and without waiting for tool detection — so an editor-only
session does not stay `unloaded`. A connection without that role (the CLI)
never starts a load, and `LspConfig/1.get` still never loads. Because this
load uses the daemon's own environment, a later operation from a client whose
environment differs reloads the workspace first (§19.15).

**As interfaces.** *(`lw.internal.Snapshot/1` and
`loomworks.Workspace/1.header`: implemented, step 5g.2 part A
(`daemon/core_interfaces.lua`); the CLI's read commands call
`Snapshot/1.get` since part B (`daemon/calls.lua`); the
editor views steps 5j–5n, §19.19: `view.Header/1` and `view.ProjectsIndex/1`
specified ("Views" below, step 5j part 0) and served (part B), the editor's use done, part C.)* The `snapshot` request becomes `lw.internal.Snapshot/1.get { scope }`
([API.md](../protocol/API.md) §16), flagged `same_build`: the CLI's read commands and the parity tests
use it, the editor never does. The
always-warm header is the `loomworks.view.Header/1` interface (and
`loomworks.Workspace/1.header`); `welcome.header` stays as it is, frozen.
View-scoped models are `loomworks.view.*` interfaces, one per view, each
returning its full state on subscribe (`initial`, [API.md](../protocol/API.md) §14) and following with
`update` signals, so a reconnect re-hydrates with no further protocol; the
editor's projection of file-shaped tables is replaced by these views as the
steps land.

**Views.** *(Step 5j: specified, part 0; the daemon side implemented, part B
(`daemon/views.lua` mounted on `/views`, the builder `view_state.lua`); the
editor side implemented, part C (the view store `views.lua`, the observer's
`/views` subscriptions, lualine and the status page header on the store,
`lw.buf_project`).)* Two views back the editor's always-warm surfaces, the
statusline (spec/ui.md §3) and the buffer → project lookup:
`loomworks.view.Header/1` and `loomworks.view.ProjectsIndex/1`, specified with
the rules every view follows in [API.md](../protocol/API.md) §14. What only the daemon knows — the
header's `pid`, `lw_version` and `session_generation`, and every opaque id
— the daemon's views carry as their schemas require ([PROTOCOL.md](../protocol/PROTOCOL.md)
§12.1); the in-process builder leaves it out ("Two sources, one shape" below).
`view.Header/1`'s `version` is the daemon's in the daemon's view and the
editor's in one built in-process (also `daemon` mode's `unloaded` header
before the daemon's arrives); the status page's header shows it (spec/ui.md
§1). For its `trust`, the status page offers review & trust and discarding
the working copy (`user`) or resetting the build cache (`cache`). Its
`active_profile_id` is what the editor puts in an `{ id }` reference once
commands move to interfaces (step 5o), as `config_set_id`. A ProjectsIndex
record's `active.state` includes a task another client runs in the daemon
([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Running state"); the statusline icon is computed from these states.

The buffer → project lookup (`lw.buf_project`, "Two sources, one shape")
is the record whose `abs_path` is the longest prefix of the buffer's path
**on a separator boundary**: a record matches when the buffer's path equals
its `abs_path` or starts with its `abs_path` followed by `/`, so a project
at `/a/foo` does not match a buffer in `/a/foobar`. Both paths are compared
in their normalized form (§2.3: `/`-separated, and lowercased on Windows).
A buffer's record is chosen first by physical path (links, junctions and
Windows 8.3 short names resolved): of the records whose physical path
contains the buffer's physical path, separator-bounded, the one with the
longest physical path wins; only when there is none, of the records whose
normalized `abs_path` contains the buffer's normalized path,
separator-bounded, the one with the longest normalized `abs_path` wins.
This deliberately fixes today's `project_for_buf`, whose bare prefix test
lets `/a/foo` claim a buffer in `/a/foobar`.

**The tests view.** *(Step 5m, done: part 0 the spec; A the host-neutral
builder, in-process only; B1 the daemon side; C1 the editor's read path.)*
`loomworks.view.Tests/1` ([API.md](../protocol/API.md) §14.3), on `/views` like the two above, backs
the test explorer, its gutter signs and inline marks ([`LOOMTEST.md`](https://github.com/samienne/loomworks.nvim/blob/master/LOOMTEST.md)). Its
`stale` also counts the CLI's builds; discovery needs the client's
environment ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Tests"); the `message` of a unit is the in-process
explorer's. In-process (A) a node's `id` is a local key with the same scope.
Last results live in the daemon's memory: they survive the editor's
reconnects, not a daemon restart (persisting them is later, §19.19 5m part
D).

**The workspace view.** *(Step 5n, done: part 0 the spec; A the host-neutral
builder, in-process only; B1 the daemon side; C1 the editor's read path.)*
`loomworks.view.Workspace/1` ([API.md](../protocol/API.md) §14.4), on `/views`
like the views above, backs the status page's body: Diagnostics,
Suggestions, Profiles, Orphaned Build Dirs, Configuration Sets, Projects
and SDKs (spec/ui.md §1.1). The header, LSP, Debug Adapters and Tasks
sections keep their own sources. In `daemon` mode the editor renders these
sections only from the view; while the view is not offered, each section is
one line in the warning highlight, `unavailable — <why>`, as the Debug
Adapters section's is. In `daemon` mode the status page takes whether the
workspace is loaded from `view.Header/1`'s `state`, so an unloaded
workspace's `published = false` never shows the "loomworks.json not on
disk" banner. Its ids are the daemon's alone ("Two sources, one
shape"). The rows carry what step 5o's command methods take as `{ id }`
references. The view lists every field the status page reads for these
sections; it carries no build progress: a profile's or unit's percent,
elapsed time and progress messages come from `Tasks/1`
([API.md](../protocol/API.md) §7, §14.4 "Progress is not in the view"),
which the status page overlays on the view's rows as it shows remote and
editor-owned tasks ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Tasks in the task runner", "Running state",
"UI"). The outcome of a profile's last finished operation is state, not
progress: the view carries it as the profile's `last_result`. A unit's
state change or a `last_result` change sends the view's `update`; a build's
progress never does.

**Freshness of views.** *(Step 5n part B1.)* The daemon checks for file changes (its file tracker's sync, as at the start of
a state-changing request) before it computes a view: at each point where
`header_check` runs, and for a view's `get`. A change another process made
to `loomworks.json`, `user.json` or the cache — an in-process editor write
before step 5o — is applied to the model then, so it shows in the views on
the next check, not only after the next state-changing request. The check
never loads a workspace and never runs a tool detection: a change to
`loomworks.json` (which can need a tool detection) or one that needs a
reload, and the files changed with it, are not applied at a view check;
they wait for the next state-changing request's sync.
The daemon watches `loomworks.json` and `.lw/user.json`. Another process's change is applied when it is seen, as a check would apply it, with no request needed. It is applied after the current model segment, if one runs. A change that needs a load or a tool detection waits as above.
The editor in `daemon`
mode writes only through command methods (step 5o, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Model writes"),
whose `update`s precede their replies.

A file that cannot be parsed (not JSON, or a working copy whose signature envelope cannot be read) never unloads or replaces the model. The last good model stays, a load warning names the file (`source = "load"`, severity `warn`, "Load warnings" below), and the next change retries. A well-formed working copy that fails its signature is still the refusal of §17.4.

A file that is missing while its staged copy exists (`<file>.tmp`, or a transaction's `<file>.txn-<id>`, §19.4) is a save in progress: the target is briefly absent between its two renames. It is checked again shortly; while the staged copy remains, the model is kept. A missing file with no staged copy is missing, as a deleted file is.

**Load warnings.** *(Step 6b-α.)* What a workspace load reports
besides the structural diagnostics — a declared project directory not
found, an entry skipped, every warning or error the load raises — is kept as
**persistent workspace diagnostics** of the loaded model, with `source =
"load"` and severity `warn` or `error`, until the next load replaces them (a re-assembly after an edit to `loomworks.json` or `user.json` is a load).
They are in `view.Workspace/1`'s `diagnostics` (the status page's
Diagnostics section) and count toward `view.Header/1`'s `diagnostics`
level ([API.md](../protocol/API.md) §14.1, §14.4); the editor shows them
there and holds no load of its own to notify them from. Every CLI request
that uses the loaded workspace — the one that loaded it and each later one on
a warm daemon — carries them in its reply's `notes` with their roles (§19.15
"Roles and verbose"), once each, so each CLI command prints them as an
in-process run, which loads the workspace each time, does. An editor's later
requests do not carry them: the editor shows them in the views. A load raises them only through
the host's notification seam (core's `_deps.notify`), never through
`vim.notify` directly, so both hosts color them by role (§16.7
*Highlighting*). A load note that a structural diagnostic of the loaded model already shows (a stale mapping, a configuration a module reported an error for) is listed once in the views, as that diagnostic; CLI replies still carry it as a note.

**Two sources, one shape.** The editor renders each view from one table of
the view's shape: the daemon's (`initial`, then `update`, `get` after a gap)
while it holds a subscription to the view, otherwise one it builds from its
in-process model with the same builder the daemon uses. The shape is shared,
except for what only the daemon knows: the daemon's view carries it as the
schemas require ([PROTOCOL.md](../protocol/PROTOCOL.md) §12.1), and a view
built in-process, outside that contract, leaves it out: the
header's `pid`, `lw_version` and `session_generation`, and every opaque id
(`active_profile_id`, `config_set_id`, a project record's `id` and
`active.unit_id`, the tests view's `profile_id` and unit `id`; its node ids
are local keys in-process; the workspace view's row `id`s). A view the daemon does not offer (or offers only at another
version) is built in-process too, with the one Runtime-line note of [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)
"Interface client". In `daemon`
mode a view is **never** built from the editor's own model: while the
workspace is unloaded — the daemon reports it `unloaded`, the connection is
lost ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Unloaded on disconnect") or not yet made — the header shows
`unloaded` and the ProjectsIndex is empty, so `lw.buf_project` maps no
buffer until the daemon reports `loaded`, and the tests view has no units
([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Tests"); a view the daemon does not offer
is shown unavailable with that note, not built in-process. In `in-process`
mode views are built in-process as above (removed with the in-process
editor, §19.19 6b-β). The plugin keeps `lw.project_for_buf(bufnr)` (it returns
the `loomworks.Project` in `in-process` mode and, from step 6b-α, the
buffer's ProjectsIndex record in `daemon` mode, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Public API"; from step 5l it is public API only and the LSP layer
no longer uses it, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "LSP configuration")
and adds `lw.buf_project(bufnr)`, returning the buffer's ProjectsIndex record
by the separator-bounded longest-prefix rule above (or `nil` when no record
matches) — from step 5l also the LSP layer's buffer → project rule, in both
modes; `lw.buf_status(bufnr)` keeps its return shape and reads the two
views, plus its `lsp` field ([loomworks.nvim `spec/plugin.md` §9.8](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#9-lsp-integration)), which the editor adds from its own LSP
layer in every mode (`lw.lsp_buf_state`).

### 19.14 Commands

*Status: master for the host-probing queries `tools` and `profile_cache`
(`daemon/snapshot.lua` `QUERIES`, served as `Toolchains/1.list` and
`Profiles/1.compiler_cache`); `lw health` still probes in-process. Commands
are interface methods ("As interfaces" below, step 5o).*

A mutation is a **command** the daemon applies to its model with the
operation's locks (§19.3) and persists. Commands are FIFO-serialized: a
command's `changed` signal precedes any later command's and precedes its own
reply. Wire references are resolved to domain objects once, at the
serialization boundary, and the objects are passed down; domain logic stays
reference-based and never turns an object back into a key to find it again.

Read-only queries run on the client's projection, except queries that probe
the host (health, tools, sdk detect, profile query), which are interface
methods run in the calling client's environment (the call's `env`, a model
segment, §19.15). The daemon's query registry holds `tools` and
`profile_cache`, served as `Toolchains/1.list` and
`Profiles/1.compiler_cache`, whose semantics are [API.md](../protocol/API.md) §11.

**As interfaces.** *(The query registry: implemented, step 5g.2 part B
(`Toolchains/1.list`, `Profiles/1.compiler_cache`; the CLI calls them);
command methods: step 5o, §19.19 — `Workspace/1`
(part B1), `Profiles/1` and `ConfigSets/1` (part B2), `Projects/1` (part B3),
`Sdks/1` and `Toolchains/1.rescan` (part B4) implemented, the others planned.)* Commands are the
**mutating methods** of the model interfaces (`loomworks.Workspace/1`,
`Profiles/1`, `Projects/1`, `ConfigSets/1`, `Sdks/1`, `Maintenance/1`,
`Toolchains/1.rescan`; §19.20), declared mutating in their schemas, with the
rules above unchanged: FIFO, the `changed` signal (and the affected views'
`update`s) before the reply. A command's result is an outcome of
[API.md](../protocol/API.md) §4.1: `ok` (with `notes` for what it applied
with a warning), `refused` (nothing written, the model unchanged),
`declined`, or `confirm` for a deletion, a nuke, a trust review and the
removal of the working copy (§8.6 there). There is no rolled-back or
partially-applied outcome: a command refused before its first write changed
nothing, and one that performs a user action in several steps and fails a
later one after an earlier one was committed is `ok` with a `warn` note
naming what was not done. One user action is one command: a command that
changes several things (adding a project with its mappings and its
profiles' toolchain, creating a profile from an automatic configuration
set, removing a project with its build state) does them in the daemon,
never as a client's sequence of calls. The query registry becomes interface
methods — `tools` is `loomworks.Toolchains/1.list`, `profile_cache` is
`loomworks.Profiles/1.compiler_cache`. Wire arguments that name entities are references (`{ id }` or
`{ key }`, [API.md](../protocol/API.md) §1.2): the editor sends ids, the CLI the keys the user typed,
resolved with the same messages and exit codes as in-process (§16.9).

### 19.15 Task stream and delegated operations

*Status: master for `lw build` in all its forms (`lw build [<profile>]
[--target <name>]… [--force] [--reconfigure] [-v] [-- <args>]`) in
`runtime-mode daemon` (`daemon/service.lua`, `daemon/runner.lua`,
`daemon/tasks.lua`, `daemon/envscope.lua`; the client in `cli.lua`
`_delegate`), and for the plan form of `lw test` (`lw test [<profile>]
[--no-build] [--junit <file>] [-- <args>]`, §16.16, saved test targets included — the
plan shared with the in-process host in `test_plan.lua`; `lw test --target`,
`--saved`, `--discovered` and `--list` stay in-process, see Routing), and for the preparation of `lw run` (§16.17; see Run;
`run_prep.lua`, the client's `_finish_routed_run`; device runs stay
in-process, see Routing), and for `lw clean [<profile>]` (§16.1; see Clean;
the plan, lines and wipe shared with the in-process clean in `build_run.lua`,
the wipe the in-process build-directory deletion `Workspace:clean_wipe_build_dir`
with a stop predicate); `-v` on `lw test`, `lw run` and `lw clean` (see
Roles and verbose); observed by the editor ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client));
`lw reset [<profile> | --all] [-y]` (§16.30; see
Reset, step 5d); other operations future. The task-streamed interface
methods ("Tasks of interface methods" below: `Build/1`, `Tests/1.run`,
`Launch/1.prepare_run`) are implemented, step 5g.2 part B, and the CLI calls
them; `loomworks.Tasks/1` observation signals, `list` and
`cancel` are implemented, step 5g.2 part A. The editor's operations as calls
("Editor scopes and configure", "Debug", the editor in "Task ownership" and
"Not routed" below; [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"): step 5k, specified (part 0);
the daemon side of "Editor scopes and configure" is implemented (part B1),
the rest plan.*

A running operation streams `task` events on the **task stream** of
[PROTOCOL.md](../protocol/PROTOCOL.md) §14, separate from model changes and observable by every connected
client (a build started by the CLI streams into the editor); the task meta
and the lines are [API.md](../protocol/API.md) §4.2. Ownership, flow control and observer bounds are
[PROTOCOL.md](../protocol/PROTOCOL.md) §14.3–§14.4. For a CLI owner the
stream is its terminal: a client that stopped reading (`lw build | less`
paused) pauses the running step's output, so the build tool then blocks on
its full pipe as it blocks on a paused terminal in-process. The durable
outcome arrives as a `Workspace/1.changed` (§19.12).

**Request.** `lw build` calls `Build/1.build` ([API.md](../protocol/API.md) §8): `args` carries the
parsed command line (`profile`, `targets`, `extra`, `force`, `reconfigure`,
`verbose`), and its outcomes are [API.md](../protocol/API.md) §8.1 — on `refused` the client prints
the message as the in-process host does and exits with that code; on
`declined` it runs the command on the in-process path.

`lw test` — its plan form (§16.16) — calls `Tests/1.run` ([API.md](../protocol/API.md) §10.1); `args` carries
`profile`, `junit`, `extra` and `no_build`. Its plan's pre-build checks are
the in-process ones; a saved test target on a unit a foreign kit builds runs
on a device, which stays with the client as a device run does (`declined`).
In this section "build" stands for either operation unless a rule names
one.

**Same behaviour.** An operation run in the daemon is behaviorally identical to
the in-process operation it replaces — the same step sequence, locks, gates,
status lines, cache write-back, failure lines and exit codes — differing only
in how a step is spawned (streamed) and how a refusal travels (on the stream,
printed by the client exactly as the in-process host prints it). What each
operation does and prints is [API.md](../protocol/API.md) §8–§10. In the daemon the build-directory
locks carry the §19.5 record (holder kind `daemon`, the operation rewritten
configure → build). Only the build tool's own terminal detection differs: its
output reaches the client through a pipe, as when the in-process build is
piped (`lw build | tee`) — so a tool that colours or redraws only on a
terminal does not (ninja prints every `[n/N]` line instead of one updating
status line, compilers drop colour). No colour variable is added for it:
such variables (`CLICOLOR_FORCE`, …) reach every process of the build,
including ones whose output a build script captures, so they would change
what a build does; a user who wants colour sets them in the environment of
`lw build`, which the step receives.

The daemon sends the `Workspace/1.changed` of the task's cache write-back (§19.12)
before its `done`, so the editor has already reloaded the outcome when the
running state clears.

For a test run it is the test plan of §16.16 ([API.md](../protocol/API.md) §10.1), the in-process
host's own code (`test_plan.lua`) run with the task as its host.

**Roles and verbose.** Every `line` the daemon emits carries the role the
in-process host prints that line with (§16.7, [API.md](../protocol/API.md) §4.2). The shared line
producers return the role beside the text (`build_run.step_lines` and the
clean, deploy and test line helpers), so both hosts take it from one place.
So does every note of a reply ([API.md](../protocol/API.md) §4.1): a
notification the workspace raises before the call's task starts goes into
the reply's `notes` with the role the in-process loader prints it with
(`fail` for an error, `warn` for a warning), a test plan's pre-build note
with `plain`, in `note_roles`; the client paints each as its in-process
printer does on standard error. The load's warnings are the loaded
workspace's, not the loading request's: every CLI request that uses the
workspace carries them (§19.13 "Load warnings"; step 6b-α).
The client paints by role exactly as its in-process printer does, and decides
colour per stream after the `quiet` redirection (`--print` sends `out` to
stderr). The daemon never writes escape sequences and never sees
`--color`/`--no-color`, which stay in the client and are not sent.
With `verbose` the daemon emits the command lines itself. Their `env:` line
is computed against the environment the client sent ([API.md](../protocol/API.md) §5, **Environment**
below), before the daemon's own adjustments (such as
`NoDefaultCurrentDirectoryInExePath`), not the daemon's. This holds also when the line is
produced in an asynchronous step callback, outside the environment scope
(`daemon/envscope.lua`), so the inherited environment is passed in
explicitly.

**Run.** `lw run` (§16.17) is split: the daemon **prepares** the launch, the
client **executes** it. The program is the user's own — interactive,
possibly long-running, attached to a terminal — so it never runs in the
daemon. The preparation is `Launch/1.prepare_run` ([API.md](../protocol/API.md) §9.1), `args`
carrying the parsed command line.

The client then closes its daemon connection and finishes the run as the
in-process host does after resolving: `--print` / `--dry-run` print the
report (with the not-built note); otherwise it prints `running <name> [cwd:
<cwd>]: <argv>` and executes `<prefix> <cmd> <args>` itself — attached to its
terminal (inherited standard input, output and error; on Windows not hidden),
in `cwd`, with its own environment plus `env`, the program resolved on its own
search path as in-process (§5.10). The program's exit status is `lw run`'s.
Under `--print` / `--dry-run` the client writes the whole task stream to
standard error, so standard output carries only the report. Hence:

- **Not the daemon's.** The program is the client's child. It holds no lock,
  task or connection: `lw daemon stop|kill|restart`, a retire for a version
  change and an idle exit never touch it, and it does not keep the daemon
  busy (§19.11). Ctrl-C while it runs reaches it and the client through their
  console, as in-process; Ctrl-C during the preparation cancels the task
  (Cancellation).
- **Concurrent runs.** Any number of `lw run` may run at once. Their
  preparations are serialized by the build-directory locks like any builds;
  their programs are not.
- **A build while the program runs** proceeds, as in-process. On Windows a
  running executable cannot be overwritten, so a build that relinks it fails
  at that step as it does today; nothing is added for it (no lock held across
  the run, no retry, no warning).
- **Terminal.** The program's output never passes through the daemon: it has
  the client's real terminal (colour, size, redraws), unlike the build's
  tools above.

**Debug.** *(Step 5k, part B2: implemented, daemon side; the editor calls it
from part C2.)* A debug launch takes the same split: the daemon prepares it
(`Launch/1.prepare_debug`, [API.md](../protocol/API.md) §9.2), the client hands the result to its
debugger, which starts the program — the program is never the daemon's. The
editor keeps device targets in-process and never sends one until step 5n
([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Devices").

**Build scope of a launch.** *(Step 5k, part B2: implemented, daemon side;
its deploy steps' asynchrony and step reports: step 5t, part B.)* The
`build_scope` of `prepare_run` and `prepare_debug` is [API.md](../protocol/API.md) §9.3; the
`target` scope is the launch flow the editor runs before a launch in-process
(§8.8.4 steps 3–6), each build locking as in-process. The CLI sends no
`build_scope`; the editor sends `target`, so an editor launch builds what it
built in-process, not the whole profile.

**Build of a launch target.** *(Step 5t: implemented, daemon side part B, editor side part C.)*
`Launch/1.build` ([API.md](../protocol/API.md) §9.4) builds a launch target as the editor's
in-process launch build does (§8.8.4 steps 3–5, `LaunchTarget:build`),
deploy freshness recorded as in-process. The editor keeps device targets'
builds in-process and never sends one ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations") until
step 5n extends `Launch/1.build` to them (part B2, daemon side: implemented —
a device target's build ends with its post-build deploy).

**Steps of a task.** *(Step 5t: implemented, daemon side part B, editor side part C.)* The steps a
target-scoped task announces are [API.md](../protocol/API.md) §4.3; their ordering, `seq` and the
re-read of `Tasks/1.list` on a gap are [PROTOCOL.md](../protocol/PROTOCOL.md) §14.7.

**Tests.** *(Step 5m, done: part 0 the spec; B1 discovery, B2 runs, debug
preparation and results; the editor's use [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Tests".)* The editor's
test discovery and its runs of selected tests execute in the daemon, like
its builds; only a test debug session's program is the client's. The
methods are `Tests/1` ([API.md](../protocol/API.md) §10.2), on the active profile and its
`view.Tests/1`. In the daemon a probe or run waiting for a build directory
waits in the build-directory operation queue (§5.3, FIFO), and a holder in
another process fails fast (§19.3); discovery is the in-process
`discover_tests` (§8.9.3). The batch `lw test` (`Tests/1.run`) is unchanged
by them. The CLI sends no `Tests/1.discover`, `run_cases` or
`prepare_debug` in this step (`lw test --list` stays in-process, Routing).

**Clean.** *(Step 5c.)* `lw clean [<profile>]` (§16.1) calls
`Build/1.clean` ([API.md](../protocol/API.md) §8.4); `args` carries `profile`. In the daemon the
build-directory locks carry the §19.5 record (holder kind `daemon`, operation
`clean`), and a core-performed wipe runs in the daemon process as the SAME
build-directory deletion as in-process (§4.6, §4.7; one path for both
hosts), under the workspace operation lock taken before the build-directory
locks (§19.3). The removal does not block the daemon's endpoint (pings,
status and other clients are served while it runs). Any write-back's
`Workspace/1.changed` precedes `done` ("Same behaviour" above).

**Reset.** *(Step 5d.)* `lw reset [<profile> | --all] [-y]` (§16.30) calls
`Build/1.reset` ([API.md](../protocol/API.md) §8.5); `args` carries `profile`, `all`, `yes`
(`-y` / `--yes`) and `plan`. The CLI prints a `confirm`'s lines on standard
output and asks the user as in-process: a non-interactive client prints the
in-process refusal naming `-y` and exits 1; a declined prompt prints
`aborted — nothing was removed` and exits 1; a confirmed one sends `reset`
again with `yes` and that `plan`. In the daemon the workspace operation lock
is §19.3's (operation `reset`) and the build-directory locks carry the §19.5
record (holder kind `daemon`, operation `reset`); the removal is the SAME
build-directory deletion as in-process (§4.6, §4.7; one path for both hosts)
and does not block the daemon's endpoint (pings, status and other clients
are served while it runs). A removal still running after its task ended
(timed out) keeps the daemon busy — it neither idles out nor retires — until
it settles, and a daemon that stops meanwhile asks it to stop between
entries. The write-back's `Workspace/1.changed` precedes `done` ("Same behaviour" above).

**Editor scopes and configure.** *(Step 5k part B1: implemented on the
daemon side — `daemon/core_interfaces.lua`, `daemon/service.lua`
`_resolve_units`, `daemon/runner.lua`, `build_run.plan` /
`overseer.plan_units_build`; the editor calls them from part C1.)* `Build/1` grows
additively for the editor's actions ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"); its
interfaces are still drafts, so this is no new version ([PROTOCOL.md](../protocol/PROTOCOL.md) §17.1):
`configure`, `units`, `jobs` and `{ project, target }` targets are [API.md](../protocol/API.md)
§8.2–§8.3. `configure` configures as the editor's configure action does
in-process, also a unit already configured, its locks carrying the §19.5
record (holder kind `daemon`, operation `configure`); a `units` scope runs as
the editor's unit actions run in-process, and an observer resolves its
`meta.units` as for `reset --all` ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Running state"); `jobs` is the
editor's serial `-j1` build.

**Confirmation.** A daemon never prompts ([API.md](../protocol/API.md) §8.6).

**Environment.** A routed build behaves as if the client process had run it,
as [API.md](../protocol/API.md) §5 specifies: the client sends its whole environment and the daemon
applies it to the operation and to nothing else. In the daemon:

- every piece of model work for the request runs with the daemon's process
  environment switched to the client's (on Windows keeping
  `NoDefaultCurrentDirectoryInExePath=1`, §5.10, when the client's lacks it)
  and restored afterwards. These pieces run one at a time (a FIFO), so two
  clients never see each other's environment;
- a step never gets the daemon's launch environment, whose
  loomworks-internal values (the pinned-context marker, `LW_ROOT`, the
  development facility's opt-in) therefore do not leak into builds;
- the daemon's workspace model is kept for the environment it was loaded in:
  a request whose environment differs reloads the workspace from disk first,
  as an in-process load in that environment would read it; the reloaded
  model's entities keep the ids of those they replace (§19.12), so the
  request's references, resolved after the reload, still name their
  entities; while another
  build runs in the daemon, such a request is declined instead. The
  comparison ignores variables that differ between two commands of one shell
  (`_`, `PWD`, `OLDPWD`, `SHLVL`) and between two terminals of one user — the
  terminal's, multiplexer's, SSH and login session's per-window/pane/session
  identifiers (`WT_SESSION`, `TERM_SESSION_ID`, `TMUX`, `TMUX_PANE`, `STY`,
  `WINDOWID`, `SSH_CONNECTION`, `SSH_TTY`, `SSH_AUTH_SOCK`, `GPG_TTY`,
  `XDG_SESSION_ID`, editor terminals' IPC handles `VSCODE_*`, …; names compared
  case-insensitively on Windows), and the hidden `=`-prefixed entries of a
  Windows environment block (cmd.exe's per-drive directories `=C:` and
  `=ExitCode`, which every process started from a cmd.exe — a `.cmd` shim, a
  PowerShell or developer prompt opened from one — inherits); these still
  reach the step unchanged, and the `=` entries are never applied to the
  daemon's own process environment. It is a
  list of what to ignore, not of what to compare: what a load reads is
  open-ended (`${VAR}` references, module and SDK probes, compiler and
  `vcvarsall` variables), and a variable missed by a list of what to compare
  would build with a model read in another environment.

The environment never leaves the machine: it is sent only after the mutual
authentication of §19.8, over the owner-only endpoint of §19.7, to a process
of the same user, is held in memory for the request only, and is never
written to the runtime log, the handle or any workspace file.

**Live workspace.** The daemon loads its workspace on its first operation,
or when an editor attaches (§19.13 "Loaded on attach") (the same load as the in-process path) and keeps it. Besides watching (§19.13), before accepting each operation the daemon applies every pending
external change to its files exactly as its file watcher would — including a
trust refusal (§17.4), which unloads the workspace and is returned as
`refused` — completes or refuses a commit journal by reloading (§19.4), and
waits for a tool rescan a changed `loomworks.json` started. It then resolves
arguments as the in-process host does (§16.9; the same matcher, the same
messages, the client's interactivity).

**Cancellation.** An operation belongs to its client; when a task ends early
and how is [API.md](../protocol/API.md) §7.2. The daemon cancels it when that client disconnects (`lw`
ending on Ctrl-C — see Task ownership for when that is — drops the
connection, which is the cancellation, and exits 130), when the daemon stops
(`lw daemon stop`, idle, retire, root removed, lost lock), or when the
workspace or the operation's subject is unloaded/removed; it terminates the
running step's process tree identity-verified by process id and start time
(§19.5).
A client that loses the connection
after its operation was accepted follows [PROTOCOL.md](../protocol/PROTOCOL.md) §14.5 (for a run: it starts no
program). Cancellation ends with the task: a run's program,
started after it, is never the daemon's to stop (Run). A
connection that owns a running operation is never dropped for silence
([PROTOCOL.md](../protocol/PROTOCOL.md) §14.4, §19.11); the CLI also pings while it waits. The step's processes are the
daemon's, not in the client's console, so the interrupt must reach the
client itself: on Windows a routed client re-enables the console's Ctrl-C for
its process (a process started with it disabled — `start /b`, a new process
group, as Git Bash starts the native program it then signals with `kill
-INT` — would otherwise never see it, while in-process the build's own
processes in that console still stop).

A client disconnects when its connection ends or fails, including a write to
it that fails because the peer went away; a disconnect never ends the daemon
or another client's operations. No lw process is ended by a write to a closed
socket or pipe; processes lw starts keep the platform's default.

**Task ownership.** *(Step 5i: the CLI's two-stage Ctrl-C is implemented,
part F — `cli.lua` `_routed_cancel`, the interrupt handler's interceptor.)* Every task a connection starts — build, test, run preparation,
configure, clean, reset — is owned by that connection ([PROTOCOL.md](../protocol/PROTOCOL.md) §14.3). When the
connection closes for any reason (a CLI's Ctrl-C, the editor quitting or
crashing, `lw` killed, a `--stdio` relay ending), the daemon cancels its tasks
as above.
Configure counts as a connection-owned task from step 5i (cancelled when its
connection closes), but in 5i it reaches the daemon only as a step of a
routed build, test or run preparation; a standalone configure is routed from
step 5k, by the editor (`Build/1.configure`; the CLI has no configure
command).

*(Step 5k part C1, done.)* **The editor as owner.** A task the editor starts
through a call is owned by its connection like a CLI's. The editor cancels
only its own tasks, always with `loomworks.Tasks/1.cancel` (graceful, as the
CLI's first Ctrl-C) and then waits for the task's `done`: a stop from the
task runner, and the pre-emption of §5.4 — a clean cancels the running build
or configure on the same units before it starts — cancel an editor-owned task
this way. A conflicting task another client owns (a `lw build` in a
terminal) is never cancelled (`forbidden`, below): the editor's operation is
sent anyway and meets the build-directory locks that task holds exactly as a
second CLI command would (§16.6). The editor has no second stage: quitting it, or unloading or
swapping the workspace, closes its relay connection ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Teardown"),
which cancels every task it owns.

In the CLI, once the daemon has
accepted the task, the **first Ctrl-C** asks the daemon to stop it
(`loomworks.Tasks/1.cancel`: the daemon stops the running step's process tree
as above — the daemon runs in its own console, so a build never receives the
console's Ctrl-C) and prints one stderr line, `lw: stopping the <op> - press
Ctrl-C again to stop waiting`; `lw` keeps waiting until the task has stopped
(its `<op> stopped: …` line is printed as usual). A **second Ctrl-C** makes
`lw` leave at once, closing the connection, while the daemon finishes
stopping the task. Either way `lw` exits 130 after an intercepted Ctrl-C —
also when the task ended before the cancel landed (the daemon then answers
that there is no running task) and when the connection is lost meanwhile —
and a run's program is never started. A Ctrl-C before the daemon has accepted
the task closes the connection and exits 130 (there is nothing to cancel
yet). Only Ctrl-C is two-stage: Ctrl-Break, a
closed console, a hangup and a termination request end `lw` at once
(closing the connection). An attached run (§19.1 "Loopback": the runtime is
the `lw` process itself) is unchanged — a Ctrl-C ends it. *(Future, not
planned in a step: `lw build --detach` hands a task over to the daemon, which
then owns it with no connection.)*

**Tasks of interface methods.** *(Step 5g.2: `loomworks.Tasks/1` — `list`,
`cancel`, the `started` / `ended` signals with the `task_id` filter — is
implemented, part A; the task-streamed methods (`start.meta` naming the
method, `done.result`), part B; the observation bound to the subscription,
step 5g.3 (`tasks.lua` `Task:_observes`).)* The task stream is a
**transport** mechanism ([PROTOCOL.md](../protocol/PROTOCOL.md) §14), not part of any one interface. The
task-streamed methods, their task results and `loomworks.Tasks/1` are
[API.md](../protocol/API.md) §7: `Build/1.build`, `Tests/1.run` and `Launch/1.prepare_run` from step
5g.2, `Build/1.configure` and `Launch/1.prepare_debug` from step 5k,
`Launch/1.build` from step 5t, and a module's log stream. `status.tasks`
(§19.11) stays as it is, frozen.

**Observation, late joining and cancel** are [PROTOCOL.md](../protocol/PROTOCOL.md) §14.6 and
[API.md](../protocol/API.md) §7.

**Routing.** A client routes an operation to the daemon only when the daemon
carries every argument form the client was given; any other form runs on the
in-process path (transition) and a workspace the machine would refuse (§17.4)
is never routed. For `lw build` in step 3: routed in `runtime-mode daemon`
when this command has a matching daemon (it was used, launched or restarted
by the version handshake, §19.9/§19.10), the arguments parse, and the working
copy and cache verify; **not routed** — the in-process path exactly as
before — with `--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI` (§19.1),
`--break-locks` (its ask-and-kill recovery stays with the client process), a
version bypass, a daemon that is hung, starting, foreign or could not be
started, and an argument `cmd_build` refuses (it reports it). In
`runtime-mode daemon`, a build the daemon does not run is never silent:
except for the explicit opt-outs (`--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI`)
and the cases the in-process path itself reports (an argument `cmd_build`
refuses, a workspace the machine refuses), exactly one line on standard error
says why, and the build runs in-process. The version handshake's and the
launch's lines (§19.9, §19.10) are that line for a version bypass, a newer
daemon, and a daemon that is hung, still starting or could not be started; a
declined request prints `lw: the workspace daemon declined the build
(<reason>); running without it`; a runtime held by an attached lw command is
waited for, or the build fails "workspace busy" (§19.2); every other case — a
runtime held by another host, `--break-locks`, a daemon that cannot be reached
or fails before accepting, a failed endpoint check — prints `lw: the
workspace daemon could not take the build (<reason>); running without it`.
While the daemon is opt-in, an accepted build prints one dim line on standard
error before its output — `lw: building through the workspace daemon (pid N)`
— which is removed when the default flips; a refusal prints neither.

*(Step 5e:)* in `runtime-mode daemon`, the attached selections
above (`--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI`, a failed background
launch) — `--break-locks` given with one of them included —
no longer run the routed operations in-process: they run them attached, over
the loopback transport (§19.1 "Loopback during the transition"), with the same arguments, refusals
and output. An attached operation prints no `… through the workspace daemon
(pid N)` line and no "running without it" line for its attached selection.

`lw test` (step 5) is routed by the same rules, an argument `cmd_test` refuses
taking the place of one `cmd_build` refuses — as does a form the request does
not carry (`--saved`, `--discovered`, `--list`, device options, §16.16,
§16.34): it runs in-process — and its lines name the test: `lw: the workspace daemon
declined the test (<reason>); running without it`, `lw: the workspace daemon
could not take the test (<reason>); running without it` and `lw: testing
through the workspace daemon (pid N)`. Its named-executable form, `lw test
--target <exe>…` (local or on a device, §16.16, §18), is not carried in this
step — its device locks, staging and liveness stay with the client process —
and prints `lw: the workspace daemon could not take the test (--target runs
test executables in this process); running without it`.

`lw run` (step 5) is routed by the same rules for its preparation
(Run), an argument `cmd_run` refuses taking the place of one `cmd_build`
refuses (`--print` with `--prefix` among them), and its lines name the run:
`lw: the workspace daemon declined the run (<reason>); running without it`,
`lw: the workspace daemon could not take the run (<reason>); running without
it` and `lw: preparing the run through the workspace daemon (pid N)` (before
the build's output; on standard error like the others). A run on a device
(§16.17, §18) is not carried in this step — its device locks, staging and the
remote program's liveness stay with the client process:

- a device option (`--device`, `--fresh`, `--timeout`, `--no-wait`, a log
  option; §18.3) prints `lw: the workspace daemon could not take the run
  (device options run the program on a device in this process); running
  without it`;
- a profile one of whose units builds with a foreign kit (§18.1, the kit's
  execution platform — known before anything is built) is `declined` before
  any side effect: `lw: the workspace daemon declined the run (profile '<p>'
  builds for <platform>; device runs stay in this process); running without
  it`;
- a target found foreign only by probing its built artifact (§18.1, no kit
  platform) is known only after the daemon built it: the task ends with
  `exit_code` 0, no `launch`, and `device = true`, before any deploy (of the
  `target` build scope: before its post-build deploy, "Build scope of a
  launch" below); the
  client prints `lw: the workspace daemon could not take the run (<name> runs
  on a device in this process); continuing without it` and continues
  in-process from the deploy (deploy → stage → execute, §18.4–§18.5) without
  building again.

The editor's own run and debug launches stay in-process in this step; from
step 5k their preparation is routed (`prepare_run`, `prepare_debug` with
`build_scope = "target"`; [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"), a device target's
launch going through `Devices/1` from step 5n, and a preparation that ends
with `device = true` refused in the editor from step 6b-α ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor
operations").

`lw clean` (step 5c) is routed by the same rules, an argument `cmd_clean`
refuses taking the place of one `cmd_build` refuses, and its lines name the
clean: `lw: the workspace daemon declined the clean (<reason>); running
without it`, `lw: the workspace daemon could not take the clean (<reason>);
running without it` and `lw: cleaning through the workspace daemon (pid N)`.
It has no form the daemon does not carry. Configuring has no command of its
own: it is a step of the routed build (`lw build --reconfigure` forces it,
§16.4), and runs in the daemon with it.

*(Step 5d.)* `lw reset` is routed by the same rules, an argument
`cmd_reset` refuses (an unknown flag, `--all` with a profile) taking the
place of one `cmd_build` refuses, and its lines name the reset: `lw: the
workspace daemon declined the reset (<reason>); running without it`, `lw:
the workspace daemon could not take the reset (<reason>); running without it`
and `lw: resetting through the workspace daemon (pid N)` — printed when the
reset is accepted, so after the confirmation. Each of the two requests of a
confirmed reset is routed or not on its own: when the second one cannot be
routed (the daemon stopped or was retired while the user answered), the
client says so on the could-not line and runs the reset in-process with the
user's answer, never asking again; the in-process reset plans again and
refuses with the changed-plan line above when its plan differs from the one
shown. It has no form the daemon does not carry.

**Not routed.** These commands touch build directories but stay on the
in-process path in this step; they are not routed commands, so they print no
daemon line, and their cross-process locks (§16.6, §19.3) serialize them with
the daemon's operations as with any other process:

- `lw nuke` — removes the workspace's build state (`.lw/build/`, the build
  and health caches), taking every build-directory lock first (§19.3); the
  editor's nuke in `daemon` mode is `Maintenance/1.nuke` ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Model
  writes");
- `lw device clean` (§16.34) — its device locks and the device's staging stay
  with the client process, as for a device run;
- the editor's own operations, including its clean, delete and configure
  actions ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)) — until step 5k, which routes its builds, configures,
  module cleans and launch preparations ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"); its
  deletions (a profile, a configuration unit, an orphaned or stray build
  directory, all orphans, a project with its build state) are, in `daemon`
  mode, `Maintenance/1.execute_deletion` tasks ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Model writes"), and
  in-process ones otherwise, holding the workspace operation lock and the
  build-directory locks of §19.3 like every other deletion path (§4.6); its
  device-target launches until
  `Devices/1` (step 5n, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"). Its test discovery, test runs
  and test debug preparations move to `Tests/1` in step 5m ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Tests").

### 19.16 The editor as a client

The editor client's behavior is specified in
[loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client).
Its sub-headings, which references to it quote, are:

- "End state"
- "Through the relay": "The relay process", "Waiting notes", "Exit before
  `welcome`", "Following a stopped or retiring daemon without relaunching
  it" ("Drop", "Retiring", "Status 14", "Status 16"), "Skipping an
  incompatible daemon"
- "Interface client", "Editor operations", "Model writes", "Availability"
- "Public API", "A default target is addressed by its profile alone"
- "LSP configuration": "Reads", "Readiness", "Waiting", "Unavailable",
  "Running clients", "Owned databases", "Re-evaluation", "Options", "Buffer
  → project"
- "Tests": "Discovery", "Runs", "Debug", "Output", "Unavailable or
  unloaded", "Neotest"
- "Devices", "Tasks in the task runner"
- "The observer" (formerly "Step 4: the observer"): "Host binary" ("Pre-launch
  probe", "Plugin pin", "The plugin-managed `lw`", "Channel upgrades",
  "Retiring an incompatible daemon", "Install location"), "Launch",
  "Connect" ("Incompatible daemon", "Keepalive"), "No relaunch after a stop",
  "Loaded on attach", "Unloaded on disconnect", "Retiring", "Model changes",
  "Tasks" ("Resolving", "Running state", "Joining late", "Output", "End",
  "UI"), "Teardown", "Quiet degradation"

The daemon's side of "Loaded on attach" is §19.13 "Loaded on attach"; the
order of a task's write-back `Workspace/1.changed` before its `done` ("Tasks",
"End" there) is §19.15 "Same behaviour"; the relay's own behavior is §19.10
"Connections".

### 19.17 Parity

*Status: master for `lw build` (`tests/daemon_build_cli_spec.lua`: every
build form both ways — the same output, exit code and persisted cache;
`tests/daemon_build_service_spec.lua`, `tests/daemon_real_build_spec.lua`)
and the batch `lw test` (`tests/daemon_test_cli_spec.lua`: passing, failing,
runner arguments, JUnit (also a runner that wrote none), a failed build, an
unknown or missing profile, both ways — the same output, exit code, JUnit
files and persisted cache) and `lw run`
(`tests/daemon_run_cli_spec.lua`: the default target, a named build target
and command configuration, the two-operand form, forwarded arguments,
`--cwd`, `--prefix`, `--print[=json]`, `--dry-run`, `--no-build`, a failed
build, a failed deploy, an unknown, ambiguous or unset target, the program's
exit status, both ways — the same output, exit code, deploy records and
persisted cache; plus: the program runs after the task ended and every lock
was released (a `lw build` of the profile proceeds while it runs), it
survives `lw daemon stop`, two runs at once, the not-carried device forms
print their line) and `lw clean` (`tests/daemon_clean_cli_spec.lua`: a module
clean, a core-performed wipe, a refused unsafe path, nothing to clean, a
failing step, an unknown or missing profile, both ways — the same output, exit
code, build-directory contents and persisted cache; plus cancellation during a
step and during a wipe; `tests/daemon_clean_service_spec.lua`: the daemon
answers `ping` while a wipe runs, a cancelled wipe stops between entries and
holds its locks until it has); `lw reset`
(`tests/daemon_reset_cli_spec.lua`: a profile reset, `--all` with an
orphaned directory, a directory shared with another profile kept, nothing to
reset, `-y`, a confirmed and a declined prompt, a non-interactive refusal
without `-y`, an unknown or missing profile, both ways — the same output,
exit code, build-directory contents and persisted cache; plus a plan changed
between listing and confirmation, a second request that cannot be routed
(the daemon stopped while the user answered) and cancellation during the
removal; `tests/daemon_reset_service_spec.lua`: the daemon answers `ping`
while a reset removes, `confirm` takes no lock and changes nothing, a changed
plan is refused, a held build-directory lock refuses the reset naming the
holder, a cancelled reset stops between entries, leaves the cache `unknown`
and holds its locks until it has, `--all` is one task without a profile and
an observer shows every profile with one of its units `deleting`; a directory
that cannot be removed is `tests/cli_reset_spec.lua`'s, the deletion and its
check being the one path both hosts run); the projection half #88. For
`lw build`, `lw test`, `lw run` and `lw clean` also with `-v`, and with
`--color=always`: the same bytes both ways (each line the same text and
role; in `tests/daemon_{build,test,run,clean}_cli_spec.lua`, also with a
module environment, the `env:` line computed against the client's
environment).*

Because both paths share the deserializer and serializers, correctness is
differential: running an operation in-process and through the daemon MUST
leave byte-identical workspace files, and the client projection MUST serialize
identically to the daemon's model. Every operation moved in §19.19 carries such
a test before its routing is enabled.

### 19.18 Device and log records

*Status: implemented in step 5n (parts B2, B3 and C3: `Devices/1`,
`Launch/1.device_log`).*

Device logs travel on the task-stream channel as normalized records
`{ ts, level, tag, pid, message, fields? }` (unknown level → a default,
unknown keys → `fields`). A module's device listing, install, launch and
stop run in the daemon from step 5n ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Devices"); the log stream is
`Launch/1.device_log` ([API.md](../protocol/API.md) §9.5), its records sent
as that interface's `log` signal.

### 19.19 Transition order

*Status: steps 1–5 done on `staging/daemon` except 5q and the optional
parts 5k D and 5m D; 6b-α next, then 6, 6b-β,
6c and 8a–8c. Each step is shippable on its own and keeps master green.*

1. **Operation locks** — §19.3, §19.4 and §19.5 on the in-process path: the
   workspace operation lock, the lock order, `lw nuke` taking build locks,
   journalled multi-file commits, dead/hung holder recovery and
   `--break-locks`. No daemon involvement.
2. **Lifetime** — §19.2, §19.6–§19.11 behind `runtime-mode daemon`: the
   daemon starts and stays running, answering `ping`/`status` only; `lw daemon
   status|stop|restart|kill`; the runtime log; the Runtime row.
3. **First operation** — `lw build` routed to the daemon (§19.15). *(Done.)*
4. **Editor connects** — observer + keepalive ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)). *(Done.)*
5. **Remaining operations**, one at a time, each with a parity test (§19.17);
   then the loopback transport, so attached runs use the same code; then the
   CLI and the editor stop loading the workspace themselves. Routed so far:
   the batch `lw test`; the preparation of `lw run` (§19.15, Run; protocol
   6) — the program runs in the client; device runs and the editor's
   launches stay in-process.
   - **5c — `lw clean`** (§19.15, Clean; protocol 8): executed in the daemon
     under exclusive build-directory locks, with the in-process deletion
     safety for a core-performed wipe. Configuring is already routed as a
     step of `lw build`. `lw nuke` and `lw device clean` stay
     in-process (§19.15, Not routed). *(Done.)*
   - **5d — `lw reset`** (§19.15, Reset; protocol 9): executed in the daemon
     under the workspace operation lock and exclusive build-directory locks,
     through the same deletion as in-process; its confirmation asked by the
     client from the daemon's listing, the answer carrying a token of the
     listed plan. *(Done.)*
   - **5e — Loopback for the routed operations** (§19.1 "Loopback during the
     transition"): in `daemon` mode an attached selection runs `lw build`,
     `lw test`, the preparation of `lw run`, `lw clean` and `lw reset` through
     the daemon's own server and service in the client process, over the
     loopback transport, holding the runtime lock in `attached` mode; the
     `in-process` default is unchanged. The transport and the attached
     server are in place, and the CLI uses them (done). Profile and
     project mutations, publish / import / pull and devices are routed —
     shared and attached — later, with the command machinery of §19.14. The
     editor gets no loopback runtime (D8 is superseded) and no private
     daemon: when the shared daemon cannot be started it runs degraded
     (steps 5i, 5s). *(Done.)*
   - **5f — Plugin/binary boundary**: the classification manifest and the
     ratcheting guard test (`tests/split`), no behaviour change. *(Done,
     #149.)*
   - **5g.1 — Transport 11 and the root object** *(done)* (§19.8, §19.20): the envelope
     (`call`, structured `error`, `signal`), `loomworks.Root/1`
     (`describe`, `schema`, `subscribe`, `unsubscribe`, `objects_changed`),
     `welcome.objects`, `protocol_min`; the daemon accepts protocols 10 and
     11; one dispatch table, through which the protocol-10 kinds are served as
     v0 aliases (no behaviour change); the schema directory with the
     meta-schema, the transport, `loomworks.Root/1` and `loomworks.Common/1`
     documents; the schema validator; the lint and additive-ratchet tests.
   - **5g.2 — Existing operations as interfaces** *(done)*: `loomworks.Build/1`,
     `Tests/1.run`, `Launch/1.prepare_run`, `Toolchains/1.list`,
     `Profiles/1.compiler_cache`, `Workspace/1` (`header`, `changed`),
     `Tasks/1` (`list`, `cancel`, the subscription) and
     `lw.internal.Snapshot/1`. The CLI switches to calls in the same step (it
     is the same artefact); the v0 kinds keep serving older editors. The
     conformance runner over the standard-I/O transport, with transcripts for
     each. *(Done. Part A: `Workspace/1` (`header`, `changed`),
     `Tasks/1` (`list`, `cancel`, the subscription),
     `lw.internal.Snapshot/1`, `lw daemon run --stdio`, the conformance runner
     and the transcripts of these and `Root/1`. Part B: `Build/1`,
     `Tests/1.run`, `Launch/1.prepare_run`, `Toolchains/1.list`,
     `Profiles/1.compiler_cache`, `Workspace/1.header_changed`, opaque string
     ids and the CLI's switch to calls (`daemon/calls.lua`).)*
   - **5g.3 — Policies** *(done)*: `lw_version` equality as the CLI's policy through
     `describe` (§19.9); busy = owns a task or a command in flight (§19.9); the
     editor's observer re-describes on connect and subscribes to `/tasks` and
     `/workspace` when the daemon offers them (later too, on
     `objects_changed`), otherwise uses the v0 broadcasts; the guard's
     interface ratchet (every plugin-side call names an interface version that
     has a schema and client-conformance transcripts; a site naming an
     interface at run time is an allow-listed exception). *(Done:
     `ensure.policy`, `Server:conn_busy` / `status.busy_clients`,
     `observer._subscribe`, transport-11 delivery by subscription, the guard's
     interface ratchet in `tests/split`. Deferred to 5j: checking that the
     methods and signals the plugin uses on an interface version are covered
     by its transcripts — done: each versioned table declares
     the `methods` the plugin calls and the `signals` it handles, every
     interface call names a declared method, and every declared one is sent
     or expected in that version's transcripts; uses not yet transcribed are
     an allow-listed, exact-match exception.)*
   - **5h — Editor-side binary selection and provisioning** ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Host
     binary"), used first only for the observer's binary:
     - **5h.1** — the selection order (explicit, `lw` on the search path, the
       plugin-managed `lw`, `binary.prefer`), the install-location rule, the
       status page and `:checkhealth` listing; `daemon/host_binary.lua` and
       its reads of `lw.pin` and of lw's pinned cache are removed. No
       downloads. *(Done.)*
     - **5h.2** — binary side: `lw version --json` (also a release asset
       listed in `SHA256SUMS`), the daemon commands as pin-redirect commands
       (§16.23), the install-folder override for an `lw` the plugin runs
       (retired with self-contained executables, §16.22). *(Done.)*
     - **5h.3** — download, verify (against the plugin's hash) and cache the
       managed `lw` under the editor's data directory; `binary.download`,
       `binary.release_url`; pruning of other managed binaries. *(Done.)*
     - **5h.4** — the plugin's own pin (a hash per host asset, outside any
       release asset), pinning only published releases, the interface check
       at pin time. *(Done: [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Plugin pin"; first seeded with
       0.1.43-beta.15, which predates the descriptor. The release sequencing
       that committed the pin on the build commit was retired when the plugin
       moved to its own repository.)*
     - **5h.5** — channel upgrades through the verified `lw`
       (`binary.channel`, `lw release query`, §16.42; [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Channel
       upgrades"), compatibility-driven selection ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Pre-launch
       probe"), the editor's retirement of an incompatible idle daemon
       ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Retiring an incompatible daemon"). In parts: the spec; the
       binary's `release query` *(done)*; the probe in the selection
       *(done)*; the retirement *(done)*;
       `binary.channel` *(done)*.
   - **5i — Connections** (§19.10 "Connections", §19.11, §19.15 "Task
     ownership", [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) End state): `lw daemon run --root <root> --stdio`
     becomes a connect-or-start relay — discovery, launch, authentication and
     the handshake for the editor, which then reads none of lw's internal
     files; it forwards frames opaquely, so it never changes for a new
     interface (this replaces the separate `lw daemon attach --stdio` bridge
     planned earlier). Every CLI command that already uses the daemon
     connects or starts likewise (no new command is routed; the `in-process`
     default is unchanged). The relay's handshake (§19.8 "Relay handshake":
     the client's `hello` read first, `server_proof` verified before
     forwarding, `welcome.daemon` and `welcome.via` added), its bounded
     buffering (`RELAY_HIGH_WATER`), its wait on a retiring daemon
     (`RELAY_RETIRE_WAIT`), its `--no-launch` form that only waits for a
     daemon (the editor's after a stop or a busy retirement; with
     `--skip-instance`, after an incompatible daemon) and its exit
     statuses (§19.10 "Relay exit status"). Relays register nothing; `lw daemon list` and
     `kill --all --strays` show them as connections of their daemon, while a
     `--stdio` process the runtime lock names is still a runtime (older
     pins). Each task is owned by the connection that
     started it and cancelled when that connection closes; the CLI's two-stage
     Ctrl-C; the process-tree kill on Windows. The idle rule becomes "no
     connections and no background work", background work bounded by
     `BACKGROUND_MAX_DURATION` (10 minutes). The conformance runner gets its
     isolated daemon per case through the hidden `--private` flag, gated by
     `LOOMWORKS_TEST_PRIVATE_STDIO=1`, or a temporary root. A relay the
     editor starts applies the **editor's** compatibility rule (§19.9
     "Editor retirement", [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Retiring an incompatible daemon"), not the
     CLI's `lw_version` equality, and never restarts a daemon on its own;
     the editor's retirement goes through the relay connection.
     In parts: the spec *(done)*; B — connection code extracted from the
     CLI into `daemon/connect.lua` *(done)*; C — the relay and `--private`
     *(done)*; D — `lw daemon list` / `kill` classification of relays
     *(done)*; E — the idle rule
     *(done: tool detection past the cap is abandoned by unloading the
     model, a run past it stops the daemon through the stop path)*;
     F — the CLI's two-stage Ctrl-C *(done)*; G — the editor uses the relay
     ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Through the relay"): G0 its spec *(done)*, G1 the relay
     transport and lifecycle with the relay's `--retiring` flag (§19.10 "A
     named retiring daemon") *(done)*, G2 the incompatible-daemon policy over the
     relay *(done)*.
   - **5r — Warm restarts** (§19.11 "Warm restarts", §16.43), right after 5i
     (ids are not in order), in parts: A — the spec *(done)*;
     B — the idle grace (`IDLE_GRACE_SECONDS` = 45 s as the default of
     `daemon-idle-timeout`, the setting still overriding it) *(done)*;
     C — the
     fingerprinted per-module-type tool cache in `tools.json` (fingerprint
     includes the `lw` identity with its `lw_version`, so results of a retired
     daemon of another version are not reused; each type written atomically
     on completion, an interrupted type not written; reused on the next start
     when its fingerprint matches; the same check in the in-process CLI)
     *(done)*;
     D *(optional)* — `lw daemon status` shows the idle deadline (`status`
     `idle_timeout` / `idle_deadline`) *(done)*.
   - **5j–5o — Editor consumers move to interfaces**, each step landing its
     interfaces with their schemas and transcripts: `view.Header/1` and
     `view.ProjectsIndex/1` (5j); the editor's operations as calls,
     `Launch/1.prepare_debug`, `DebugConfig/1`, the editor's task runner
     tasks on `Tasks/1` (5k); `LspConfig/1` (5l); `Tests/1.discover` and
     `view.Tests/1` (5m); `view.Workspace/1` and `Devices/1` (5n); the
     command methods of `Workspace`, `Profiles`, `Projects`, `ConfigSets`,
     `Sdks` and `Maintenance` (5o).
     - **5j — Header and project index** (§19.13 "Views"; [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Interface
       client"), in parts: A — the guard's method/signal coverage deferred
       from 5g.3 (#185) *(done)*; 0 — spec: the two views' fields,
       the `update` rule and the two sources *(done)*; B — daemon
       side: the schemas of `loomworks.view.Header/1` and
       `loomworks.view.ProjectsIndex/1`, their transcripts on the `empty` and
       `shell` fixtures, and a new `daemon/views.lua` mounted on `/views`,
       sending `update` where `header_check` runs, with the ids the daemon
       alone fills (`active_profile_id`, `config_set_id`, the records' `id`
       and `active.unit_id`) *(done)*; C — editor side: a view
       store fed by the observer's subscription or by the in-process builder,
       lualine and the status page's header moved onto it,
       `lw.buf_project` (separator-bounded longest prefix), the lualine → `loomworks.events` edge removed and the
       reach-in counts lowered *(done)*.
     - **5k — Editor operations as calls** (§19.15 "Editor scopes and
       configure", "Debug", "Build scope of a launch", "The editor as owner";
       [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"; §19.20 `DebugConfig/1`), in parts: A —
       preparation with no behaviour change, in-process only: one debug-spec
       seam shared by both hosts, the adapter defaults and resolution in a
       host-neutral module, and a guard ratchet on the editor's operation
       call sites; 0 — spec *(done)*; B1 — daemon side: `Build/1`
       `configure`, `units`, `jobs` and project-qualified targets, with
       schemas and transcripts on the `shell` fixture *(done)*; B2 — daemon side:
       `Launch/1.prepare_debug` with `Common/1` `DebugSpec`, `build_scope` on
       both preparations, and `DebugConfig/1` on `/debug`, with schemas and
       transcripts *(done)*; C1 — editor side: the call API with owned tasks, routing
       of builds, configures and module cleans with the availability rule,
       the task-runner bridge (editor-owned and read-only observed tasks),
       cancellation, one progress entry per owned task, and retirement
       counting the editor's own tasks (needs B1) — delivered as C1a (the
       call API, routing, availability, cancellation, the one progress
       entry, retirement) and C1b (the task-runner bridge: owned and
       read-only observed tasks in overseer, `Open overseer` on their rows)
       *(C1a and C1b done)*;
       C2 — editor side: run and
       debug through `prepare_run` / `prepare_debug` for non-device targets,
       the module-target debug unified with run (§8.9.6), the debug adapters
       section on `DebugConfig/1`, the reach-in counts lowered (needs B2 and
       C1) *(C2 done)*; D *(optional)* — a real-daemon
       end-to-end suite for the editor client, unless folded into C1 and C2.
       B1 and B2 are independent. *(Done, except the optional D.)*
     - **5l — LSP configuration through the daemon** ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "LSP
       configuration"; §19.20 `LspConfig/1`; [loomworks.nvim `spec/plugin.md` §9.2](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#9-lsp-integration), [loomworks.nvim `spec/plugin.md` §9.7](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#9-lsp-integration), [loomworks.nvim `spec/plugin.md` §9.8](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#9-lsp-integration)), in parts:
       0 — spec *(done)*; A — preparation with no behaviour
       change, in-process only: one host-neutral builder of the state
       (entries with `db_state`, `db_dir` and `db_rev`, options, readiness),
       an LSP source the LSP layer and the integrations read instead of the
       model, and the reach-in counts lowered;
       B — daemon side: `LspConfig/1` on `/lsp` (`get`, `set_option`,
       `changed`) with schema and transcripts on the `shell` fixture, the
       `changed` emission where `header_check` runs and on a database
       written; C — editor side: the cached state and its reads, the
       hold and withhold rules with no in-process fallback (held while
       waiting for the daemon, withheld when it cannot give the state),
       buffer → project by `lw.buf_project`, the hold released on the
       daemon's `ready`, the options written only through `set_option`,
       the editor's own database generation stopped in `daemon` mode,
       and a real-daemon end-to-end check
       (needs A and B; may land as C1, the read path, and C2, the writes and
       the generation owner). *(Done.)*
     - **5m — Tests through the daemon** (§19.13 "The tests view"; §19.15
       "Tests"; [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Tests"; §19.20 `Tests/1`; §8.9; [`LOOMTEST.md`](https://github.com/samienne/loomworks.nvim/blob/master/LOOMTEST.md)), in
       parts: 0 — spec (this; the `loomworks.view.Tests/1` schema, the
       `loomworks.Tests/1` `results` signal schema and the shared result
       types in `loomworks.Common/1`; the `Tests/1` method schemas land with
       their handlers in B1 and B2, since the interface registry does not
       mount a schema method without a handler); A — preparation with no
       behaviour change, in-process only: one host-neutral builder of the
       view's shape (unit states, explicit suite nodes, unit-scoped ids with
       an id provider), a test source the loomtest and neotest adapters read
       instead of the model, loomtest accepting adapter-supplied suite
       nodes, exact-id results and an optional adapter-executed `start`
       capability, a guard ratchet on the new files; B1 — daemon side:
       `Tests/1.discover` (task) and `view.Tests/1` on `/views` with the
       `stale` marking and the per-node last results, a harness-only stub
       test module for the transcripts (it ships only in tests: a static
       TestUnit discovering from JSON and running an `nvim -l` script that
       prints gtest-format output and results), schemas and transcripts
       *(done)*; B2 — daemon side: `Tests/1.run_cases`, the `results` signal,
       `Tests/1.result`, `Tests/1.prepare_debug` and `Tests/1.collect`, the
       per-run results file, schemas and transcripts (B1 and B2 independent
       after 0); C1 — editor side: the view in the view store, the test
       source's daemon form, the explorer's header, tree, signs and inline
       marks on it, the `stale` → `discover` trigger, the unavailable and
       unloaded handling, no in-process discovery in `daemon` mode, the
       neotest refusal *(done)*;
       C2 — editor side: runs through `run_cases` (owned
       overseer rows, cancel, live status from `results`), debug through
       `prepare_debug` → the debug seam → `collect`, `ensure_built` unused in
       `daemon` mode, the test output and error locations from `result`, a
       real-daemon end-to-end check *(done)*; D *(optional, later)* — last results persisted across daemon
       restarts, and a daemon-mode neotest (positions and results from the
       view, runs through a CLI relay such as `lw test --select <id>…`,
       designed with `lw test --list`). *(Done, except the optional D.)*
     - **5s — No editor fallbacks** ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Availability"; before 5n): in
       `daemon` mode an operation the daemon cannot carry is refused, never
       run in-process; the debug-adapter section and its writes fail
       likewise. The `daemon` editor mode becomes the default, with
       `in-process` deprecated for one beta cycle (§19.1), then 6b-α and 6b-β. The
       status page's body sections and the model's mutations stay on the
       editor's in-process model until 5n (reads) and 5o (writes), marked
       transitional ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"); device-target launches
       stay in the editor until `Devices/1` (5n). The editor no longer reads
       `LOOMWORKS_RUNTIME`, `LOOMWORKS_NO_DAEMON` or `CI` for its mode, so a
       headless editor under `CI=true` (this repo's test suite included)
       defaults to `daemon`. *(Done.)*
     - **5t — Launch-target builds as one call** (§19.15 "Build of a launch
       target", "Steps of a task"; [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"; §19.20
       `Launch/1`, `Tasks/1`; after 5s, before 5n), in parts: 0 — spec *(done)*; B —
       daemon side: `Launch/1.build`, the target-scope phase planner shared
       with the preparations, the asynchronous cancellable deploy phases,
       `force` on the preparations, `TaskInfo.steps` and the `Tasks/1.step`
       signal on every target-scoped task, schemas and transcripts on the
       `shell` fixture (a dependency, a pre-build deploy, a failing step, a
       cancel) *(done)*; C — editor side: `LaunchTarget:build` through
       `Launch/1.build` for non-device targets (one owned task, the conflict
       question before the call, no editor deploy), the progress entry and
       the task runner row following the current step, prepare_run /
       prepare_debug's progress likewise *(done)*. Device targets' builds stay the
       editor's until 5n, which extends `Launch/1.build` to device targets
       with the post-build deploy, leaving install and launch to
       `Devices/1`. *(Done.)*
     - **5n — Workspace view and devices through the daemon** (§19.13 "The
       workspace view"; [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Devices"; §19.18; §19.20 `view.Workspace/1`,
       `Devices/1`, `Profiles/1`, `Launch/1`; after 5s and 5t), in parts:
       0 — spec (this; the `loomworks.view.Workspace/1` schema; the
       `Devices/1` method schemas land with their handlers in B2, since the
       interface registry does not mount a schema method without a handler);
       A — preparation with no behaviour change, in-process only: one
       host-neutral builder of the view's shape, the status page's sections
       split into rendering from that table and their actions, a device
       source seam, the guard ratchet (the status page's rendering
       byte-identical before and after); B1 — daemon side:
       `view.Workspace/1` on `/views` (`update` only on a difference, ids
       daemon-only), schema and transcripts on the `empty` and `shell`
       fixtures; B2 — daemon side: `Devices/1` on `/devices` (`list`, `scan`,
       `install`, `launch`, `stop`, the `changed` signal),
       `Profiles/1.set_device` / `clear_device`, `Launch/1.build` extended to
       device targets with the post-build deploy, and a tests-only stub
       device module, schemas and transcripts (B1 and B2 independent after
       A; B2 *done*: an install holds its build directory, then
       the device lock — §19.3's order — a launch and a stop the device lock
       only); C1 — editor side: the status page's body from the view, nothing of
       it built in-process in `daemon` mode, the `unavailable — <why>` lines;
       C2 — editor side: the device list, choice and launches through
       `Devices/1` (refused while disconnected), the device-log reach-in
       removed, an end-to-end check with the stub module; B3/C3 — the device
       log stream as `Launch/1.device_log`, daemon and editor sides. Runner
       devices (§18), `lw device clean` and `lw run --device` stay out of
       5n. *(Done.)*
     - **5o — Model writes through the daemon** (§19.14 "As interfaces";
       [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Model writes"; §19.20 `Workspace/1`, `Profiles/1`,
       `Projects/1`, `ConfigSets/1`, `Sdks/1`, `Maintenance/1`,
       `Toolchains/1.rescan`; after 5n), in parts: 0 — spec, and references
       by id resolved straight to their objects (no key round-trip in the
       daemon's operation path); A0 — launch configurations as domain
       objects with ids (spec §1.2.1), no behaviour change; A1 — a
       host-neutral command layer with one function per command, the
       editor's orchestration moved into it, no behaviour change; A2 —
       deletion plans with tokens for every deletion target, on top of the
       fix that makes every in-process deletion take the operation and
       build-directory locks (its own PR on `staging/daemon`, merged
       first); B1 — `Workspace/1` commands; B2 — `Profiles/1` and
       `ConfigSets/1`; B3 — `Projects/1`; B4 — `Sdks/1` and
       `Toolchains/1.rescan`; B5 — `Maintenance/1.execute_deletion`; B6
       *(optional)* — `Maintenance/1.nuke`; C0 — the status page's actions
       and dialogs behind one seam, no behaviour change; C2 — the seam as
       calls by id; C1 — the status page's body from the view (5n part C1,
       rebased: its transitional key resolution removed), last.
       `Profiles/1.list` and `query`, `Maintenance/1.orphaned`, `locks` and
       `unlock`, `Sdks/1.list` and `Workspace/1.create` stay out of 5o; the
       CLI's model commands are not routed in 5o (their `Ref` arguments
       accept keys for later routing; an `ItemRef` is id-only). Publish and
       every rename that propagates into the cache take the workspace
       operation lock (§19.3) in the daemon and in-process alike; a launch
       rename writes only the working copy and takes none. *(Done: C2 landed
       as C2a–C2d, B6 included.)*
   - ~~**5p — Editor-owned child daemon**~~ — dropped: the editor connects
     through the `--stdio` relay of 5i instead. The editor no longer loading
     the workspace itself in daemon mode is step 6b-α, after 5j–5o moved
     every consumer.
   - **5q — Module interfaces** (§19.20): `M.interfaces` registration, the
     `/modules/<id>` objects mounted and unmounted with the root's
     `objects_changed` (§19.20 "Object set"), a first module interface with its schemas and
     transcripts in the module's repository. Any time after 5g.2.
   - **Retirement of protocol 10** *(done, for the 0.2.0 release)*: the
     transport restarts at 1 with `protocol_min` 1 (PROTOCOL.md §6), and the
     v0 aliases, the transport-10 broadcasts and integer task ids are
     deleted. No stable release ever shipped them, so no deprecation window
     applies.
6. **Default flips** to the binary path for the CLI (the shared daemon;
   degraded when it cannot be started), after the criteria in [`DAEMON.md`](https://github.com/samienne/loomworks.nvim/blob/7b7d1f9f07a3ec55845b65f6ded5972bbbdceba8/DAEMON.md). The
   editor's default flipped in 5s, after which the in-process editor stays
   one beta cycle behind `runtime.mode = "in-process"`, with a deprecation
   note.
   - **6b-α — The editor without a model** ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "End state", "Public
     API", "Editor operations", "Model writes"; §19.13 "Load warnings";
     [API.md](../protocol/API.md) §9.6, §11, §14.4), after 5n–5o and before
     the CLI's default flip: in `daemon` mode the editor loads no workspace,
     scans no toolchains or targets, runs no file tracker, writes none of
     the workspace's files (the cache included) and builds no view
     in-process; its public getters return view rows with ids, its pickers
     and build functions are calls, `lw.compile_command_for_file` and `N`
     are refused, and a `device = true` preparation is refused (§18.11). In
     parts: 0 — spec (this); C — daemon side: `Launch/1.targets`,
     `Profiles/1.set_default_target` and `projects[].targets` in
     `view.Workspace/1`, with schemas and transcripts; F — the load's
     warnings as persistent diagnostics, the notification seam in every
     load path; A1 — editor side: no model in `daemon` mode (the load,
     the observer's attach by root, the views with no in-process fallback,
     the facade by calls, `N` and `device = true`); A2 — editor side: the
     public API and pickers on views and calls (needs C). **QA** of the
     daemon editor runs on 6b-α (A1 and A2 landed), with the deprecated
     `in-process` editor still present.
   - **6b-β** — the in-process editor is removed (its LSP path with it, [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client)
     "LSP configuration", and every "until step 6b-β" transition); with no
     host binary the editor runs degraded. It follows 5s's deprecation beta
     and 6b-α, may land during the QA beta, and does not wait for the CLI's
     default flip (the CLI's in-process mode is a separate decision).
   - **6c** — the binary's Lua moves to its own tree (mechanical); the
     protocol schemas and transcripts become the cross-repository contract,
     in a separate protocol repository pinned by both sides (§19.20).

**Later steps, in this order** (after the steps above; [`DAEMON.md`](https://github.com/samienne/loomworks.nvim/blob/7b7d1f9f07a3ec55845b65f6ded5972bbbdceba8/DAEMON.md) 8a–8c):

- **8a — Workspace data to `.lw/`** (§16.44): lw's workspace data files move from
  `.nvim/` to `.lw/` with a one-time migration recorded by a marker; when
  both exist and disagree, lw refuses rather than choosing. Every deletion
  scope that names `.nvim/` (the workspace-files scope of nuke, housekeeping's
  `<root>/.nvim/tmp`, the launcher cache `.nvim/cache`) is moved and
  re-reviewed for deletion safety; `.lw/` ignores itself, and the launcher
  templates get a new generation.
- **8b — Release v0.2.0**: `staging/daemon` is merged to master and released
  once the daemon steps and 8a are done.
- **8c — Repository split**: this repository keeps only the editor plugin;
  the CLI, the daemon, the bootstrap and protocol code, the protocol
  specification, the release workflow and the launcher scripts move to a new
  repository with their history. Existing pins and launchers download from
  the fixed release origin (§16.22), so releases stay or are mirrored there
  for a transition period; the plugin's own pin points at the new origin.

### 19.20 Interfaces

*Status: step 5g.1 is implemented on `staging/daemon`: the transport
envelope (`call`, `ok`, the structured `error`, `signal`; task frames as
before), the root object with `loomworks.Root/1` (`describe`, `schema`,
`subscribe`, `unsubscribe`, `objects_changed`, `retiring`) and
`welcome.objects` (`daemon/interfaces.lua`), the schema format and the
documents of the transport, `loomworks.Root/1` and `loomworks.Common/1`
(`spec/protocol/`, embedded in the release executable as `loomworks/protocol/`), the
validator and the lint and ratchet tests (`proto/schema.lua`,
`proto/schema_check.lua`). Arguments are always validated; results are
validated in development builds and tests (a violation is an `internal`
error), signals only logged. `forbidden` is returned by `Tasks/1.cancel`;
`not_loaded`, `stopping` and `retiring` are defined but not yet returned,
and `frozen/` is empty until a stable release ships an interface
version. Step 5g.2 part A is implemented: `loomworks.Workspace/1`
(`header`, `changed`), `loomworks.Tasks/1` (`list`, `cancel`, `started`,
`ended`) and `lw.internal.Snapshot/1` (`daemon/core_interfaces.lua`), the
standard-I/O transport (`lw daemon run --stdio`, `daemon/stdio.lua`), the
conformance engine and runner (`proto/conformance.lua`,
`scripts/conformance.lua`) and the golden transcripts
(`spec/protocol/transcripts/`, `meta/transcript.schema.json`). Step 5g.2
part B is implemented: `loomworks.Build/1` (`build`, `clean`, `reset`),
`loomworks.Tests/1.run`, `loomworks.Launch/1.prepare_run` (task-streamed),
`loomworks.Toolchains/1.list`, `loomworks.Profiles/1.compiler_cache`,
`loomworks.Workspace/1.header_changed`, references by `{ id }` or `{ key }`
and the CLI's calls (`daemon/calls.lua`); each of these
interfaces serves only the methods the catalogue's 5g.2 entries name, the rest
being added with their steps. Step 5g.3 is implemented: the CLI policy, the
busy rule, delivery to a connection by subscription only and
the guard's interface ratchet. The editor's interfaces of steps 5j–5o are
implemented, and the additions of step 6b-α are plan. The rest is plan: module
interfaces step 5q; out-of-process providers are reserved and built later
(§19.19).*

**The protocol.** The layers (transport, interfaces, data), interface
naming and reserved namespaces, objects as services, the root object
`loomworks.Root/1`, per-call version choice and `same_build`, the message
envelope (`call`, `ok`, `error`, `signal`, `task`), the transport error codes
and the rule that a mutating method's reply is never turned into an error
are specified in [PROTOCOL.md](../protocol/PROTOCOL.md) §2, §8–§11. The loomworks interface suite
on top of it — the entities and references, the objects, the root's `binary`
and `owner`, the shared types and outcomes, the environment and every
interface version that has a schema — is specified in [API.md](../protocol/API.md). This section adds
what is specific to this implementation and its roadmap. The root's
`retiring` is §19.11's.

**Message envelope** is [PROTOCOL.md](../protocol/PROTOCOL.md) §8.

**The root object** is [PROTOCOL.md](../protocol/PROTOCOL.md) §10 and [API.md](../protocol/API.md) §3.

**Object set.** This daemon mounts every core object when its service
starts, before it loads the workspace (a call that needs the workspace loads it
on demand). The object set is therefore fixed for the session, `welcome.objects` and
`describe` list it whole, and the root's `objects_changed` is never sent
*(until step 5q, which mounts and unmounts `/modules/<id>` as modules load,
and sends it then)*. A client still subscribes to an interface that appears
later on `objects_changed` ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Interface client").

**Errors and domain results** are [PROTOCOL.md](../protocol/PROTOCOL.md) §11 and [API.md](../protocol/API.md) §4.1.

**Signals and subscriptions** are [PROTOCOL.md](../protocol/PROTOCOL.md) §12–§13.

**The CLI's calls.** The CLI sends its operations and reads as interface
calls (`daemon/calls.lua`) and acts on a transport error by its code:
`unknown_object`, `unknown_interface`, `unknown_method`,
`unsupported_version`, `invalid_args`, `same_build_required`, `stopping`,
`retiring` — nothing ran, the command runs in-process (`declined`); `internal` or an
unknown code — for a mutating method, which may have started, the command
fails with exit 1 and is never run a second time in-process; for any other
method it runs in-process.

**References.** References (`{ id }` or `{ key }`) are [API.md](../protocol/API.md) §1.2. The
editor sends ids taken from results and views; the CLI sends the key the
user typed, which the daemon resolves with the in-process matcher (§16.9).
Either is resolved once, in the model segment, to the live object, and the
object is what the handler passes on: an id is never turned into its key to
be looked up again (step 5o part 0).

**Signals, subscriptions and tasks.** Subscriptions, `initial` state,
`seq` and session generation, and the task stream of task-streamed methods
(ownership, back-pressure, observer bounds, disconnect-cancellation; only the
owner may cancel) are [PROTOCOL.md](../protocol/PROTOCOL.md) §12–§14; the task interface `loomworks.Tasks/1`,
the task meta and the task ids are [API.md](../protocol/API.md) §4.2 and §7.

**Interface catalogue.** The first versions of the core interfaces, landed by
the steps of §19.19. Their schemas, not this table, are the full contract;
[API.md](../protocol/API.md) specifies the versions that have a schema, and the other rows are the
roadmap.

| Object | Interface | Methods (signals); T = task-streamed |
|--|--|--|
| `/` | `loomworks.Root/1` (frozen) | describe, schema, subscribe, unsubscribe (objects_changed, retiring) |
| — | `loomworks.Common/1` | shared types only: reference, id, outcome, environment, launch spec, debug spec, task meta |
| `/workspace` | `loomworks.Workspace/1` | header, publish, publish_one, revert_to_baseline, revert_one, set_intent, set_description, trust_accept, delete_user_prefs (changed, header_changed); create deferred |
| `/profiles` | `loomworks.Profiles/1` | list, set_active, create, tool_choices, add_tool, remove_tool, set_device, clear_device, set_default_target *(6b-α)*, query, compiler_cache |
| `/projects` | `loomworks.Projects/1` | candidates, add, declaration, configuration_save, configuration_remove, options_save, launch_save, launch_remove, deploy_save, variable_save, variable_remove, type_config_set, expand_preview, unit_options |
| `/projects` | `loomworks.ConfigSets/1` | candidates, add, update, remove, generate_defaults |
| `/build` | `loomworks.Build/1` | build T, configure T, clean T, reset T |
| `/tests` | `loomworks.Tests/1` | discover T, run T, run_cases T, prepare_debug T, collect, result (results) |
| `/launch` | `loomworks.Launch/1` | prepare_run T, prepare_debug T, build T *(5t, with part B)*, device_log T (log), targets *(6b-α)* |
| `/debug` | `loomworks.DebugConfig/1` | adapters, set_adapter, known_languages |
| `/lsp` | `loomworks.LspConfig/1` | get, set_option (changed) |
| `/tasks` | `loomworks.Tasks/1` | list, cancel (started, ended, step; task frames; `TaskInfo.steps`) |
| `/toolchains` | `loomworks.Toolchains/1` | list, rescan |
| `/toolchains` | `loomworks.Sdks/1` | list, detect, add, remove |
| `/devices` | `loomworks.Devices/1` | list, scan T, install T, launch T, stop (changed) |
| `/health` | `loomworks.Health/1` | run |
| `/maintenance` | `loomworks.Maintenance/1` | orphaned, execute_deletion T, nuke T *(optional)*, locks, unlock |
| `/views` | `loomworks.view.Header/1`, `.ProjectsIndex/1`, `.Workspace/1`, `.Tests/1` (one interface each) | get (update; full state on subscribe) |
| `/internal` | `lw.internal.Snapshot/1` (same_build) | get |
| `/modules/<id>` | `<id>.<Name>/<v>` | defined by the module |

An interface whose surface grows unwieldy is split at its next version without
disturbing the clients of the others.

Replaying a task's earlier output (`Tasks/1` has no `attach`) is
[#50](https://github.com/samienne/loomworks/issues/50).

**`DebugConfig/1`.** *(Step 5k, part B2: implemented, daemon side.)* The
workspace's debug-adapter mapping, on `/debug`, specified in [API.md](../protocol/API.md) §12.
`set_adapter` writes as the in-process `Workspace:set_debug_adapter` writes,
under the model lock, with a `Workspace/1.changed` (§19.12), and stores the adapter
name as given, as in-process.

**`LspConfig/1`.** *(Step 5l part B, done.)* What the workspace's language
servers are configured with (the editor's use: [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "LSP configuration"),
on `/lsp`, specified in [API.md](../protocol/API.md) §13. Project ids in `get` come only from the
daemon, as in the views (§19.13). `set_option` writes as the in-process
`Workspace:set_lsp_option` writes, under the model lock, with a
`Workspace/1.changed` (§19.12); the in-process `Workspace:set_lsp_option` refuses
the calls `set_option` answers with `invalid_args` the same way, writing
nothing.

**`Tests/1`.** *(Step 5m, done: B1 `discover`, B2 the rest; the shared
types `TestNodeRef`, `TestCaseResult` and `TestStatus` in
`loomworks.Common/1`, the view `loomworks.view.Tests/1`, specified in part
0.)* The editor's test discovery, runs and debug preparations, on `/tests`
beside the batch `run`, additively (the interface is a draft, so no new
version), are specified in [API.md](../protocol/API.md) §10; the daemon side is §19.15 "Tests", the
editor's use [loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Tests".

A per-file compile-command query (§8.4 `compile_command_for`) is not part of
`LspConfig/1` ([#51](https://github.com/samienne/loomworks/issues/51)); in
`daemon` mode the editor refuses it ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Public API").

**Module interfaces.** A module's interfaces — its namespace, the mount rule
and rejection per interface version — are [API.md](../protocol/API.md) §17. A Lua module declares its
interfaces in its module table (`interfaces`: per interface name and version,
the path of its schema relative to the plugin, its method handlers and its
signals); they are mounted when the module is loaded (§8.0), and a rejected
interface version is reported by `lw health`. Handlers receive a context
(environment, reply, task start, signal emission, reference resolution),
never the connection.

**Providers (reserved).** A daemon not written in Lua hosts modules out of
process through providers ([PROTOCOL.md](../protocol/PROTOCOL.md) Annex A), which own `/modules/<id>`.

**Schemas and conformance.** The schema documents, their restricted keyword
set, the additive ratchet and the conformance checks are [PROTOCOL.md](../protocol/PROTOCOL.md) §16–§17. Core's
documents live in this repository's protocol schema directory
(`spec/protocol/`), together with the transport document, golden transcripts
and the frozen snapshot of every interface version a stable release shipped;
after the split they move to a separate protocol repository, tagged and
pinned by both the binary and the plugin. A module's documents live in its
own repository. Server conformance drives the transcripts against any binary
over the standard-I/O transport — the Lua daemon and any rewrite alike — and
client conformance replays them against the plugin's client. Besides the
checks of PROTOCOL.md §17.4, a **registry and schema agreement** check
requires every mounted interface version to have a document with the
published digest, every method an implementation and every version older
than the newest an adapter. The daemon validates its results and signals
(PROTOCOL.md §16.4) in development builds and tests: a violation fails the
test, and is a log line in a release build; a mutating method's invalid reply
is also logged (PROTOCOL.md §11.3). The released versions whose snapshots
`frozen/` keeps (PROTOCOL.md §16.5) are those a stable release shipped.

**Transcripts.** The transcript format, the runner's steps, matchers and
checks are [PROTOCOL.md](../protocol/PROTOCOL.md) §18; the fixtures the runner prepares (`fixture`) are
[API.md](../protocol/API.md) §18.

**Versions and deprecation.** Tolerance of unknown values, new interface
versions and the support window are [PROTOCOL.md](../protocol/PROTOCOL.md) §17. The daemon serves a
deprecated version `N` through an adapter over `N+1` — never a second
implementation: the same handlers, with an argument and result adapter. The support
window of PROTOCOL.md §17.3 is **two stable releases and at least 60 days**
after the first stable release that deprecated the version; a transport
version below a raised `protocol_min` is dropped under the same window. A
deprecated version is also announced on the editor's Runtime line.
