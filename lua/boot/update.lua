-- Release resolution and acquisition helpers for the host bootstrap: the
-- update channel, the newest release (from its signed SHA256SUMS), the
-- per-version asset base, and verified fetches of host executables.
-- Self-update itself replaces only the executable (boot.host_update, spec
-- §16.32); no release bundle is installed.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local miniz = require("miniz")
local paths = require("boot.paths")
local verify = require("boot.verify")
local download = require("boot.download")
local pin = require("boot.pin")
local origin = require("boot.origin")
local json = require("boot.json")

local M = {}

--- Is `h` a SHA-256 hex digest?
local function is_sha256(h)
  return type(h) == "string" and #h == 64 and h:match("^%x+$") ~= nil
end

-- Where releases are fetched from. Overridable via LOOMWORKS_RELEASE_URL or
-- the `release-url` config key; a local directory works as an offline mirror.
-- `/releases/latest/download` already resolves to the newest NON-prerelease on
-- GitHub, so this base IS the `stable` channel. Latest queries go to
-- the current repository only; a SPECIFIC version's assets come from the
-- repository that version was published in (boot.origin, see versioned_base).
M.DEFAULT_RELEASE_URL = origin.LATEST_DOWNLOAD

-- The releases API for the default origin. Consulted ONLY to resolve the
-- `unstable` channel: the newest release INCLUDING pre-releases. Never
-- queried for `stable`, nor when a release-source override / mirror is set —
-- the channel governs only the default origin.
M.RELEASES_API_URL = origin.RELEASES_API

-- The update channels this host knows. `stable` (default) is unchanged
-- behavior; `unstable` follows pre-releases too. Both verify identically.
M.CHANNELS = { stable = true, unstable = true }
M.DEFAULT_CHANNEL = "stable"

local function release_base(opts)
  local base = (opts and opts.url)
    or paths.getenv("LOOMWORKS_RELEASE_URL")
    or paths.read_config()["release-url"]
    or M.DEFAULT_RELEASE_URL
  return (base:gsub("/+$", ""))
end

--- The `latest`/override release base (holds manifest.json + `latest` assets).
function M.release_base(opts) return release_base(opts) end

--- The user-supplied release-source override (opts.url > LOOMWORKS_RELEASE_URL >
--- `release-url` config), or nil when the default origin is in effect. An
--- override is a mirror used as-is and SUPERSEDES channel resolution:
--- the channel governs only the default origin. Public so `lw health` can
--- surface the "channel is being overridden" state without reimplementing
--- the precedence.
function M.url_override(opts)
  return (opts and opts.url)
    or paths.getenv("LOOMWORKS_RELEASE_URL")
    or paths.read_config()["release-url"]
end
local url_override = M.url_override

--- Resolve the active update channel with precedence: explicit
--- opts.channel > LOOMWORKS_CHANNEL env > `channel` config key > default
--- (stable). Returns the channel name, or nil + err for an unknown value.
--- @return string|nil channel, string|nil err
function M.resolve_channel(opts)
  local c = (opts and opts.channel)
    or paths.getenv("LOOMWORKS_CHANNEL")
    or paths.read_config()["channel"]
    or M.DEFAULT_CHANNEL
  if not M.CHANNELS[c] then
    return nil, "unknown update channel '" .. tostring(c) ..
      "' (expected 'stable' or 'unstable')"
  end
  return c
end

--- Save `channel` as the host's update channel — what
--- `lw self-update --channel <c>` does, writing the same `channel` key as
--- `lw settings set channel <c>`. LOOMWORKS_CHANNEL still overrides it for a run.
--- @param channel string
--- @return { changed: boolean, channel: string, previous?: string, file: string }|nil result
--- @return string|nil err
function M.persist_channel(channel)
  if not M.CHANNELS[channel] then
    return nil, "unknown update channel '" .. tostring(channel) ..
      "' (expected 'stable' or 'unstable')"
  end
  local cfg = paths.read_config()
  local previous = cfg.channel
  local file = paths.config_file()
  if previous == channel then return { changed = false, channel = channel, file = file } end
  cfg.channel = channel
  local ok, err = paths.write_config(cfg)
  if not ok then return nil, "could not save the update channel to " .. file .. ": " .. tostring(err) end
  return { changed = true, channel = channel, previous = previous, file = file }
end

--- Resolve the newest release version for the `unstable` channel by
--- querying the releases API. The highest-versioned NON-DRAFT entry wins (by
--- version, never list order; a pre-release ranks below its release) —
--- pre-releases are INCLUDED (that is what `unstable` means). Returns the version (leading `v`
--- stripped) or nil, err.
---
--- SECURITY: the tag is network-derived, so it is validated with
--- pin.valid_version BEFORE it can reach any URL or path (defense in depth).
--- Transport is never trusted — the release it names is still bound to its
--- signed hash list and hash-verified downstream exactly as on stable.
--- `fetch_limits` (optional) is passed to `download.fetch` — the health check's
--- quick timeouts; self-update calls it without, keeping the default retries.
--- @param fetch_limits? { connect_timeout?: integer, max_time?: integer, attempts?: integer }
--- @return string|nil version, string|nil err
function M.resolve_unstable_version(fetch_limits)
  local fopts = {
    headers = { "Accept: application/vnd.github+json", "User-Agent: loomworks-lw" },
  }
  for k, v in pairs(fetch_limits or {}) do fopts[k] = v end
  local body, e = download.fetch(M.RELEASES_API_URL, fopts)
  if not body then return nil, "fetch releases: " .. tostring(e) end
  local releases, derr = json.decode(body)
  if type(releases) ~= "table" then
    return nil, "releases API: " .. (derr or "unexpected response")
  end
  -- The API lists releases in PUBLISH order, not version order (a stable
  -- release cut after a newer pre-release is listed first), so take the
  -- HIGHEST non-draft version by release ordering (a pre-release ranks
  -- below its release). Every candidate tag is validated first: one unsafe
  -- tag fails the whole query.
  local best
  for _, rel in ipairs(releases) do
    if type(rel) == "table" and rel.draft ~= true and type(rel.tag_name) == "string" then
      local ver = (rel.tag_name:gsub("^v", ""))
      if not pin.valid_version(ver) then
        return nil, "releases API returned an unsafe version '" ..
          tostring(rel.tag_name) .. "'"
      end
      if not best or paths.version_gt(ver, best) then best = ver end
    end
  end
  if best then return best end
  return nil, "no releases found on the unstable channel"
end

--- The newest release a `latest`/override base publishes, from its SIGNED
--- hash list (spec §16.12): SHA256SUMS + SHA256SUMS.sig are fetched and the
--- signature verified with the key built into this host, then the version is
--- read from the list's one version-bearing descriptor entry
--- (`lw-<version>-descriptor.json`). A release before self-contained
--- executables names no descriptor: only then (transitional, while such a
--- release is the newest) is the version read from its signed manifest.json,
--- and only when the signed list names that version's bundle.
--- A list whose signature does not verify is an error, never a fallback.
--- `fetch` (curl limits, see `download.fetch`) bounds every fetch.
---
--- SECURITY: the version is validated with pin.valid_version before it is
--- returned (it becomes part of URLs downstream).
--- @param base string
--- @param fetch? table curl limits
--- @return string|nil version, string|nil err
function M.latest_signed_version(base, fetch)
  local sums, e1 = download.fetch(base .. "/SHA256SUMS", fetch)
  if not sums then return nil, "fetch SHA256SUMS: " .. tostring(e1) end
  local sig, e2 = download.fetch(base .. "/SHA256SUMS.sig", fetch)
  if not sig then return nil, "fetch SHA256SUMS.sig: " .. tostring(e2) end
  local okv, ev = verify.verify_detached(sums, sig)
  if not okv then return nil, "SHA256SUMS signature: " .. tostring(ev) end
  local found
  local list = require("boot.bootstrap").parse_sums(sums)
  for name in pairs(list) do
    local v = name:match("^lw%-(.+)%-descriptor%.json$")
    if v then
      if not pin.valid_version(v) then
        return nil, "SHA256SUMS names an unsafe release version '" .. v .. "'"
      end
      if found and found ~= v then
        return nil, "SHA256SUMS names more than one release's descriptor (" .. found ..
          ", " .. v .. ")"
      end
      found = v
    end
  end
  if found then return found end
  -- Transitional: the newest release predates self-contained executables.
  local mbytes, em = download.fetch(base .. "/manifest.json", fetch)
  if not mbytes then
    return nil, "SHA256SUMS names no release descriptor, and manifest.json is " ..
      "unavailable: " .. tostring(em)
  end
  local msig, es = download.fetch(base .. "/manifest.json.sig", fetch)
  if not msig then return nil, "fetch manifest.json.sig: " .. tostring(es) end
  local manifest, merr = verify.load_manifest(mbytes, msig)
  if not manifest then return nil, merr end
  if not pin.valid_version(manifest.version) then
    return nil, "manifest named an unsafe version '" .. tostring(manifest.version) .. "'"
  end
  -- The manifest is signed on its own, so it could be another release's than
  -- the list's: accept its version only when the signed list names that
  -- release's bundle (the version-bearing entry of such a release, §16.12).
  local own = pin.bundle_asset(manifest.version)
  if not list[own] then
    return nil, "SHA256SUMS does not match manifest.json: it has no '" .. own ..
      "' entry for release " .. manifest.version
  end
  return manifest.version
end

--- Resolve the newest AVAILABLE release version for the resolved channel,
--- without downloading any executable: the releases API on `unstable` (the
--- default origin only; reusing resolve_unstable_version), else the signed
--- SHA256SUMS of the `latest`/override base (`latest_signed_version`). Behind
--- self-update's target, `lw health`'s update check, `lw release query` and
--- `lw bootstrap install --latest`. All failures (offline, HTTP error,
--- malformed body, a signature that does not verify) are returned as
--- `nil, err` so a caller can degrade silently.
---
--- `opts.fetch` (curl limits, see `download.fetch`) bounds the fetches; the
--- health check passes quick timeouts so an unreachable network cannot stall
--- `lw health`. A local/mirror base is a file read and ignores it.
--- @return string|nil version, string|nil err
function M.resolve_newest_version(opts)
  opts = opts or {}
  local channel, cerr = M.resolve_channel(opts)
  if not channel then return nil, cerr end
  -- `unstable` on the default origin: newest incl. pre-releases via the API. A
  -- mirror/override supersedes the channel and is read like stable.
  if channel == "unstable" and not url_override(opts) then
    return M.resolve_unstable_version(opts.fetch)
  end
  return M.latest_signed_version(release_base(opts), opts.fetch)
end

--- Self-update's target when no `--version` is given: the resolved channel's
--- newest release (spec §16.29, §16.32). `channel_overridden` is the
--- requested channel name when a release-url override superseded a
--- non-default channel (nil otherwise) — for the caller to warn about.
--- @param opts? { url?: string, channel?: string, fetch?: table }
--- @return { version: string, channel: string, channel_overridden?: string }|nil target
--- @return string|nil err
function M.resolve_target(opts)
  opts = opts or {}
  local channel, cerr = M.resolve_channel(opts)
  if not channel then return nil, cerr end
  -- A release-url override supersedes the channel: it is used as-is and the
  -- channel (which governs only the default origin) is ignored. By design, but
  -- silent it misleads, so a NON-DEFAULT channel superseded this way is
  -- reported (`stable` is the override's own behavior: no conflict).
  local overridden = (channel ~= M.DEFAULT_CHANNEL and url_override(opts)) and channel or nil
  local version, err = M.resolve_newest_version(opts)
  if not version then return nil, err end
  return { version = version, channel = channel, channel_overridden = overridden }
end

--- Is `base` a local path / offline mirror (flat layout) rather than the
--- versioned GitHub origin? Mirrors boot.download's scheme test.
local function is_local_base(base)
  local scheme = base:match("^(%a[%w+.-]*)://")
  if scheme == "file" then return true end
  if not scheme then return true end
  return false
end

--- The base URL holding a SPECIFIC version's assets. Without a release-url
--- override they come from the repository that version was published in
--- (boot.origin: below 0.2 the legacy one, never retried at the other) under
--- its versioned path (…/releases/download/v<ver>/). An override is one mirror
--- for all versions: a GitHub-shaped `…/releases/latest/download` one maps to
--- its own versioned path, any other (or a local base) is flat — the version's
--- assets sit at the base directly. So the
--- pin's per-version fetches resolve on GitHub and against an offline mirror
--- alike.
function M.versioned_base(version, opts)
  -- Defense in depth: never interpolate an unvalidated version into a URL.
  if not pin.valid_version(version) then
    error("unsafe release version: " .. tostring(version))
  end
  local base = release_base(opts)
  if is_local_base(base) then return base end
  if not url_override(opts) then return origin.download_base(version) end
  local root = base:match("^(.-)/releases/latest/download$")
  if root then return root .. "/releases/download/v" .. version end
  return base
end

--- Ensure the host binary `asset` for `version` is cached at `dest`, verified
--- against the pinned `sha256` (mandatory, unconditional). Idempotent: a present
--- file whose hash matches is reused; a mismatch deletes the bad file. Reuses
--- boot.download + boot.verify + rename_with_retry. Returns true, dest or nil, err.
--- `opts.on_fetch()`, when given, is called once just before a download (never
--- when the cached file verifies), so a caller can say it is fetching.
function M.ensure_host_binary(version, asset, sha256, dest, opts)
  if not pin.valid_version(version) then
    return nil, "unsafe release version '" .. tostring(version) .. "'"
  end
  if not is_sha256(sha256) then
    return nil, "no pinned sha256 for '" .. tostring(asset) .. "'"
  end
  if uv.fs_stat(dest) and verify.verify_file_sha256(dest, sha256) then
    return true, dest
  end
  paths.rm_rf(dest)
  local parent = dest:match("^(.*)/[^/]*$")
  if parent then
    local ok, err = paths.mkdirp(parent)
    if not ok then return nil, "prepare cache dir: " .. tostring(err) end
  end
  local tmp = dest .. ".dl"
  paths.rm_rf(tmp)
  if opts and opts.on_fetch then opts.on_fetch() end
  local url = M.versioned_base(version, opts) .. "/" .. asset
  local okd, ed = download.fetch_to_file(url, tmp)
  if not okd then paths.rm_rf(tmp); return nil, "fetch " .. asset .. ": " .. ed end
  local okv, ev = verify.verify_file_sha256(tmp, sha256)
  if not okv then paths.rm_rf(tmp); return nil, "verify " .. asset .. ": " .. (ev or "mismatch") end
  local okr, er = M.rename_with_retry(tmp, dest)
  if not okr then paths.rm_rf(tmp); return nil, "activate " .. asset .. ": " .. tostring(er) end
  if not paths.is_windows then pcall(uv.fs_chmod, dest, tonumber("755", 8)) end
  return true, dest
end

--- The machine-local directory for everything a pinned run provisions:
--- `<data>/pinned`. Never inside a repository — a clone can ship any file
--- under its own tree, so nothing there is trusted.
function M.pinned_root() return paths.data_dir() .. "/pinned" end

--- Where the pinned bundle for (`version`, pinned bundle `sha256`) lives:
--- `<data>/pinned/<sha256>/lua-<version>`. Keyed by the pinned hash, so a pin
--- naming a different hash never reuses a directory provisioned (verified)
--- for another; the `lua-<version>` tail keeps the version derivable from the
--- root like every other release root.
function M.pinned_bundle_dir(version, sha256)
  return M.pinned_root() .. "/" .. tostring(sha256):lower() .. "/lua-" .. version
end

--- Transitional, for a bootstrap-only host (one that does not embed the code)
--- in pinned context only; the redirect never provisions a bundle (it runs
--- the pinned executable from boot.exe_cache).
--- Provision the pinned release bundle for `version` into the MACHINE-LOCAL
--- pinned cache (`pinned_bundle_dir`), verified against the pinned
--- `opts.bundle_sha256`. Idempotent (a bundle this function already extracted
--- and verified is reused); a failed/partial provision leaves prior state
--- intact. The directory is only ever populated here, after the download from
--- the fixed origin matched the pinned hash, so reusing it by presence is
--- sound. A repository's own `.nvim/cache` is never consulted: a clone can
--- ship a pre-"extracted" bundle there. Returns the lua-root or nil, err.
--- (`opts.root`, the pin root, is accepted for callers but no longer used.)
--- `opts.on_fetch()`, when given, is called once just before the bundle is
--- downloaded (never when it is already provisioned).
function M.ensure_version(version, opts)
  opts = opts or {}
  -- Trust boundary: `version` becomes an rm_rf'd path below, so refuse a
  -- traversal before touching the filesystem.
  if not pin.valid_version(version) then
    return nil, "unsafe release version '" .. tostring(version) .. "'"
  end
  local bundle = "loomworks-lua-" .. version .. ".zip"
  local sha = opts.bundle_sha256
  if not is_sha256(sha) then
    return nil, "no pinned sha256 for '" .. bundle .. "'"
  end
  sha = sha:lower()
  local dest = M.pinned_bundle_dir(version, sha)
  -- Already provisioned by us? The CLI entry existing is the marker.
  if uv.fs_stat(dest .. "/loomworks/cli.lua") then return dest end

  local cache = M.pinned_root()
  local okm, em = paths.mkdirp(cache .. "/" .. sha)
  if not okm then return nil, "prepare pinned cache dir: " .. tostring(em) end

  local tmpzip = cache .. "/.dl-" .. sha .. "-" .. version .. ".zip"
  paths.rm_rf(tmpzip)
  if opts.on_fetch then opts.on_fetch() end
  local url = M.versioned_base(version, opts) .. "/" .. bundle
  local okd, ed = download.fetch_to_file(url, tmpzip)
  if not okd then paths.rm_rf(tmpzip); return nil, "fetch bundle: " .. ed end
  local okv, ev = verify.verify_file_sha256(tmpzip, sha)
  if not okv then paths.rm_rf(tmpzip); return nil, "bundle verify: " .. (ev or "mismatch") end

  local stage = cache .. "/.stage-" .. sha .. "-" .. version
  paths.rm_rf(stage)
  local okx, ex = M.extract_zip(tmpzip, stage)
  paths.rm_rf(tmpzip)
  if not okx then paths.rm_rf(stage); return nil, "extract: " .. ex end
  if uv.fs_stat(dest) then paths.rm_rf(dest) end
  local okr, er = M.rename_with_retry(stage, dest)
  if not okr then paths.rm_rf(stage); return nil, "activate: " .. tostring(er) end
  return dest
end

--- Extract the zip at `zip_path` into `dest_dir` (created). Rejects unsafe
--- entry names (path traversal / absolute). Returns true or nil, err.
function M.extract_zip(zip_path, dest_dir)
  local reader = miniz.new_reader(zip_path)
  if not reader then return nil, "'" .. zip_path .. "' is not a valid zip" end

  -- Single exit so the reader handle is always released before we return.
  -- miniz's reader has no close method and keeps the archive file mmapped/open
  -- until it is garbage-collected; on Windows an open handle turns a later
  -- unlink of `zip_path` into a lingering "delete pending" file that can't be
  -- rewritten (Permission denied) — which bites callers that reuse a
  -- deterministic archive path (e.g. `lw module` reinstalling the same name).
  -- Dropping the reference and forcing a collection here is the "close".
  local err
  local ok = paths.mkdirp(dest_dir)
  if not ok then err = "cannot create '" .. dest_dir .. "'" end
  if ok then
    for i = 1, reader:get_num_files() do
      local name = reader:get_filename(i)
      if name:find("%.%.", 1, true) or name:match("^/") or name:match("^%a:")
          or name:match("^\\") then  -- also reject a leading backslash / UNC
        err = "unsafe zip entry '" .. name .. "'"; break
      end
      local target = dest_dir .. "/" .. name
      if reader:is_directory(i) then
        local mok, merr = paths.mkdirp(target)
        if not mok then err = merr; break end
      else
        local parent = target:match("^(.*)/[^/]*$")
        if parent then
          local mok, merr = paths.mkdirp(parent)
          if not mok then err = merr; break end
        end
        local data = reader:extract(i)
        if data == nil then err = "failed to extract '" .. name .. "'"; break end
        local f, oe = io.open(target, "wb")
        if not f then err = "cannot write '" .. target .. "': " .. tostring(oe); break end
        f:write(data); f:close()
      end
    end
  end

  reader = nil
  collectgarbage("collect")
  if err then return nil, err end
  return true
end

--- Rename `src` to `dst`, retrying transient Windows failures. Immediately
--- after extracting a bundle, Windows Defender (or the search indexer) often
--- holds a brief handle on a freshly written file, so `MoveFile` on the
--- directory fails with ACCESS_DENIED (EPERM/EACCES) or a sharing violation
--- (EBUSY). These clear once the scan finishes, so back off and retry rather
--- than aborting the whole self-update. Returns true, or false + last error.
--- @param src string
--- @param dst string
--- @param opts? { rename?: fun(a:string,b:string):boolean|nil, sleep?: fun(ms:integer), attempts?: integer }
function M.rename_with_retry(src, dst, opts)
  opts = opts or {}
  local rename = opts.rename or uv.fs_rename
  local sleep = opts.sleep or (uv.sleep and function(ms) uv.sleep(ms) end) or function() end
  local attempts = opts.attempts or 15
  local last
  for i = 1, attempts do
    local ok, err = rename(src, dst)
    if ok then return true end
    last = err
    if i < attempts then sleep(math.min(60 * i, 400)) end
  end
  return false, last
end

--- The one-line `lw version` report. The host's release version
--- leads, with the capability version in parentheses. A host with no
--- embedded release version never guesses one: it is `dev build` when it IS a
--- development build (`info.dev_build`, from host_update.dev_build — the same
--- predicate self-update uses), else `unknown release` (a release host built
--- before version identity existed, which self-update does replace).
--- ASCII only: it prints before system Lua can set the console
--- encoding. In pinned context the PIN decides what runs, not the
--- update channel: the line names the pinned version (marked prerelease when it
--- is one) and the pin file, and carries no channel. A release bundle that is a
--- prerelease is marked `(prerelease)` too.
---
--- Embedded code (a release executable, spec §16.32) has no bundle and no
--- capability version: the line names the release version (marked prerelease)
--- and "self-contained", or "dev build", then the pin or the channel.
--- @param info { host_version: integer, release_version?: string, dev_build?: boolean, source: string, bundle: string }
--- @param channel string the resolved update channel
--- @param pinned? { file: string, version: string } the pin this invocation runs under
--- @return string line
function M.version_line(info, channel, pinned)
  local function pin_or_channel(line)
    if pinned then
      return line .. " | pinned: " .. pinned.version
        .. (paths.is_prerelease(pinned.version) and " (prerelease)" or "")
        .. " by " .. pinned.file
    end
    return line .. " | channel: " .. channel
  end
  if info.source == "embedded" then
    local v = (not info.dev_build) and info.release_version or nil
    local label = v and (v .. (paths.is_prerelease(v) and " (prerelease)" or "") .. " (self-contained)")
      or "dev build"
    return pin_or_channel("lw - host: " .. label)
  end
  local label = info.release_version
    or (info.dev_build and "dev build" or "unknown release")
  local host = label .. " (v" .. info.host_version .. ")"
  -- A prerelease bundle says so (a user following `stable` after trying
  -- `unstable` keeps it until a newer stable arrives).
  local bundle = info.bundle
  if info.source == "release" and paths.is_prerelease(bundle) then bundle = bundle .. " (prerelease)" end
  return pin_or_channel(string.format("lw - host: %s | source: %s | bundle: %s",
    host, info.source, bundle))
end

--- Describe the resolved runtime for `lw version`.
--- With no on-disk source, system Lua can only come from the host itself: it
--- is `fused` when the host really carries it (a dev build / source run,
--- `opts.fused_system_lua`); otherwise nothing is installed — a release host
--- before its first `lw self-update` — and the report says so rather than
--- claiming a bundle every other command would then fail to find.
--- Embedded code (`source_kind` "embedded", spec §16.11) has no bundle: the
--- info names its release version (`opts.release_version`, default the host's).
--- @param luaroot string|nil the resolved system-Lua root
--- @param source_kind "dev"|"release"|"embedded"|nil the system-Lua source
--- @param opts? { dev_build?: boolean, fused_system_lua?: boolean, release_version?: string } whether the host is a development build (host_update.dev_build) / carries system Lua fused in
--- @return { host_version: integer, release_version: string|nil, dev_build: boolean, source: string, bundle: string, luaroot: string|nil }
function M.version_info(luaroot, source_kind, opts)
  local bundle, source = nil, source_kind
  if source_kind == "embedded" then
    return {
      host_version = verify.HOST_VERSION,
      release_version = (opts and opts.release_version) or verify.RELEASE_VERSION,
      dev_build = (opts and opts.dev_build) and true or false,
      source = "embedded",
      bundle = "embedded",
    }
  end
  if source_kind == "dev" then
    bundle = "dev (" .. (luaroot or "?") .. ")"
  elseif source_kind == "release" and luaroot then
    bundle = luaroot:match("lua%-(.+)$") or "?"
  elseif opts and opts.fused_system_lua then
    bundle, source = "bundled (fused)", "fused"
  else
    bundle, source = "none installed (run `lw self-update`)", "none"
  end
  return {
    host_version = verify.HOST_VERSION,
    -- The host's embedded release version; nil = a dev build or
    -- a release host from before version identity (told apart by dev_build).
    release_version = verify.RELEASE_VERSION,
    dev_build = (opts and opts.dev_build) and true or false,
    source = source,
    bundle = bundle,
    luaroot = luaroot,
  }
end

return M
