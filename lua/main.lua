-- Universal luvi entry point — the host bootstrap.
--
-- It carries no behavioral logic; it (1) resolves where *system Lua* (the
-- loomworks implementation) comes from, (2) handles the host-level commands
-- `version`, `self-update`, `install`, `bootstrap` and `release query` (which
-- must work even with no bundle installed) and, when there is no system Lua
-- at all, their help (boot.help), and (3) runs the CLI from the resolved
-- source.
--
-- System-Lua source precedence:
--   LOOMWORKS_LUA env > `--dev[=PATH]` > settings `default-source=dev`
--     (the development facility: only on that explicit opt-in, spec §16.11)
--   > the embedded code: when the fused bundle holds loomworks/cli.lua (a
--     release executable, a full-fused dev exe, a `luvi lua --` source run)
--     it runs, and nothing else — never an installed bundle (§16.11)
--   > transitional, a bootstrap-only host: the newest verified release bundle
--     (<data>/loomworks/lua-<ver>/).
-- A resolved on-disk root is authoritative — no silent bundle fallback.
--
-- Bootstrap-only modules live under `lua/boot/` (verify, download, update,
-- host_update, json, paths, pin, ...); they load from the fused host regardless
-- of the chosen source, via the boot searcher below. They are NOT part of the
-- release bundle they verify.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local loaders = package.loaders or package.searchers
local bundle = require("luvi").bundle

-- ---- searcher order: ours first, right after preload ------------------------
-- Every loomworks searcher (boot, system Lua, fused-bundle fallback, acquired
-- modules) is inserted directly after the preload searcher, AHEAD of the
-- package.path / package.cpath searchers, in the order added. The path
-- searchers then only ever see names nothing of ours provides.
local next_slot = 2
local function add_searcher(fn)
  table.insert(loaders, next_slot, fn)
  next_slot = next_slot + 1
end

-- ---- boot searcher: always resolve boot.* from the fused/source bundle ------
-- First of ours: LuaJIT's Windows default package.path includes `!\lua\?.lua`
-- (the executable's own directory), so a searcher behind the path searchers
-- would let a `lua/` directory beside lw.exe shadow the fused boot modules —
-- including boot.verify, which carries the release public key.
add_searcher(function(modname)
  if modname ~= "boot" and modname:sub(1, 5) ~= "boot." then return nil end
  local base = modname:gsub("%.", "/")
  for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
    local src = bundle.readfile(cand)
    if src then
      local chunk, err = loadstring(src, "bundle:" .. cand)
      return chunk or ("\n\t" .. tostring(err))
    end
  end
  return "\n\tno bundle file for '" .. modname .. "'"
end)

-- ---- process hygiene (before anything else loads or spawns) -----------------
-- 1. Strip package.path / package.cpath down to absolute entries outside the
--    executable's directory: LuaJIT's defaults begin with `./?.lua` (a file
--    relative to the current directory — i.e. a cloned repository) and, on
--    Windows, `<exe dir>\lua\?.lua`. Our own code never resolves through them
--    (our searchers come first); what remains serves third-party names only,
--    and those must never come from the cwd or from beside the executable.
-- 2. Windows: set NoDefaultCurrentDirectoryInExePath=1 in our environment.
--    libuv (every spawn this process makes) and cmd.exe (every child, which
--    inherits it) then no longer search the current directory for a bare
--    program name. Defense in depth: bare names are also resolved to absolute
--    PATH entries before spawning (boot.exe / loomworks.exe).
do
  local luapath = require("boot.luapath")
  local is_windows = package.config:sub(1, 1) == "\\"
  local exe_dir
  local ok_e, exe = pcall(uv.exepath)
  if ok_e and type(exe) == "string" then exe_dir = exe:match("^(.*)[/\\][^/\\]*$") end
  local sopts = { is_windows = is_windows, exclude_dirs = { exe_dir } }
  package.path = luapath.sanitize(package.path, sopts)
  package.cpath = luapath.sanitize(package.cpath, sopts)
  if is_windows then uv.os_setenv("NoDefaultCurrentDirectoryInExePath", "1") end
end

-- A write to a closed socket or pipe is an EPIPE error, never a SIGPIPE that
-- ends this process (the daemon, a relay, the CLI): boot.signals.
require("boot.signals").catch_sigpipe()

local paths = require("boot.paths")
local pin = require("boot.pin")


--- Exit, flushing stdout first (host-level bootstrap path; the CLI has its own).
local function exit(code)
  io.stdout:flush()
  os.exit(code)
end

--- Env read via libuv's view (sees in-process uv.os_setenv; used for tests).
local function getenv(name) return paths.getenv(name) end

-- ---- args: peel off the bootstrap-level `--dev[=PATH]` / `--no-pin` flags ---
-- Only where they are lw's own: never after `--` or from a program's
-- arguments (`lw launch add … -- --dev`).
local forwarded, host_flags = pin.peel_host_flags({ ... })
local dev_flag, dev_flag_path, no_pin = host_flags.dev, host_flags.dev_path, host_flags.no_pin

-- ---- resolve the system-Lua source -----------------------------------------
local cfg = paths.read_config()
local env_lua = paths.norm(os.getenv("LOOMWORKS_LUA"))
local dev_opt_in = env_lua ~= nil or dev_flag or cfg["default-source"] == "dev"
-- Does this executable embed the loomworks code (spec §16.11)? A release
-- executable and a development fuse do; a bootstrap-only host (transitional,
-- releases before self-contained executables) does not.
local embedded = bundle.readfile("loomworks/cli.lua") ~= nil
-- The release version fused into this executable; nil for a development build.
local release_version = require("boot.verify").RELEASE_VERSION

local luaroot, source_kind
if dev_opt_in then
  luaroot = env_lua or paths.norm(dev_flag_path) or paths.norm(cfg["dev-lua"])
  source_kind = "dev"
  if not luaroot then
    io.stderr:write(pin.dev_unconfigured_message(host_flags.dev_in_args and not env_lua))
    os.exit(1)
  end
  if not uv.fs_stat(luaroot .. "/loomworks") then
    io.stderr:write(
      "lw: development source '" .. luaroot .. "' is not a loomworks `lua/` " ..
      "directory\n    (no `loomworks/` subdir found there).\n")
    os.exit(1)
  end
elseif embedded then
  -- The embedded code is the release: never an installed bundle, never the
  -- install folder.
  luaroot, source_kind = nil, "embedded"
else
  -- Transitional: a bootstrap-only host runs the newest installed bundle.
  luaroot = paths.newest_release_root()
  source_kind = luaroot and "release" or nil
end

-- A Windows host self-update — or `lw install` / `make install`
-- over a running lw (boot.install.copy_binary) — renames the running exe aside
-- to `<exe>.old`; the next invocation removes it. Best-effort and silent — the
-- file may still be in use by another lw process that started before the swap.
-- Never under the development facility (nor beside bare luvi, cleanup_old).
if paths.is_windows and not dev_opt_in then require("boot.host_update").cleanup_old() end

--- The release version of the code this invocation runs: the embedded
--- release's, or (transitional) the installed bundle's `lua-<ver>`; nil for a
--- development build or the development facility.
local function running_code_version()
  if source_kind == "embedded" then return release_version end
  if source_kind == "release" and luaroot then return luaroot:match("lua%-(.+)$") end
  return nil
end

--- What code runs, for every later reader: the host commands below
--- (self-update and gc must know the code is embedded) as well as system Lua
--- (release_notice and the other identity readers). Kind "embedded" | "dev" |
--- "release" (transitional bundle), its release version (nil for a
--- development build or source), and the executable. Published as soon as the
--- source is resolved, and again when the pinned context switches it to a
--- provisioned bundle.
local function publish_code()
  local okx, exe = pcall(uv.exepath)
  _G.__loomworks_code = { kind = source_kind, version = running_code_version(),
    exe = okx and exe or nil }
end
publish_code()

-- ---- pin: sentinel, override, and workspace root ----------------------------
-- The pinned-context marker and the forwarded workspace root are host-internal
-- (spec §16.22): read once here, kept for system Lua (loomworks.host_env) and
-- removed from the environment, as LOOMWORKS_LAUNCHER is below, so nothing
-- this process starts inherits them — an lw run by a build, run or test step
-- resolves its own workspace and pin — and a daemon request's environment
-- never carries them. Starting a daemon or forwarding passes them explicitly.
local pinned_sentinel = getenv("LOOMWORKS_PINNED")
local lw_root_env = getenv("LW_ROOT")
_G.__loomworks_host_env = { pinned = pinned_sentinel, root = lw_root_env }
if pinned_sentinel then pcall(uv.os_unsetenv, "LOOMWORKS_PINNED") end
if lw_root_env then pcall(uv.os_unsetenv, "LW_ROOT") end
local lw_override = getenv("LOOMWORKS_LW") ~= nil
-- The command and its sub-command (`daemon run`), tolerant of a leading
-- global flag (e.g. `lw --no-input self-update`), the same way the redirect
-- classifies it — otherwise a flag-prefixed host command would fall through
-- to the nvim-hosted CLI.
local command, command_sub = pin.command_words(forwarded)
-- The workspace root the pin (and the repo-local cache) live at — the same
-- upward walk the CLI uses to bind a workspace, seeded from LW_ROOT when a
-- launcher passes the user's cwd. A daemon started for a workspace (`lw
-- daemon run --root <dir>`, which runs from the per-user state directory)
-- names its workspace with --root.
-- For a daemon command its --root wins over LW_ROOT: a launcher's LW_ROOT is
-- the user's cwd, which may lie in another (nested / submodule) pinned root.
local pin_start = (command == "daemon") and paths.norm(pin.root_option(forwarded)) or nil
pin_start = pin_start or paths.norm(lw_root_env)
local pin_root = pin.find_pin_root(pin_start or uv.cwd())

-- ---- host commands: version / self-update (work without a bundle) -----------
-- `--version` / `-v` are the conventional spellings; accept them as aliases so
-- they don't fall through to workspace resolution and error about a missing
-- loomworks.json. Only before the command word: after it `-v` is the
-- command's own option (`lw build -v`), while
-- `lw -v build` is still the version.
if pin.asks_version(forwarded) then command = "version" end
--- Is system Lua fused into this host (`embedded`)? A release executable and a
--- dev build (`make install` / `luvi lua --`) fuse it; a bootstrap-only host
--- (transitional) carries only the bootstrap.
local function fused_system_lua() return embedded end

-- `lw <host-command> --help` / `-h` must show help, never perform the operation
-- (a `self-update --help` that replaced the binary was a real bug). Leave such
-- invocations to the CLI's central help dispatcher below — or, with no system
-- Lua to run it, to the host's own help (boot.help, before the "no release"
-- error).
local help_requested = false
for i = 1, pin.own_end(forwarded) - 1 do -- never a program's `--help`
  local v = forwarded[i]
  if v == "--help" or v == "-h" then help_requested = true; break end
end

local host_command = (not help_requested) and command or nil

-- How lw was run: a repo launcher names itself in
-- LOOMWORKS_LAUNCHER (lw.sh / lw.cmd); a pinned context without it is some
-- launcher; otherwise the global lw. Kept for system Lua (health's remedies)
-- in a global, and removed from the environment so a process this one starts
-- (a build, a launched program) does not inherit it.
local invoked_form
do
  local l = getenv("LOOMWORKS_LAUNCHER")
  if l == "lw.sh" or l == "lw.cmd" then invoked_form = l
  elseif pinned_sentinel then invoked_form = "launcher"
  else invoked_form = "global" end
  _G.__loomworks_invoked = invoked_form
  if l then pcall(uv.os_unsetenv, "LOOMWORKS_LAUNCHER") end
end

-- ---- pin management --------------------------------------------------------
-- `lw bootstrap [install|upgrade]` runs as the invoked host, never redirects,
-- and needs no system Lua — so it is handled here, BEFORE pinned-context bundle
-- provisioning: `./lw.sh bootstrap` works offline and can repair a pin whose
-- bundle entry is wrong.
--
-- `lw update` (deprecated in 0.1.37, since removed) is an unknown command that
-- still names its replacements — here, so the pointer needs no bundle and no
-- workspace, and `lw update --help` gets it too.
if command == "update" then
  io.stderr:write(require("boot.bootstrap").removed_update_line(invoked_form) .. "\n")
  exit(2)
end
if host_command == "bootstrap" then
  local bootstrap = require("boot.bootstrap")
  local invoked = invoked_form
  local o, perr = pin.parse_bootstrap_args(forwarded, command, { invoked = invoked })
  local function usage(msg)
    io.stderr:write("lw: " .. msg .. "\n    See `" ..
      require("boot.launcher_check").cmd(invoked, "help bootstrap") .. "`.\n")
    exit(2)
  end
  if not o then usage(perr) end
  -- Where to look: the launcher-passed root, else the current directory.
  local start = paths.norm(lw_root_env) or (uv.cwd():gsub("\\", "/"):gsub("/+$", ""))
  -- The version a NEW pin defaults to: the running release (the bundle this
  -- host resolved, else the host's own release identity); nil for a dev build.
  local host_version = running_code_version() or release_version
  if o.sub == nil then
    local st = bootstrap.status(start, { invoked = invoked, host_version = host_version,
      self_version = require("boot.verify").RELEASE_VERSION, channel = o.channel, check = o.check })
    if o.json then
      io.write(require("boot.json").encode(st.doc) .. "\n")
    else
      for _, line in ipairs(st.lines) do io.write(line .. "\n") end
    end
    exit(st.exit)
  end
  -- The running executable is never pruned from the launcher cache (under
  -- `./lw.sh bootstrap install` it IS a cached binary, still executing).
  local okx, running_exe = pcall(uv.exepath)
  local report, err = bootstrap.install(start, {
    version = o.version, latest = o.latest, channel = o.channel, pin_only = o.pin_only,
    force = o.force, host_version = host_version, invoked = invoked,
    -- The launcher templates are the HOST's (boot.launcher), so the "written
    -- by an older lw" hint compares against the host's own release version
    -- (nil for a development build, whose templates are the newest).
    self_version = require("boot.verify").RELEASE_VERSION,
    running_exe = okx and running_exe or nil,
  })
  if report then for _, line in ipairs(report) do io.write(line .. "\n") end end
  if err then
    io.stderr:write("lw: bootstrap install failed: " .. tostring(err) .. "\n")
    exit(1)
  end
  exit(0)
end

-- ---- release query -----------------------------------------------------------
-- `lw release query` resolves a channel to a verified release for a caller
-- that runs a verified lw (the editor's managed lw). A host command: handled
-- here, BEFORE pinned-bundle provisioning and pin redirection, so it never
-- runs a repo's pinned lw, needs no bundle or workspace and writes nothing.
if host_command == "release" then
  local code, out, err = require("boot.release_query").run(forwarded)
  if err then io.stderr:write(err) end
  if out then io.write(out) end
  exit(code)
end

-- ---- pinned context: embedded code ------------------------------------------
-- Set by the launcher script or the redirect. Embedded code runs only as the
-- release it is (spec §16.22): the pinned version runs here, in-process, with
-- nothing provisioned; any other version — or a development build, which has
-- none — refuses, and never redirects again. The development facility (an
-- explicit opt-in) keeps the transitional behaviour below.
if pinned_sentinel and not dev_opt_in and source_kind == "embedded"
    and pinned_sentinel ~= release_version then
  io.stderr:write("lw: refusing to run in pinned context: this lw is " ..
    (release_version and ("release " .. release_version) or "a dev build") ..
    ", but the pin requires " .. pinned_sentinel .. "\n" ..
    "    Run the repository's launcher (./lw.sh or lw.cmd) or the pinned release's lw.\n")
  exit(1)
end

-- ---- pinned context: provision the pinned bundle (transitional) -------------
-- Set by the launcher script or the redirect below. We are the pinned host;
-- load system Lua from the pinned bundle — provisioned and verified into the
-- machine-local pinned cache (<data>/pinned/<sha256>/lua-<ver>), never read
-- from the repository — rather than the newest global install, and never
-- redirect again (the sentinel is our guard).
if pinned_sentinel and not dev_opt_in and source_kind ~= "embedded" then
  local p = pin_root and pin.read(pin_root)
  if p and p.version == pinned_sentinel then
    local dir, err = require("boot.update").ensure_version(p.version, {
      root = pin_root,
      bundle_sha256 = p.hashes[pin.bundle_asset(p.version)],
      -- A first run through lw.sh / lw.cmd downloads the bundle here; say so
      -- on stderr (stdout can be machine-consumed).
      on_fetch = function()
        io.stderr:write("fetching loomworks " .. p.version .. " (pinned)...\n")
      end,
    })
    if not dir then
      io.stderr:write("lw: could not provision pinned bundle " .. p.version ..
        ": " .. tostring(err) .. "\n")
      exit(1)
    end
    -- Record its last use: `lw cleanup --all` prunes pinned
    -- releases unused for long. The directory's mtime, never a file inside
    -- it (the bundle tree must stay byte-identical to the release).
    pcall(uv.fs_utime, dir, os.time(), os.time())
    luaroot, source_kind = dir, "release"
    publish_code()
  end
end

-- `lw version --json` (the binary descriptor) describes what this
-- binary implements — protocol range, interfaces, schemas — which lives in
-- system Lua, so it runs after the system-Lua searcher is installed (below).
local version_json = false
if host_command == "version" then
  for _, v in ipairs(forwarded) do
    if v == "--json" then version_json = true end
  end
end

if host_command == "version" and not version_json then
  local upd = require("boot.update")
  -- Same dev-build predicate self-update uses, so the label never
  -- calls a host a dev build that self-update would replace, or vice versa.
  local hu = require("boot.host_update")
  local fused = fused_system_lua()
  local dev_build = hu.dev_build({ exe = hu.exe_path(), fused_system_lua = fused,
    release_version = release_version }) ~= nil
  -- `fused_system_lua` decides "bundled (fused)" vs "none installed": a release
  -- host with no bundle must not claim one (every other command would say none).
  local info = upd.version_info(luaroot, source_kind, { dev_build = dev_build, fused_system_lua = fused })
  -- The update channel is a self-update preference; show it so `lw version` is
  -- the one place a user confirms whether they follow stable or unstable.
  local channel = upd.resolve_channel({}) or upd.DEFAULT_CHANNEL
  -- In pinned context (a launcher / the redirect set the sentinel) the pin, not
  -- the channel setting, decides what runs: name it instead of the channel.
  local pinned = (pinned_sentinel and pin_root)
    and { file = pin_root .. "/lw.pin", version = pinned_sentinel } or nil
  io.write(upd.version_line(info, channel, pinned) .. "\n")
  exit(0)
elseif host_command == "self-update" then
  -- Self-update replaces only the executable (spec §16.32): the release
  -- executable carries all its code, so there is no bundle step.
  if source_kind == "dev" then
    io.stderr:write("lw: self-update does not apply to a development source " ..
      "(--dev / default-source=dev).\n")
    exit(1)
  end
  local force, channel, version, no_host = false, nil, nil, false
  local pending  -- the valued flag whose value is the next token
  for _, v in ipairs(forwarded) do
    if pending == "channel" then channel, pending = v, nil
    elseif pending == "version" then version, pending = v, nil
    elseif v == "--force" then force = true
    elseif v == "--no-host" then no_host = true
    elseif v == "--channel" then channel, pending = "", "channel"
    elseif v == "--version" then version, pending = "", "version"
    elseif type(v) == "string" and v:sub(1, 10) == "--channel=" then channel = v:sub(11)
    elseif type(v) == "string" and v:sub(1, 10) == "--version=" then version = v:sub(11) end
  end
  if no_host then
    io.stderr:write("lw: --no-host is no longer accepted: self-update replaces only the " ..
      "lw executable (there is no separate bundle to update)\n")
    exit(2)
  end
  if channel == "" then
    io.stderr:write("lw: --channel needs a value: stable or unstable\n")
    exit(2)
  end
  if version == "" then
    io.stderr:write("lw: --version needs a value: a release version such as 0.2.0\n")
    exit(2)
  end
  if version and not pin.valid_version(version) then
    io.stderr:write("lw: --version '" .. version .. "' is not a release version\n")
    exit(2)
  end
  local upd = require("boot.update")
  -- `--channel <c>` is persisted: it becomes the update channel
  -- for later runs too, exactly like `lw settings set channel <c>`.
  if channel then
    local saved, serr = upd.persist_channel(channel)
    if not saved then
      io.stderr:write("lw: " .. tostring(serr) .. "\n")
      exit(2)
    end
    io.write(saved.changed
      and ("lw: update channel set to " .. channel .. " (saved in your lw settings; later runs follow it)\n")
      or ("lw: update channel is already " .. channel .. "\n"))
    local env_channel = getenv("LOOMWORKS_CHANNEL")
    if env_channel and env_channel ~= "" and env_channel ~= channel then
      io.write("lw: note: LOOMWORKS_CHANNEL=" .. env_channel .. " overrides the saved channel " ..
        "in any run where it is set\n")
    end
  end
  io.write("lw: checking for updates...\n")
  -- The target: the exact `--version`, else the channel's newest release.
  local target = version
  if not target then
    local t, terr = upd.resolve_target({ channel = channel })
    if not t then
      io.stderr:write("lw: self-update failed: " .. tostring(terr) .. "\n")
      -- A 404 here usually means this build points at a release feed that has
      -- no releases yet, so say where it looked and how to redirect it rather
      -- than leaving a bare curl error.
      if tostring(terr):find("404", 1, true) then
        io.stderr:write("    Releases are fetched from: " .. upd.DEFAULT_RELEASE_URL .. "\n" ..
          "    Point it elsewhere with `lw settings set release-url <url>` or\n" ..
          "    LOOMWORKS_RELEASE_URL (a local directory works as an offline mirror).\n")
      end
      exit(1)
    end
    if t.channel_overridden then
      io.stderr:write("lw: --channel " .. t.channel_overridden ..
        " is ignored - a release-url override is in effect (LOOMWORKS_RELEASE_URL / " ..
        "the `release-url` setting). The channel governs only the default origin; " ..
        "unset the override to use channels.\n")
    end
    target = t.version
    io.write("lw: latest release: " .. target .. "\n")
  end
  -- Verified against the target's signed SHA256SUMS before any swap; refuses
  -- for pinned / dev / source-run hosts (a note, not a failure).
  local h = require("boot.host_update").update_host({
    target_version = target,
    force = force,
    pinned = pinned_sentinel ~= nil,
    dev = source_kind == "dev",
    fused_system_lua = fused_system_lua(),
    info = function(line) io.write("lw: " .. line .. "\n") end,
  })
  if h.status == "replaced" then
    io.write("lw: updated lw " .. (h.from or "(unknown version)") .. " -> " ..
      h.to .. " (" .. h.exe .. ")\n")
    if h.hint then io.write("lw: note: " .. h.hint .. "\n") end
    exit(0)
  elseif h.status == "current" then
    io.write("lw: already up to date (" .. target .. ")\n")
    exit(0)
  elseif h.status == "skipped" then
    io.write("lw: not replaced: " .. h.message .. "\n")
    exit(0)
  end
  io.stderr:write("lw: self-update failed: " .. tostring(h.message) .. "\n")
  if h.manual then io.stderr:write("    To update it manually, " .. h.manual .. ".\n") end
  io.stderr:write("    The installed lw was not changed.\n")
  exit(1)
elseif host_command == "install" then
  local opts = { dry_run = false, no_modify_path = false }
  for _, v in ipairs(forwarded) do
    if v == "-y" or v == "--yes" then opts.assume_yes = true
    elseif v == "--no-modify-path" then opts.no_modify_path = true
    elseif v == "--no-bundle" then  -- accepted and ignored: install places only the executable
    elseif v == "--dry-run" then opts.dry_run = true
    elseif v == "--no-input" or v == "--non-interactive" then opts.no_input = true end
  end
  -- Same non-interactive switches as the CLI: never prompt (replacing an
  -- existing binary or editing PATH then needs -y) under LW_NO_INPUT / CI.
  local function env_truthy(name)
    local e = getenv(name)
    return e ~= nil and e ~= "" and e ~= "0" and e:lower() ~= "false"
  end
  if env_truthy("LW_NO_INPUT") or env_truthy("CI") then opts.no_input = true end
  -- install may report progress AND fail (e.g. the PATH edit after the binary
  -- was placed): print whatever it got done, then honour the error.
  local report, err = require("boot.install").install(opts)
  if report then
    for _, line in ipairs(report) do io.write(line .. "\n") end
  end
  if err then
    io.stderr:write("lw: install failed: " .. tostring(err) .. "\n")
    exit(1)
  end
  exit(0)
end

-- ---- pin: redirect a workspace operation to the pinned release --------------
-- A global host in a pinned repo runs the pinned release. Fast path: the pin
-- matches self, run in-process (no download). Otherwise acquire and verify the
-- pinned release executable into the executable cache, set the sentinel, and
-- re-exec it — that host runs as the pinned release and never redirects again.
do
  local self_version = running_code_version()
  local p = pin_root and pin.read(pin_root)
  local stdio = false
  for i = 1, pin.own_end(forwarded) - 1 do if forwarded[i] == "--stdio" then stdio = true end end
  local decision = {
    command = command,
    sub = command_sub,
    stdio = stdio,
    pin = p,
    self_version = self_version,
    pinned_sentinel = pinned_sentinel,
    no_pin = no_pin,
    lw_override = lw_override,
    dev = dev_opt_in,
  }
  local action, _, since = pin.decide(decision)
  -- A command this host runs itself in a repository that pins another lw
  -- leaves the workspace daemon to the pinned lw: the CLI's
  -- ensure step neither starts nor replaces one (loomworks.daemon.ensure).
  if action ~= "redirect" then _G.__loomworks_foreign_pin = pin.foreign_pin(decision) end
  -- The pinned lw predates the command: never redirect to a host that would
  -- only say "unknown command".
  -- A daemon this host would start instead is the pinned lw's to start: refuse
  -- (the editor then runs without a daemon). Anything else runs here,
  -- leaving the workspace daemon alone (foreign_pin above).
  if action == "unsupported" then
    local what = "lw " .. command .. (command_sub and pin.REDIRECT_SUBCOMMANDS[command]
      and (" " .. command_sub .. ((stdio and command_sub == "run") and " --stdio" or "")) or "")
    if command == "daemon" then
      io.stderr:write("lw: this repo pins lw " .. p.version .. ", which predates `" .. what ..
        "` (added in " .. since .. "); the workspace daemon is left to the pinned lw - not started\n")
      exit(1)
    end
    io.stderr:write("lw: this repo pins lw " .. p.version .. ", which predates `" .. what ..
      "` (added in " .. since .. "); running it as this lw, without the workspace daemon\n")
  end
  if action == "redirect" then
    local asset, aerr = pin.detect_asset()
    if not asset then
      io.stderr:write("lw: cannot honor lw.pin: " .. tostring(aerr) .. "\n")
      exit(1)
    end
    -- A pinned release that reads its bundle from the repository-local
    -- `.nvim/cache/lua-<ver>/` would load code from the repository: refuse it
    -- up front (spec §16.22), before any fetch, naming the version and the
    -- command that moves the pin. Nothing is deleted.
    if pin.reads_repo_bundle(p.version) then
      io.stderr:write("lw: refusing to run pinned lw " .. p.version .. ": releases before " ..
        pin.REPO_BUNDLE_BEFORE .. " load code from the repository; to move lw.pin to a supported release " ..
        require("boot.launcher_check").run(invoked_form, "bootstrap upgrade") .. "\n")
      exit(1)
    end
    local exe_cache = require("boot.exe_cache")
    -- The pinned release executable, from the machine-local executable cache
    -- <data>/exe/<sha256>/ (never the repository: a clone could ship a binary
    -- there with a pin naming its hash), verified against the pin. Only the
    -- executable: a release before self-contained executables provisions its
    -- own bundle. "fetching" (stderr: stdout can be machine-consumed) only
    -- when a download really happens.
    local sha = type(p.hashes[asset]) == "string" and p.hashes[asset]:lower() or nil
    local bin, err = exe_cache.ensure(p.version, asset, sha, {
      on_fetch = function()
        io.stderr:write("fetching loomworks " .. p.version .. " (pinned)...\n")
      end,
    })
    if not bin then
      io.stderr:write("lw: could not fetch pinned lw " .. p.version .. ": " ..
        tostring(err) .. "\n")
      exit(1)
    end
    -- Record its last use (`lw cleanup --all` prunes executables unused for long).
    exe_cache.touch(sha)
    -- Pass the sentinel + workspace root to the pinned lw explicitly (they
    -- were removed from our environment at startup, spec §16.22): set just
    -- before the exec, which is the only process this one starts from here
    -- on (uv.os_setenv is visible to spawned children).
    io.stderr:write("loomworks " .. p.version .. " (pinned)\n")
    uv.os_setenv("LOOMWORKS_PINNED", p.version)
    -- (A daemon's root is its --root: it runs from the per-user state dir.)
    uv.os_setenv("LW_ROOT", pin_start or uv.cwd())
    -- A pinned lw that predates the color options would reject them.
    local code = require("boot.exe").run_in_place(bin, pin.redirect_args(forwarded, p.version))
    if not code then
      io.stderr:write("lw: cannot exec pinned lw at " .. bin .. "\n")
      exit(1)
    end
    exit(code)
  end
end

-- ---- install the loomworks searcher + run -----------------------------------
if luaroot then
  -- On-disk root (dev or release) is authoritative; no bundle fallback, so a
  -- partial tree fails loudly instead of silently mixing in bundled code.
  _G.__loomworks_luaroot = luaroot
  add_searcher(function(modname)
    local base = luaroot .. "/" .. modname:gsub("%.", "/")
    for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
      local fh = io.open(cand, "r")
      if fh then
        local s = fh:read("*a"); fh:close()
        local chunk, err = loadstring(s, "@" .. cand)
        return chunk or ("\n\t" .. tostring(err))
      end
    end
    return "\n\tno " .. source_kind .. " file for '" .. modname .. "'"
  end)
else
  -- No on-disk root. Fall back to a full-fused bundle (dev exe / source run);
  -- if there is no fused loomworks either, this is a bootstrap-only host with
  -- nothing installed yet — guide the user to fetch a release. Help still
  -- works: a user must be able to learn what `install` / `self-update` do
  -- before either has run (host usage + per-host-command help, exit 0).
  if not embedded then
    -- In a pinned repository the full-help note names the launcher (which
    -- runs the pinned release and provisions its bundle), not self-update.
    local help_text = require("boot.help").for_args(forwarded, { pinned = pin_root ~= nil })
    if help_text then
      io.write(help_text .. "\n")
      exit(0)
    end
    io.stderr:write(
      "lw: no loomworks release is installed.\n" ..
      "    Run `lw self-update` to download and verify the current release.\n")
    exit(1)
  end
  add_searcher(function(modname)
    local base = modname:gsub("%.", "/")
    for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
      local src = bundle.readfile(cand)
      if src then
        local chunk, err = loadstring(src, "bundle:" .. cand)
        return chunk or ("\n\t" .. tostring(err))
      end
    end
    return "\n\tno bundle file for '" .. modname .. "'"
  end)
end

-- ---- acquired modules: resolve alongside system Lua ------------------------
-- Modules installed by `lw module install` live under <data>/loomworks/modules/
-- <name>/lua, separate from the release source so a self-update never disturbs
-- them. Expose their roots to both resolvers — the require searcher below and
-- the vim shim's `nvim_get_runtime_file` glob (module/SDK discovery) — via a
-- global, so the two stay in lockstep. Added after the system-Lua searcher so
-- core always wins a name (module packages only ever add new namespaces:
-- loomworks.modules.<id>, loomworks.sdks.<id>, loomworks.progress.<id>), yet
-- still ahead of the path searchers.
_G.__loomworks_module_roots = paths.module_lua_roots()
if #_G.__loomworks_module_roots > 0 then
  add_searcher(function(modname)
    local rel = modname:gsub("%.", "/")
    for _, root in ipairs(_G.__loomworks_module_roots) do
      for _, cand in ipairs({ root .. "/" .. rel .. ".lua", root .. "/" .. rel .. "/init.lua" }) do
        local fh = io.open(cand, "r")
        if fh then
          local s = fh:read("*a"); fh:close()
          local chunk, err = loadstring(s, "@" .. cand)
          return chunk or ("\n\t" .. tostring(err))
        end
      end
    end
    return "\n\tno acquired-module file for '" .. modname .. "'"
  end)
end

if not _G.vim then
  _G.vim = require("loomworks.shim")
end

-- `lw version --json`: the binary descriptor, from the system
-- Lua this invocation resolved — never a workspace, never a daemon.
if version_json then
  local ok, doc = pcall(function()
    return require("loomworks.daemon.descriptor").describe()
  end)
  if not ok then
    io.stderr:write("lw: cannot describe this binary: " .. tostring(doc) .. "\n")
    exit(1)
  end
  io.write(require("loomworks.daemon.descriptor").encode(doc) .. "\n")
  exit(0)
end

_G.arg = forwarded
require("loomworks.cli")
