-- Repo-local launcher / version-pin helpers for the host bootstrap.
--
-- Pure logic shared by the launcher (main.lua) and pin management
-- (boot.bootstrap): parse/serialize `lw.pin`, select the host-binary asset for
-- the running platform, locate the pin root, and decide whether a global host
-- should redirect to a pinned release. Depends only on luv; never on the vim
-- shim or the bundle it may end up provisioning.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

-- The real published host-binary assets, keyed by "<os>/<arch>". These are the
-- exact names the release workflow uploads (see .github/workflows/release.yml);
-- a platform absent here has no pinnable binary and MUST error rather than
-- fetch a different platform's asset.
M.HOST_ASSETS = {
  ["linux/x86_64"]   = "lw-linux-x86_64",
  ["linux/arm64"]    = "lw-linux-arm64",
  ["macos/arm64"]    = "lw-macos-arm64",
  ["macos/x86_64"]   = "lw-macos-x86_64",
  ["windows/x86_64"] = "lw-windows-x86_64.exe",
}

-- The release that first published each host asset (spec §16.11 "Supported
-- platforms"): a version string, or EVERY_RELEASE for an asset every release
-- carries. Every HOST_ASSETS entry has one (one without counts as published
-- by every release: fail closed, its hash stays required). Whatever reads a release's assets
-- (pin authoring and checking, the pinned fetch, self-update) considers only
-- the assets that release publishes (host_assets_for); "since" otherwise only
-- selects the message for a platform the release predates (missing_build).
-- It never relaxes a hash check: nothing runs without its own asset's hash.
M.EVERY_RELEASE = true
M.HOST_ASSET_SINCE = {
  ["lw-linux-x86_64"]       = M.EVERY_RELEASE,
  ["lw-macos-arm64"]        = M.EVERY_RELEASE,
  ["lw-windows-x86_64.exe"] = M.EVERY_RELEASE,
  ["lw-linux-arm64"]        = "0.2.0-beta.5",
  ["lw-macos-x86_64"]       = "0.2.0-beta.5",
}

-- Workspace operations that honor a pin (redirect to the pinned release):
-- every command the CLI routes to the workspace daemon (build, run, test,
-- clean, reset) plus configure. Everything else — status, host/management
-- commands, config edits — runs as the invoked host.
M.REDIRECT_COMMANDS = {
  build = true, run = true, test = true, clean = true, configure = true, reset = true,
}

-- Commands whose SUB-command decides: of `lw daemon`, the ones
-- that start a workspace daemon — `run` (in every form, `--stdio` included:
-- what the editor launches) and `restart` — so the daemon of a pinned
-- workspace is the pinned lw whoever starts it. `status`, `list`, `stop` and
-- `kill` speak the frozen control subset to a daemon of any version and stay
-- with the invoked host.
M.REDIRECT_SUBCOMMANDS = {
  daemon = { run = true, restart = true },
}

-- The first release that has each redirected command a pinned lw may lack
-- A pin naming an older release
-- is never redirected to for it: that host would only fail with "unknown
-- command". Keys: the command, `<command> <sub>`, and `daemon run --stdio`
-- for the editor's form. Every other redirect command predates version pins.
M.REDIRECT_SINCE = {
  reset = "0.1.27",                           -- `lw reset` (#48)
  ["daemon run"] = "0.1.43-beta.5",           -- lw daemon run|stop|kill|restart (#106)
  ["daemon restart"] = "0.1.43-beta.5",       -- (#106)
  ["daemon run --stdio"] = "0.1.43-beta.15",  -- the stdio transport (#152)
}

--- The first release that has the redirected command (`cmd`, `sub`, with
--- `--stdio` when `stdio`), or nil when every pinnable release has it.
--- @param cmd string|nil
--- @param sub string|nil
--- @param stdio boolean|nil
--- @return string|nil
function M.redirect_since(cmd, sub, stdio)
  if cmd == nil then return nil end
  if M.REDIRECT_SUBCOMMANDS[cmd] then
    if sub == nil then return nil end
    local key = cmd .. " " .. sub
    return (stdio and M.REDIRECT_SINCE[key .. " --stdio"]) or M.REDIRECT_SINCE[key]
  end
  return M.REDIRECT_SINCE[cmd]
end

--- Is `v` a safe release version? THE TRUST BOUNDARY: a version flows into
--- download URLs and into rm_rf'd cache paths, so it must not carry path
--- separators, `..`, or whitespace. Whitelist an alphanumeric-led token of
--- `[%w._+-]` (semver-ish: `0.1.0`, `0.0.0-test`, `1.2.3+build`).
function M.valid_version(v)
  if type(v) ~= "string" or v == "" then return false end
  if v:find("[/\\%s]") then return false end
  if v:find("..", 1, true) then return false end  -- plain search for literal ".."
  return v:match("^%w[%w%.%+%-]*$") ~= nil
end

--- The bundle asset name for a release version.
function M.bundle_asset(version) return "loomworks-lua-" .. version .. ".zip" end

--- The descriptor asset a release publishes (spec §16.41); its entry in the
--- signed SHA256SUMS binds that list to the release (§16.12).
function M.descriptor_asset(version) return "lw-" .. version .. "-descriptor.json" end

--- Normalize an OS name (uname sysname / "Windows") to linux|macos|windows|nil.
function M.normalize_os(sysname)
  if not sysname then return nil end
  local s = sysname:lower()
  if s:find("linux", 1, true) then return "linux" end
  if s:find("darwin", 1, true) or s:find("mac", 1, true) then return "macos" end
  if s:find("mingw", 1, true) or s:find("msys", 1, true)
      or s:find("cygwin", 1, true) or s:find("windows", 1, true) then
    return "windows"
  end
  return nil
end

--- Normalize a machine/arch string (uname machine) to x86_64|arm64|<raw>.
function M.normalize_arch(machine)
  if not machine then return nil end
  local m = machine:lower()
  if m == "x86_64" or m == "amd64" then return "x86_64" end
  if m == "arm64" or m == "aarch64" then return "arm64" end
  return m
end

--- The platforms lw is built for, as "<os>-<arch>", sorted.
--- @return string[]
function M.supported_platforms()
  local list = {}
  for key in pairs(M.HOST_ASSETS) do list[#list + 1] = (key:gsub("/", "-")) end
  table.sort(list)
  return list
end

--- Select the host-binary asset for (sysname, machine). Returns the asset name,
--- or nil + "no lw build for <os>-<arch>; supported: ..." for a platform
--- without a published build.
function M.host_asset(sysname, machine)
  local os_ = M.normalize_os(sysname) or tostring(sysname or "unknown"):lower()
  local arch = M.normalize_arch(machine) or "unknown"
  local asset = M.HOST_ASSETS[os_ .. "/" .. arch]
  if not asset then
    return nil, "no lw build for " .. os_ .. "-" .. arch .. "; supported: " ..
      table.concat(M.supported_platforms(), ", ")
  end
  return asset
end

--- The release version that first published `asset`, when that is a safe
--- version and `version` is a safe version older than it; else nil.
local function predates(version, asset, tables)
  local since = ((tables and tables.since) or M.HOST_ASSET_SINCE)[asset]
  if type(since) ~= "string" or not M.valid_version(since) or not M.valid_version(version) then
    return nil
  end
  return require("boot.paths").compare_versions(version, since) < 0 and since or nil
end

--- Does release `version` publish host asset `asset`? Fails closed: only a
--- safe version provably older than the asset's recorded first release (a
--- safe version) does not; an asset with no recorded first release, or an
--- unsafe or missing version, counts as published, so its hash is required.
--- `tables` (test seam): { assets = <HOST_ASSETS>, since = <HOST_ASSET_SINCE> }.
--- @param version string|nil
--- @param asset string
--- @param tables table|nil
--- @return boolean
function M.publishes_asset(version, asset, tables)
  return predates(version, asset, tables) == nil
end

--- The host assets release `version` publishes (spec §16.11), sorted.
--- @param version string
--- @param tables table|nil test seam, as publishes_asset
--- @return string[]
function M.host_assets_for(version, tables)
  local list = {}
  for _, a in pairs((tables and tables.assets) or M.HOST_ASSETS) do
    if M.publishes_asset(version, a, tables) then list[#list + 1] = a end
  end
  table.sort(list)
  return list
end

--- When release `version` predates host asset `asset` (a platform it never
--- published), the message saying so: "release <version> has no lw build for
--- <os>-<arch> (first published in <since>)". Nil unless `asset` is a known
--- host asset with a dated first release that the safe `version` is older
--- than: otherwise a missing hash is the caller's ordinary error. Only the
--- message differs; the caller still stops.
--- @param version string|nil
--- @param asset string
--- @param tables table|nil test seam, as publishes_asset
--- @return string|nil
function M.missing_build(version, asset, tables)
  local key
  for k, a in pairs((tables and tables.assets) or M.HOST_ASSETS) do
    if a == asset then key = k; break end
  end
  local since = key and predates(version, asset, tables)
  if not since then return nil end
  return "release " .. version .. " has no lw build for " .. (key:gsub("/", "-")) ..
    " (first published in " .. since .. ")"
end

--- The host-binary asset for the running platform (via uname), or nil, err.
function M.detect_asset()
  local sys, machine
  if uv.os_uname then
    local ok, u = pcall(uv.os_uname)
    if ok and type(u) == "table" then sys, machine = u.sysname, u.machine end
  end
  if not sys and M.is_windows then sys = "Windows" end
  return M.host_asset(sys, machine)
end

--- Parse `lw.pin` text (key = value, one per line, `#` comments). Returns
--- { version = string, hashes = { [asset] = hex } } or nil, err.
function M.parse(text)
  if type(text) ~= "string" then return nil, "pin is not text" end
  local version, hashes = nil, {}
  for line in (text .. "\n"):gmatch("([^\n]-)\n") do
    local l = line:gsub("^%s+", ""):gsub("%s+$", "")
    if l ~= "" and l:sub(1, 1) ~= "#" then
      local key, val = l:match("^([%w_%.%-]+)%s*=%s*(.-)$")
      if not key then return nil, "malformed pin line: " .. line end
      if key == "version" then
        version = val
      elseif key:sub(1, 7) == "sha256_" then
        hashes[key:sub(8)] = val:lower()
      end
      -- Unknown keys are ignored (forward compatibility).
    end
  end
  if not version or version == "" then return nil, "pin missing 'version'" end
  -- Reject a malicious/garbled version here so it never reaches a URL or an
  -- rm_rf'd path (a repo cannot redirect the fetch).
  if not M.valid_version(version) then
    return nil, "pin has an unsafe version '" .. version .. "'"
  end
  return { version = version, hashes = hashes }
end

--- Serialize a version + { [asset] = hex } into pin text (deterministic order).
function M.serialize(version, hashes)
  local out = { "version = " .. version, "" }
  local assets = {}
  for a in pairs(hashes or {}) do assets[#assets + 1] = a end
  table.sort(assets)
  for _, a in ipairs(assets) do
    out[#out + 1] = "sha256_" .. a .. " = " .. hashes[a]:lower()
  end
  return table.concat(out, "\n") .. "\n"
end

--- Read + parse `<root>/lw.pin`. Returns the pin table or nil (absent/invalid).
function M.read(root)
  if not root then return nil end
  local f = io.open(root .. "/lw.pin", "r")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return (M.parse(s))
end

--- Walk up from `start` for the nearest directory holding `lw.pin`, stopping at
--- a git working-tree boundary so it never binds a parent checkout's pin.
function M.find_pin_root(start)
  local dir = start
  if not dir or dir == "" then return nil end
  dir = dir:gsub("\\", "/"):gsub("/+$", "")
  while dir ~= "" do
    if uv.fs_stat(dir .. "/lw.pin") then return dir end
    if uv.fs_stat(dir .. "/.git") then return nil end
    local parent = dir:gsub("/[^/]*$", "")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

-- The executable the HOST runs for a redirect lives in the machine-local
-- executable cache (`<data>/exe/<sha256>/`, boot.exe_cache), never under the
-- pin root.

--- The first release whose executable is self-contained (spec §16.22): it
--- runs only its embedded code and never reads a release bundle. A pin to an
--- older release (from REPO_BUNDLE_BEFORE on) is honoured by that release's
--- own executable, which provisions its own bundle.
M.SELF_CONTAINED_SINCE = "0.2.0-beta.3"

--- The first release whose host keeps its bundle machine-local (spec
--- §16.22): earlier ones provision it into the repository-local
--- `.nvim/cache/lua-<ver>/` and load it from there, so a redirect never
--- targets them.
M.REPO_BUNDLE_BEFORE = "0.1.32"

--- Does the release `version` load its bundle from the repository (before
--- REPO_BUNDLE_BEFORE, pre-releases ordered below their release)? True for
--- an unsafe version, so a caller refusing on it refuses that too.
--- @param version string
--- @return boolean
function M.reads_repo_bundle(version)
  if not M.valid_version(version) then return true end
  return require("boot.paths").compare_versions(version, M.REPO_BUNDLE_BEFORE) < 0
end

--- Is `version` a self-contained release (SELF_CONTAINED_SINCE or later,
--- pre-releases ordered below their release)? False for an unsafe version.
--- @param version string
--- @return boolean
function M.is_self_contained(version)
  if not M.valid_version(version) then return false end
  return require("boot.paths").compare_versions(version, M.SELF_CONTAINED_SINCE) >= 0
end

--- Is `cmd` (with its sub-command `sub`, the next word) a workspace operation
--- that honors a pin?
--- @param cmd string|nil
--- @param sub string|nil
--- @return boolean
function M.is_redirect_command(cmd, sub)
  if cmd == nil then return false end
  if M.REDIRECT_COMMANDS[cmd] == true then return true end
  local subs = M.REDIRECT_SUBCOMMANDS[cmd]
  return subs ~= nil and sub ~= nil and subs[sub] == true
end

--- The first two non-flag words of `args` — the command and its sub-command
--- — skipping leading global flags, and `--root <dir>` / `--root=<dir>` (the
--- option `lw daemon run --root <dir>` carries; its value is not a word).
--- @param args string[]
--- @return string|nil command, string|nil sub
function M.command_words(args)
  local words, i = {}, 1
  while i <= #args and #words < 2 do
    local v = args[i]
    if v == "--" then break end -- the rest is a program's
    if v == "--root" then
      i = i + 1
    elseif type(v) == "string" and v:sub(1, 1) ~= "-" then
      words[#words + 1] = v
    end
    i = i + 1
  end
  return words[1], words[2]
end

-- `lw launch add|create` hands the line to a program after its command
-- operand: every token there is a program argument. `--from-target <t>` has
-- no command token, so lw's options then run to the first `--`.
local LAUNCH_ADD = { add = true, create = true }
local LAUNCH_ADD_VALUED = { ["--working-dir"] = true, ["--cwd"] = true, ["--env"] = true,
  ["--description"] = true }

--- Where lw's own arguments end in `args` (the whole command line, leading
--- global flags included): the index of the first token that belongs to a
--- program or native tool — the first `--`, or a `launch add` program's
--- arguments — or #args + 1. The host's flags (`--dev`, `--no-pin`) are
--- recognised only before it; on `launch set` and the set-value
--- commands that is up to `--`, the escape for an argument or value spelling
--- one. The host mirror of the bundle's `loomworks.cli_options.own_end` (which
--- knows every command's grammar): the host cannot load the bundle before it
--- has chosen the source. Also returns the command word's index (or nil).
--- @param args string[]
--- @return integer own_end, integer|nil command_index
function M.own_end(args)
  local n = #args + 1
  local i, c = 1, nil
  while i <= #args do
    local v = args[i]
    if v == "--" then return i, nil end
    if v == "--root" then
      i = i + 1
    elseif type(v) == "string" and v:sub(1, 1) ~= "-" then
      c = i; break
    end
    i = i + 1
  end
  if not c then return n, nil end
  local function to_dashdash(from)
    for k = from, #args do if args[k] == "--" then return k end end
    return n
  end
  if not (args[c] == "launch" and LAUNCH_ADD[args[c + 1] or ""]) then
    return to_dashdash(c + 1), c
  end
  -- A valued option takes the next token unless that is missing, `--` or
  -- starts with `--` (the bundle refuses those);
  -- `--opt=value` is one token.
  local function step(k)
    local nx = args[k + 1]
    if nx == nil or nx:sub(1, 2) == "--" then return k + 1 end
    return k + 2
  end
  local npos, k = 0, c + 2
  while k <= #args do
    local v = args[k]
    if v == "--" or npos >= 3 then return k, c end
    if v == "--from-target" then return to_dashdash(step(k)), c end
    if v:sub(1, 14) == "--from-target=" then return to_dashdash(k + 1), c end
    if LAUNCH_ADD_VALUED[v] then
      k = step(k)
    else
      if v:sub(1, 1) ~= "-" then npos = npos + 1 end
      k = k + 1
    end
  end
  return n, c
end

--- Does `args` ask for the version: `-v` / `--version` before the command
--- word (or, with no command word, among lw's own arguments)? After the
--- command `-v` is that command's own option — `--verbose` on build, run,
--- test and clean — so `lw build -v` builds while
--- `lw -v build` prints the version.
--- @param args string[] the whole command line, host flags already peeled
--- @return boolean
function M.asks_version(args)
  local stop, c = M.own_end(args)
  for i = 1, (c or stop) - 1 do
    if args[i] == "-v" or args[i] == "--version" then return true end
  end
  return false
end

--- Peel the host-level flags (`--dev`, `--dev=<path>`, `--no-pin`) off the
--- command line — only where they are lw's own (`own_end`): after `--` or in
--- a program's arguments they are left in place for the program.
--- @param args string[]
--- `dev_in_args` is set when a `--dev` came after the command word (a program
--- argument the user forgot to put after `--`, for the error hint).
--- @return string[] forwarded, { dev: boolean, dev_path: string|nil, no_pin: boolean, dev_in_args: boolean } flags
function M.peel_host_flags(args)
  local stop, c = M.own_end(args)
  local forwarded, f = {}, { dev = false, dev_path = nil, no_pin = false, dev_in_args = false }
  for i, v in ipairs(args) do
    if i < stop and v == "--dev" then
      f.dev, f.dev_in_args = true, f.dev_in_args or (c ~= nil and i > c)
    elseif i < stop and type(v) == "string" and v:sub(1, 6) == "--dev=" then
      f.dev, f.dev_path = true, v:sub(7)
      f.dev_in_args = f.dev_in_args or (c ~= nil and i > c)
    elseif i < stop and v == "--no-pin" then
      f.no_pin = true
    else
      forwarded[#forwarded + 1] = v
    end
  end
  return forwarded, f
end

--- The first release whose lw knows the global color options (`--color=<when>`,
--- `--no-color`). A pinned lw older than this
--- rejects them as unknown options (exit 2).
M.COLOR_OPTIONS_SINCE = "0.1.48"

--- The arguments a redirecting host forwards to the pinned lw `version`
--- command: unchanged, except that the color options among lw's own
--- arguments (before `own_end`) are dropped when the pinned lw predates them
--- (a prerelease of COLOR_OPTIONS_SINCE included). They are never turned into
--- an environment variable; a program's arguments are never touched.
--- @param args string[] host flags already peeled
--- @param version string the pinned version
--- @return string[]
function M.redirect_args(args, version)
  if type(version) ~= "string"
    or require("boot.paths").compare_versions(version, M.COLOR_OPTIONS_SINCE) >= 0 then
    return args
  end
  local stop = M.own_end(args)
  local out = {}
  for i, v in ipairs(args) do
    local color = type(v) == "string" and (v == "--no-color" or v:sub(1, 8) == "--color=")
    if not (i < stop and color) then out[#out + 1] = v end
  end
  return out
end

--- The error for a development source with no directory configured. With
--- `in_args` (a `--dev` after the command word, `peel_host_flags`) it adds a
--- hint: the user may have meant it for the program.
--- @param in_args boolean|nil
--- @return string
function M.dev_unconfigured_message(in_args)
  local msg = "lw: development source requested but no directory is configured.\n" ..
    "    Set one with `lw settings set dev-lua <path>`, pass `--dev=<path>`,\n" ..
    "    or export LOOMWORKS_LUA=<path>.\n"
  if in_args then
    msg = msg .. "    (`--dev` there is lw's own option; to pass it to the program,\n" ..
      "    put it after `--`, e.g. `lw launch set <project> <name> -- --dev`.)\n"
  end
  return msg
end

--- The value of `--root <dir>` / `--root=<dir>` in `args`, or nil.
--- @param args string[]
--- @return string|nil
function M.root_option(args)
  for i, v in ipairs(args) do
    if v == "--root" then return args[i + 1] end
    if type(v) == "string" and v:sub(1, 7) == "--root=" then return v:sub(8) end
  end
  return nil
end

--- Decide what a global host should do about a pin. Pure — all inputs explicit.
--- "unsupported": the pinned release predates the command (REDIRECT_SINCE);
--- the third value is the release that introduced it. The caller does not
--- redirect, and leaves the workspace daemon to the pinned lw.
--- @param o { command?, sub?, stdio?, pin?, self_version?, pinned_sentinel?, no_pin?, lw_override?, dev? }
--- @return "in-process"|"redirect"|"bypass"|"no-pin"|"unsupported" action, string reason, string|nil since
function M.decide(o)
  if o.pinned_sentinel then return "in-process", "already running as the pinned host" end
  if o.dev then return "bypass", "development source" end
  if o.lw_override then return "bypass", "LOOMWORKS_LW override" end
  if o.no_pin then return "bypass", "--no-pin" end
  if not M.is_redirect_command(o.command, o.sub) then
    return "in-process", "not a workspace operation"
  end
  if not o.pin then return "no-pin", "no pin in this workspace" end
  if o.self_version and o.pin.version == o.self_version then
    return "in-process", "pinned version == self"
  end
  local since = M.redirect_since(o.command, o.sub, o.stdio)
  if since and require("boot.paths").compare_versions(o.pin.version, since) < 0 then
    return "unsupported", "pinned version " .. tostring(o.pin.version) .. " predates it", since
  end
  return "redirect", "pinned version " .. tostring(o.pin.version)
end

--- The version a pin asks for when the invoked host is not it and nothing
--- bypasses the pin — what `decide` would redirect a workspace operation to
--- — or nil. A command such a host runs itself (a config edit, `lw profile
--- select`) must not start or replace the workspace daemon: that is the
--- pinned lw's. Pure — the same inputs as `decide`.
--- @param o { pin?, self_version?, pinned_sentinel?, no_pin?, lw_override?, dev? }
--- @return string|nil
function M.foreign_pin(o)
  if o.pinned_sentinel or o.dev or o.lw_override or o.no_pin or not o.pin then return nil end
  if o.self_version and o.pin.version == o.self_version then return nil end
  return o.pin.version
end

-- The first release that keeps workspace state in `.lw/` (§16.44): one
-- before it reads and writes only `.nvim/`.
M.STATE_DIR_SINCE = "0.2.0-beta.7"

--- The pinned version when it predates the `.lw/` state layout and this host
--- is not it and nothing bypasses the pin (`foreign_pin`), else nil. Such a
--- host must not load, migrate or create workspace state for a command it
--- runs itself: the pinned lw would never see it (§16.23). Pure.
--- @param o { pin?, self_version?, pinned_sentinel?, no_pin?, lw_override?, dev? }
--- @return string|nil
function M.legacy_layout_pin(o)
  local v = M.foreign_pin(o)
  if type(v) ~= "string" then return nil end
  if require("boot.paths").compare_versions(v, M.STATE_DIR_SINCE) >= 0 then return nil end
  return v
end

--- One argument as a shell word: bare when it is plain, else single-quoted.
local function shell_word(a)
  a = tostring(a)
  if a ~= "" and not a:find("[^%w%-%._/=:@,+%%]") then return a end
  return "'" .. a:gsub("'", "'\\''") .. "'"
end

--- The pinned lw's command `rest` through the repository's launchers, in
--- the invoked form ("run `./lw.sh <rest>`"); nil when the repository has
--- neither launcher.
--- @param invoked "lw.sh"|"lw.cmd"|"launcher"|"global"|nil
--- @param rest string
--- @param launchers { sh?: boolean, cmd?: boolean }|nil which of `<pin root>/lw.sh`, `lw.cmd` exist
--- @return string|nil
local function pinned_run(invoked, rest, launchers)
  local lc = require("boot.launcher_check")
  if invoked == "lw.sh" or invoked == "lw.cmd" then return lc.run(invoked, rest) end
  launchers = launchers or {}
  if launchers.sh and launchers.cmd then return lc.run("launcher", rest) end
  if launchers.sh then return lc.run("lw.sh", rest) end
  if launchers.cmd then return lc.run("lw.cmd", rest) end
  return nil
end

--- `lw bootstrap upgrade` in the invoked form (a launcher-run host without a
--- launcher in the repository: the installed lw's).
local function upgrade_run(invoked, launchers)
  if invoked == "launcher" then
    return pinned_run(invoked, "bootstrap upgrade", launchers)
      or require("boot.launcher_check").run("global", "bootstrap upgrade")
  end
  return require("boot.launcher_check").run(invoked, "bootstrap upgrade")
end

--- The one-line refusal of a command this host would run itself in a repo
--- whose pin predates `.lw/` (§16.23): both ways out, the pinned lw through
--- the launcher (the pinned lw by version when the repository has none) and
--- the pin moved, spelled in the invoked form.
--- @param version string the pinned version
--- @param invoked "lw.sh"|"lw.cmd"|"launcher"|"global"|nil
--- @param args string[] the command's arguments
--- @param launchers { sh?: boolean, cmd?: boolean }|nil which launchers the pin root has
--- @return string
function M.legacy_layout_message(version, invoked, args, launchers)
  local words = {}
  for _, a in ipairs(args or {}) do words[#words + 1] = shell_word(a) end
  local use = pinned_run(invoked, table.concat(words, " "), launchers)
  return "lw: this repo pins lw " .. tostring(version) .. ", which keeps its state in .nvim/; this lw keeps it in" ..
    " .lw/, which the pinned lw does not read - " ..
    (use and ("to use the pinned lw " .. use)
      or ("to use the pinned lw " .. tostring(version) .. " run this command with it")) ..
    "; to move the pin " .. upgrade_run(invoked, launchers) .. " (`--no-pin` runs this lw anyway)"
end

--- The one line `lw worktree add` prints instead of seeding the new worktree
--- in a repo whose pin predates `.lw/` (§16.25, §16.23).
--- @param version string the pinned version
--- @param invoked "lw.sh"|"lw.cmd"|"launcher"|"global"|nil
--- @param launchers { sh?: boolean, cmd?: boolean }|nil
--- @return string
function M.legacy_layout_pull_note(version, invoked, launchers)
  local use = pinned_run(invoked, "pull", launchers)
  return "pull skipped - this repo pins lw " .. tostring(version) .. ", which keeps its state in .nvim/: to fold in" ..
    " main's config " .. (use and (use .. " in the worktree") or ("run `pull` in the worktree with the pinned lw "
      .. tostring(version))) .. "; to move the pin " .. upgrade_run(invoked, launchers)
end

--- The one line a host adds before redirecting to a release that predates
--- `.lw/` when the workspace has a `.lw/user.json` (§16.23).
--- @param version string
--- @param invoked "lw.sh"|"lw.cmd"|"launcher"|"global"|nil
--- @return string
function M.legacy_layout_hint(version, invoked)
  return "lw: the pinned lw " .. tostring(version) .. " keeps its state in .nvim/ and does not read .lw/user.json" ..
    " (written by a newer lw); to use it, move the pin: " ..
    require("boot.launcher_check").run(invoked, "bootstrap upgrade")
end

-- ---------------------------------------------------------------------------
-- Pin management argument grammar. Pure.
-- ---------------------------------------------------------------------------

--- Global flags the CLI accepts among a command's own arguments; tolerated
--- (and ignored) here.
M.GLOBAL_FLAGS = { ["--no-input"] = true, ["--non-interactive"] = true,
  ["--insecure"] = true, ["--verify"] = true, ["--verbose"] = true,
  ["--no-color"] = true }

local INSTALL_ONLY = { "--version", "--latest", "--channel", "--pin-only", "--force" }

--- Parse `lw bootstrap [install|upgrade] …` arguments.
--- @param args string[] the arguments (host flags already peeled), including
---   the command word itself
--- @param command "bootstrap"
--- @param popts? { invoked?: string } how lw was run, so messages name commands
---   in that form (boot.launcher_check.cmd)
--- @return table|nil opts { sub, version?, latest?, channel?, pin_only?, force?, json?, check? }, string|nil usage_error
function M.parse_bootstrap_args(args, command, popts)
  local invoked = popts and popts.invoked
  local function C(rest) return require("boot.launcher_check").cmd(invoked, rest) end
  local o = { flags = {} }
  local seen_command, positional = false, {}
  local i = 1
  local function value(flag)
    local v = args[i + 1]
    if v == nil or v:sub(1, 1) == "-" then return nil, flag .. " needs a value" end
    i = i + 1
    return v
  end
  while i <= #args do
    local v = args[i]
    local eqv
    if type(v) == "string" and v:sub(1, 2) == "--" and v:find("=", 1, true) then
      v, eqv = v:match("^([^=]+)=(.*)$")
    end
    if v == "--version" or v == "--channel" then
      local val, err = eqv, nil
      if val == nil then val, err = value(v) end
      if not val or val == "" then return nil, err or (v .. " needs a value") end
      if v == "--version" then o.version = val else o.channel = val end
      o.flags[v] = true
    elseif v == "--latest" then o.latest = true; o.flags[v] = true
    elseif v == "--pin-only" then o.pin_only = true; o.flags[v] = true
    elseif v == "--force" then o.force = true; o.flags[v] = true
    elseif v == "--json" then o.json = true; o.flags[v] = true
    elseif v == "--check" then o.check = true; o.flags[v] = true
    elseif v == "--color" and eqv ~= nil then -- `--color=<when>`, validated, else ignored
      if eqv ~= "auto" and eqv ~= "always" and eqv ~= "never" then
        return nil, "invalid value '" .. eqv .. "' for --color -- use auto, always or never"
      end
    elseif M.GLOBAL_FLAGS[v] and eqv == nil then -- tolerated
    elseif type(v) == "string" and v:sub(1, 1) == "-" then
      return nil, "unknown option '" .. v .. "' for `" .. C(command) .. "`"
    elseif not seen_command and v == command then
      seen_command = true
    else
      positional[#positional + 1] = v
    end
    i = i + 1
  end

  local sub = positional[1]
  if #positional > 1 then return nil, "unexpected argument '" .. positional[2] .. "'" end
  if sub == nil then
    for _, f in ipairs(INSTALL_ONLY) do
      if o.flags[f] then
        local example = f == "--version" and ("--version " .. tostring(o.version)) or f
        return nil, "`" .. C("bootstrap") .. "` only reports; to write the pin and launchers run" ..
          " `" .. C("bootstrap install " .. example) .. "`"
      end
    end
    return o
  end
  if sub ~= "install" and sub ~= "upgrade" then
    return nil, "unknown `" .. C("bootstrap") .. "` sub-command '" .. sub .. "' (install, upgrade)"
  end
  if o.json or o.check then
    return nil, (o.json and "--json" or "--check") .. " belongs to the status page (`" .. C("bootstrap") .. "`)"
  end
  o.sub = sub
  if sub == "upgrade" then
    if o.version then return nil, "`" .. C("bootstrap upgrade") .. "` takes no --version; use `" ..
      C("bootstrap install --version <x.y.z>") .. "`" end
    o.latest = true
  end
  if o.version and o.latest then return nil, "--version and --latest cannot be combined" end
  if o.channel and not o.latest then return nil, "--channel applies only with --latest (or `upgrade`)" end
  return o
end

return M
