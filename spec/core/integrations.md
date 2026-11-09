> Part of the loomworks core specification -- see [`README.md`](README.md) for the index and the section-range table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 9. LSP Integration

The editor-side LSP integration now lives in [loomworks.nvim `spec/plugin.md`](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#9-lsp-integration).

---

## 10. SDK Provider Contract

An SDK is a resolved platform installation (e.g., an Android NDK, an
embedded vendor toolchain, a cross-compiler distribution) that supplies
tools to one or more modules. SDK providers
are pluggable: each provider lives at `lua/loomworks/sdks/<id>.lua`
and registers itself by being required from `lua/loomworks/sdks/init.lua`
or another runtime path file.

### 10.1 Provider interface

Each provider table exposes:

| Field | Purpose |
|-------|---------|
| `id` | Provider identity (e.g., `"android-ndk"`) — stable across versions |
| `display_name` | Human-readable name shown in pickers and status |
| `detect_all() → { path, version }[]` | Enumerate installations on the host. Pure detection — no validation, no domain object creation |
| `validate(path) → boolean` | Return whether a given path looks like a valid installation of this SDK type |
| `create_sdk(key, path, version) → SDK` | Construct a `loomworks.SDK` domain object from a validated installation |
| `query_capabilities(sdk, module_id) → table\|nil` | Return opaque capability data this SDK can offer to a given module, or `nil` if it has nothing for that module. `module_id == nil` returns the supported module ids array |
| `device_runner(sdk) → Runner\|nil` | *(optional)* The device runner that executes this installation's foreign-platform build output on attached devices (§18.2) |
| `health_inventory(ctx) → Declaration[]` | *(optional)* Extra environment-inventory declarations (§16.33). Without it, core lists the provider's `detect_all()` installations plus every installation a profile pins (each validated once), under category *SDKs*; a pinned installation that no longer validates is a missing **required** item for that profile. A provider with nothing detected and nothing pinned contributes no line. A plain `lw health` probes a provider only when some profile pins one of its installations, and lists only the pinned ones; the detected-but-unpinned installations are for `lw health --all` (§16.36) |

**Declaring an installation.** An SDK is normally declared by supplying a path,
which the provider validates — identifying the installation and deriving the
facts (such as version) that the key is built from. A provider MAY derive a key
that encodes more than the version (for instance a path-derived token, so two
installations of the same version at different paths stay distinct); a
provider-derived key is the installation's identity and MUST be preserved
verbatim across save/load.

A user MAY **force** a declaration whose path fails identification — an
installation that cannot report on itself — by supplying the identifying facts
explicitly. The path MUST still exist, so a mistyped path is still refused. A
forced declaration carries only the facts the user gave: where a version was not
supplied it is unknown, and the installation therefore forfeits version-based
selection (§16.3) and is referenced by its full key.

A user MAY also declare an installation **without a path**: the candidates are
the provider's `detect_all()` installations not already declared. None is an
error that names the with-path form; exactly one is declared (and reported as
detected); several require a choice — offered interactively, or, where no
prompt is possible, an error listing each candidate as the explicit with-path
declaration. The chosen path is then declared exactly as a supplied one
(validated, key derived). Listing the detected installations is read-only and
needs no workspace.

### 10.2 SDK domain object

`loomworks.SDK` (`lua/loomworks/sdk.lua`) wraps a resolved
installation. Fields:

| Field | Purpose |
|-------|---------|
| `key` | Identity key, persisted in user.json |
| `_type` | Provider id |
| `_version` | Detected version (or nil) |
| `_path` | Resolved installation path |
| `_resolved` | Whether the path is currently valid |
| `_intent` | `"shared"` / `"local"` for the publish/working-copy model |
| `_provider` | Back-reference to the provider table |

`SDK:query(module_id)` delegates to the provider's
`query_capabilities`. Returns `nil` when the SDK is unresolved or has
nothing for that module.

### 10.3 Capability shape

Capability data is **opaque to core** — only the requesting module
interprets it. A typical shape includes paths to platform tools
(compilers, packagers, simulator binaries), toolchain files,
architecture lists, and any flags that must be threaded into the
module's task generation. Each provider documents its shape per
module in its own spec file.

### 10.4 Profile-level pinning

A profile may pin an SDK by `key` in user.json. On reload, the SDK
is resolved by `key` against the workspace's known providers. If the
provider can no longer find the installation (e.g., the SDK was moved
or uninstalled), the profile renders as incomplete with a rebase
action. No fallback guessing — incomplete profiles surface
explicitly.

When a profile has an SDK and a module asks for a tool, the resolver
consults the SDK first via `SDK:query(module_id)`. If the SDK
returns nil, the module falls through to host-tool detection. If
neither yields a tool and the profile has no explicit override, the
profile is incomplete.

**Incomplete profiles refuse build operations.** Configure, build,
launch, and debug all gate on a buildability check at every entry
point: an incomplete profile can be created, edited, persisted to
loomworks.json, and shared with collaborators, but cannot be
executed against. The error is module-agnostic and points the user
at the status page to assign a tool/SDK. Without this gate the
build chain runs with nil tool data, the build directory resolves
from a config name that may have fallen back to a phantom
Configuration, and on-disk artefacts come out malformed.

### 10.5 SDK provider implementations

Each SDK provider documents its detection logic, validation rules,
and per-module capability shape in its own spec file:

- [`spec/sdks/cpp_compiler.md`](../sdks/cpp_compiler.md) —
  User-declared C/C++ compiler (cross-compiler / custom build).

Third-party providers follow the same shape: implement the contract
above and document the per-module capability shape alongside.

Optional provider hooks beyond the base contract:

- `path_prompt: string` — overrides the generic `<display_name>
  SDK path` text in the Add-SDK dialog. Useful when the
  installation is not a directory (e.g. a compiler binary).
- `derive_key(info, path) → string` — overrides the default
  `<type>-<version>` key shape. Useful when one user can have
  multiple distinct installations of the same type and version
  (e.g. two custom compiler builds at different paths).
- `display_name_for(sdk) → string` — overrides
  `SDK:display_name()` per instance so labels can depend on
  query-time information (e.g. detected compiler family).

### 10.6 Future direction

Profile-level toolchain selection is now language-keyed: profiles
carry a flat array of tool keys (`profile.tools`), each tool declares
its language coverage (`Tool.languages`), and each Configuration
declares the languages it needs (`Configuration.languages`, defaulting
to `module.languages`). SDK-supplied tools land in their module's
`_tools` registry via `Workspace:_enrich_tools_from_sdks` on every
remerge, identified by the same key shape host tools use so
cross-module identity is preserved. SDK refresh remains cheap because
the registry is rebuilt from cache + detection on each load —
profiles store only keys, not tool_data, except in the legacy
shape which migrates transparently on first save.

Post-configure language detection (cmake file-api, meson introspect)
is a future refinement — a soft diagnostic that suggests adding a
language to a configuration when the actual configure enabled more
than was declared. Not authoritative; user remains the source of
truth for `Configuration.languages`.

### 10.7 Kit target platform

A provider whose kits build for a platform other than the host declares, in
its capability data for each such kit, an opaque **target-platform token**
(e.g. an OS/architecture pair). The module that turns capabilities into kits
(`kits_from_sdk`) returns the token beside each kit's tool data:

```
kits_from_sdk(caps, sdk) → { tool_data, target_platform? }[]
```

Core stores it as the Tool's execution platform (§1.5, §18.1) and records the
producing SDK on the Tool, so a foreign artifact is routed to that SDK's device
runner (§18.2). A kit without a token is host-runnable. The token is data about
the kit, not a program-bearing field: it names no program and is produced by
detection on this machine (§17.7).

The token vocabulary is free-form and owned by the provider: core compares a
kit's token only for equality with the `platforms` of the runner of the SDK
that produced the kit. No shared vocabulary exists; one is introduced only if
two providers ever have to agree on a platform.

---

## 11. Device Interface Contract

Devices are physical or emulated deployment targets (phones,
simulators, embedded boards). Any module may opt in to device
support for application packages (this section); SDK providers expose
devices through device runners for plain executables (§18). Core
discovers device-capable modules and routes all device operations
through them — no per-module knowledge in core.

### 11.1 Device domain object

`loomworks.Device` (`lua/loomworks/device.lua`) is identified by
its `serial` string. Runtime-only — not persisted in cache or
user.json. Workspace owns `_devices` (serial → Device), populated on
demand via `Workspace:scan_devices()`.

Fields:

| Field | Type | Description |
|-------|------|-------------|
| `serial` | string | Stable device identifier |
| `display_name` | string | Human-readable label |
| `state` | string | `"online"` / `"offline"` |
| `provider` | string | Module id or device-runner id (§18.2) that reported the device |
| `properties` | table | Provider-specific extras |

### 11.2 Module opt-in

**Static property:**

| Property | Type | Description |
|----------|------|-------------|
| `has_devices` | `boolean` | `true` if this module's launch targets may require device deployment. Default `false`. |

**Methods** (all optional, only meaningful when `has_devices = true`):

**`list_devices(tool_data, callback)`** *(async)*

Enumerate connected devices. Calls `callback(devices)` where each
device is `{ serial, display_name, state, properties }`. The module
runs the device connector tool and parses its output.

**`device_targets(project_ctx, active_config) → table[]`**

Return device launch target descriptors for the active configuration.
Each descriptor has `{ id, label, requires_device }`. These appear in
the launch target picker alongside module targets and command-type
launches.

**`device_install(tool_data, device_serial, artifact_path) → { cmd, args, env?, check_output? }`**

Return an overseer-compatible command spec for installing an
artifact onto a device. Does NOT execute the command — core runs it
via overseer. Always reinstalls (no freshness tracking).

`check_output(lines: string[]) → string|nil` is an optional failure
detector. Some device connectors exit with status 0 even when an
install is rejected by the device-side package manager; without
parsing the output, the build → deploy → install → launch chain
falls through silently and the device launches the previously
installed version of the app. Returning a non-nil string fails the
install task and breaks the chain. Modules that wrap exit-code-honest
connectors may omit this field.

**`device_launch(tool_data, device_serial, launch_info) → { cmd, args, env?, check_output? }`**

Return a command spec to launch the installed app on a device.
`launch_info` is module-specific metadata produced by
`resolve_launch_info()`. `check_output` follows the same contract
as `device_install` — used to surface launch failures that the
connector reports in stdout while exiting 0.

**`device_stop(tool_data, device_serial, bundle_name) → { cmd, args, env?, check_output? }`**

Return a command spec that force-stops the app on the device.
Session tracker calls this from `stop()` when the active run is a
device launch so stop paths actually terminate the on-device process
rather than merely closing the local log stream. `check_output`
follows the same contract as `device_install`.

**`device_pid(tool_data, device_serial, bundle_name) → { cmd, args, env? }`**

Return a command spec that, when run, prints the PID of a running
app on the device. Used by the session tracker for two purposes:
(1) initial PID discovery right after launch, and (2) periodic
polling to detect when the app has exited so the log stream can be
torn down automatically.

**`device_log(tool_data, device_serial, opts?) → { cmd, args, env? }`**

Return a command spec that streams device logs on stdout. `opts` is
an optional hint table (e.g., `opts.pid` for device-side filtering),
but the core `device_log` view does not rely on device-side filters
— it parses and filters the stream client-side. Modules may expose
whichever opts make sense.

**`device_log_clear(tool_data, device_serial) → { cmd, args, env? }`**

Optional. Return a command spec that flushes the device's log buffer.
Called by the session tracker right before starting a fresh stream so
the view doesn't mix in stale entries. Best-effort — errors here are
non-fatal.

**`resolve_artifact(project_ctx, active_config) → string|nil`**

Return the absolute path to the built artifact for device deployment.
Module-specific knowledge of where the build system places output.

**`resolve_launch_info(project_path, config_info, tool_data) → table|nil`**

Extract launch metadata from project files. Returns a table that is
passed to `device_launch()` as `launch_info`. Shape is
module-specific.

### 11.3 Launch flow with devices

The launch flow (§8.7) is extended when the target requires a device:

```
build → file-deploy → device-install → device-launch
```

1. **Build**: same as §8.7 — build dependencies, then build self.
2. **File-deploy**: same as §8.8 — copy artifacts between projects.
3. **Device check**: if `target:requires_device()` is false, proceed
   to normal launch/debug (existing path, unchanged). Otherwise:
4. **Device selection**: if the profile has no device serial, prompt
   with `vim.ui.select` populated from `list_devices()`. On
   selection, persist to profile.
5. **Device install**: call `resolve_artifact()` to find the artifact
   path, then `device_install()` to get the command spec. Execute via
   overseer as a tracked task. On failure, stop the chain with error.
6. **Device launch**: call `resolve_launch_info()` then
   `device_launch()`. Execute via overseer.
7. **Log stream** (best-effort):
   a. Resolve the launched app's PID via `device_pid()` (polled
      briefly — launch returns before the process is up).
   b. Clear the device log buffer via `device_log_clear()` (when the
      module provides it) so stale entries don't show up in the
      view.
   c. Start `device_log()` as a streaming task and hand its lines to
      the `loomworks.device_log` module, which parses each line,
      applies a session prefilter (PID OR proc-contains-bundle,
      union semantics), writes matches to a ring buffer, and renders
      filtered entries into a bottom-split scratch buffer.
   d. Start a periodic pidof poll (~3 s) on the session tracker.
      When the PID is gone for two consecutive polls the session
      tracker treats the app as exited, stops the log stream, and
      clears the active run.

   Failure at any step surfaces as a warning and does not fail the
   launch chain — the app is already running, we just can't follow
   its output this time.

Device targets always use launch mode in v1 (no device debug).

### 11.4 LaunchTarget device support

LaunchTarget supports three target types:

| Descriptor field | Target type | Source |
|-----------------|-------------|--------|
| `target` | Module target (executable) | Module's `parse_targets` discovery |
| `launch` | Command launch | loomworks.json launch section |
| `device_target` | Device target | Module's `device_targets()` |

The `device_target` field stores the target ID.
`LaunchTarget:requires_device()` returns `true` when `_device_target`
is set.

The target picker collects from all three sources:
1. Launch configurations of the projects (§1.2.1)
2. Executable targets from `ConfigUnit.targets`
3. Device targets from modules (`module.device_targets()`)

### 11.5 Device interface implementations

Devices are typically implemented inside the module that knows the
relevant connector tool. No v1 core module ships a device interface;
device-capable modules (e.g. mobile/embedded targets) live in
separate plugins and document their connector usage in their own
specs. A device-capable module MAY take its device listing and transport
from its SDK's device runner instead of running the connector itself
(§18.10).

---

## 12. Overseer Integration

### 12.1 Task generation

Modules provide task definitions via their `tasks()` function. Each task
definition includes:
- `builder()` — returns an overseer task specification
- `name` — display name
- `loomworks` — metadata: project_key, action, configuration_key, build_dir,
  tool_data, cmake info

### 12.2 Task tracking component

`loomworks.task_tracker` is an overseer component injected into every
loomworks-spawned task. It:

1. Registers the task on the appropriate ConfigUnit
2. Parses output for progress (module-specific parser)
3. On completion: records the task result to cache, unregisters from
   ConfigUnit

### 12.3 Task lifecycle

```
collect tasks → check readiness → launch/skip/defer → track → complete → record result
```

All tasks wait for pending deletions before starting.

### 12.4 Daemon tasks

*(Step 5k, plan.)* In `daemon` runtime mode the editor's builds, configures,
module cleans and launch preparations run in the workspace daemon
([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Editor operations"). Each daemon task is **one** overseer
task — not one per module task as above: an editor-owned one is started by
the call, stopped by `Tasks/1.cancel` and restarted by a new call, its
output the task's frames in a terminal buffer (overseer's output actions,
including the quickfix list, work on it); one another client started is
listed read-only with an origin marker ([loomworks.nvim `spec/plugin.md` §19.16](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#1916-the-editor-as-a-client) "Tasks in the task
runner"). Progress, cache write-back and unit state come from the daemon
(the task stream and `Workspace/1.changed`), not from `task_tracker`.
*(Step 5t: implemented, part C.)* The build of a non-device launch target is one such task
(`Launch/1.build`), not one per dependency; its progress follows the task's
current step ([API.md](../protocol/API.md) §4.3).

---

## 13. Auto-load

Auto-load in the editor now lives in [loomworks.nvim `spec/plugin.md`](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#13-auto-load).

---

## 14. Neovim Commands

The Neovim command set now lives in [loomworks.nvim `spec/plugin.md`](https://github.com/samienne/loomworks.nvim/blob/master/spec/plugin.md#14-neovim-commands).
