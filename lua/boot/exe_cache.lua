-- The machine-local, content-addressed cache of release executables
-- (spec §16.13, §16.22, §16.23, §16.40).
--
--   <data>/exe/<sha256>/lw[.exe]            a cached executable (its slot)
--   <data>/exe/<sha256>.<pid>.<nonce>.dl    one acquisition in progress
--
-- A slot is keyed by the executable's own content hash, so a pin naming
-- another hash never reuses it, and a file in it is re-hashed before every
-- run. The cache is never inside a repository (a clone can ship any file
-- there) and never moved by LOOMWORKS_INSTALL_DIR (§16.22 "No install
-- folder").
--
-- Deletion safety: this module removes only (a) its own temporary file, by
-- its exact name, and (b) a slot's executable whose hash does not match the
-- slot, by its exact name, when it is a regular file. It never removes a
-- directory, never follows a link or junction (every check is an lstat), and
-- never overwrites a matching executable (another process may be running it).
-- Leftover temp files of other processes are housekeeping's (24 h, §16.40);
-- slots are pruned only by `lw cleanup --all`.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local paths = require("boot.paths")
local pin = require("boot.pin")
local verify = require("boot.verify")

local M = {}

--- Hex digits of a temporary file's nonce (fixed: housekeeping matches it exactly).
M.NONCE_LEN = 16

--- The executable's name inside a slot.
M.EXE_NAME = paths.is_windows and "lw.exe" or "lw"

--- Is `s` a sha256 as the cache spells it (64 lower-case hex digits)?
local function is_sha(s)
  return type(s) == "string" and #s == 64 and s:match("^[0-9a-f]+$") ~= nil
end
M.is_sha = is_sha

--- Is `asset` a published host-executable asset name?
local function is_asset(asset)
  for _, a in pairs(pin.HOST_ASSETS) do
    if asset == a then return true end
  end
  return false
end

--- `<data>/exe`.
function M.dir() return paths.data_dir() .. "/exe" end

--- `<data>/exe/<sha256>`.
function M.slot(sha) return M.dir() .. "/" .. sha end

--- `<data>/exe/<sha256>/lw[.exe]`.
function M.path(sha) return M.slot(sha) .. "/" .. M.EXE_NAME end

--- The temporary file name of an acquisition: `<sha256>.<pid>.<nonce>.dl`.
function M.temp_name(sha, pid, nonce)
  return sha .. "." .. tostring(pid) .. "." .. nonce .. ".dl"
end

--- Is `name` exactly a temporary file name (`<64 lower hex>.<digits>.<16 lower hex>.dl`)?
function M.is_temp_name(name)
  if type(name) ~= "string" then return false end
  local sha, pid, nonce = name:match("^([0-9a-f]+)%.(%d+)%.([0-9a-f]+)%.dl$")
  return sha ~= nil and is_sha(sha) and #pid <= 10 and #nonce == M.NONCE_LEN
end

local function nonce()
  local ok, bytes = pcall(uv.random, M.NONCE_LEN / 2)
  if ok and type(bytes) == "string" and #bytes == M.NONCE_LEN / 2 then
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
  local t = {}
  for i = 1, M.NONCE_LEN do t[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(t)
end

--- A resolved path as a comparison key: forward slashes, no trailing slash,
--- case-folded on Windows.
local function realkey(p)
  local r = uv.fs_realpath(p)
  if type(r) ~= "string" then return nil end
  r = r:gsub("\\", "/"):gsub("/+$", "")
  if paths.is_windows then r = r:lower() end
  return r
end

--- `<data>/exe` as a real directory (lstat: not a link or junction) whose
--- resolved path is the resolved `<data>` plus `/exe`. With `create`, the data
--- directory and `exe` are made when missing. Returns true or nil, err.
local function real_cache_dir(create)
  local data, dir = paths.data_dir(), M.dir()
  if create then
    local ok, err = paths.mkdirp(data)
    if not ok then return nil, "cannot create " .. data .. ": " .. tostring(err) end
    if not uv.fs_lstat(dir) then
      local mok, merr = uv.fs_mkdir(dir, tonumber("755", 8))
      if not mok and not uv.fs_lstat(dir) then return nil, "cannot create " .. dir .. ": " .. tostring(merr) end
    end
  end
  local st = uv.fs_lstat(dir)
  if not st then return nil, dir .. " does not exist" end
  if st.type ~= "directory" then return nil, dir .. " is not a directory (a link is never followed)" end
  local rd, rx = realkey(data), realkey(dir)
  if not rd or not rx or rx ~= rd .. "/exe" then
    return nil, dir .. " does not resolve inside " .. data
  end
  return true
end

--- The state of a slot: "absent", "ok" (a real directory holding a regular
--- executable whose hash matches), "missing" (a real directory without the
--- executable), "mismatch" (a regular executable with another hash), or nil +
--- the reason for anything that is not lw's to touch (a link, a file where
--- the directory belongs, a directory at the executable's name).
local function slot_state(sha)
  local slot, exe = M.slot(sha), M.path(sha)
  local st = uv.fs_lstat(slot)
  if not st then return "absent" end
  if st.type ~= "directory" then
    return nil, slot .. " is not a directory (a link is never followed); remove it and re-run"
  end
  local fst = uv.fs_lstat(exe)
  if not fst then return "missing" end
  if fst.type ~= "file" then
    return nil, exe .. " is not a regular file (a link is never followed); remove it and re-run"
  end
  if verify.verify_file_sha256(exe, sha) then return "ok" end
  return "mismatch"
end

--- Re-verify the cached executable for `sha` just before it runs: `<data>/exe`
--- and the slot are real directories, the executable a regular file whose
--- content hash is `sha`. Returns true, or nil + the reason.
function M.verify_before_run(sha)
  if not is_sha(sha) then return nil, "not a sha256: " .. tostring(sha) end
  local okd, ed = real_cache_dir(false)
  if not okd then return nil, ed end
  local state, why = slot_state(sha)
  if state == "ok" then return true end
  return nil, why or (M.path(sha) .. (state == "mismatch" and " does not match its hash" or " is missing"))
end

--- Record the last use of the slot for `sha`: its directory's modification
--- time (never a file in it, §16.40). Never raises.
function M.touch(sha, now)
  if not is_sha(sha) then return end
  local slot = M.slot(sha)
  local st = uv.fs_lstat(slot)
  if not st or st.type ~= "directory" then return end
  now = now or os.time()
  pcall(uv.fs_utime, slot, now, now)
end

--- Unlink `path` by its exact name when it is not a real directory (a file,
--- a link, a junction: unlinking a link removes the link only). A real
--- directory is never removed. Returns true or nil, err.
local function unlink_name(path)
  local st = uv.fs_lstat(path)
  if not st then return true end
  if st.type == "directory" then return nil, path .. " is a directory" end
  local ok, err = uv.fs_unlink(path)
  if ok or not uv.fs_lstat(path) then return true end
  return nil, tostring(err)
end

--- Write `bytes` into a new file at `path`, created exclusively (never
--- through an existing name), executable. Returns true or nil, err.
local function write_exclusive(path, bytes)
  local fd, err = uv.fs_open(path, "wx", tonumber("755", 8))
  if not fd then return nil, "cannot create " .. path .. ": " .. tostring(err) end
  local off, werr = 0, nil
  while off < #bytes do
    local n, e = uv.fs_write(fd, bytes:sub(off + 1), off)
    if not n or n <= 0 then werr = e or "short write"; break end
    off = off + n
  end
  if not werr and not paths.is_windows then pcall(uv.fs_fchmod, fd, tonumber("755", 8)) end
  if not werr then pcall(uv.fs_fsync, fd) end
  uv.fs_close(fd)
  if werr then return nil, "write " .. path .. ": " .. tostring(werr) end
  return true
end

--- Ensure the release executable `asset` of `version`, whose content hash is
--- `sha` (the pin's, mandatory), is in its slot, verified. A slot already
--- holding a matching regular file is reused without a download. Otherwise
--- the executable is downloaded from the fixed origin (or the user's mirror),
--- its hash checked before anything is written, written exclusively to this
--- process's temp file in `<data>/exe` and renamed into the slot. A slot file
--- whose hash does not match is unlinked by name and acquired again.
--- Returns the executable's path, or nil + err.
--- @param version string
--- @param asset string
--- @param sha string
--- @param opts? { on_fetch?: fun(), url?: string, pid?: integer, nonce?: string }
function M.ensure(version, asset, sha, opts)
  opts = opts or {}
  if not pin.valid_version(version) then
    return nil, "unsafe release version '" .. tostring(version) .. "'"
  end
  if not is_asset(asset) then return nil, "unknown host asset '" .. tostring(asset) .. "'" end
  if not is_sha(sha) then return nil, "no valid pinned sha256 for '" .. tostring(asset) .. "'" end
  local okd, ed = real_cache_dir(true)
  if not okd then return nil, ed end

  local state, why = slot_state(sha)
  if not state then return nil, why end
  if state == "ok" then return M.path(sha) end
  if state == "mismatch" then
    local okr, er = unlink_name(M.path(sha))
    if not okr then
      return nil, M.path(sha) .. " does not match its hash and cannot be removed (" .. tostring(er) ..
        "; is it running?)"
    end
  end

  if opts.on_fetch then opts.on_fetch() end
  local url = require("boot.update").versioned_base(version, opts) .. "/" .. asset
  local bytes, ferr = require("boot.download").fetch(url)
  if not bytes then return nil, "fetch " .. asset .. ": " .. tostring(ferr) end
  -- The mandatory, unconditional hash check, before anything is written.
  if tostring(verify.sha256_hex(bytes)):lower() ~= sha then
    return nil, "verify " .. asset .. ": sha256 mismatch (expected " .. sha .. ")"
  end

  local tmp = M.dir() .. "/" .. M.temp_name(sha, opts.pid or uv.os_getpid(), opts.nonce or nonce())
  local oku, eu = unlink_name(tmp)
  if not oku then return nil, "cannot use " .. tmp .. ": " .. tostring(eu) end
  local okw, ew = write_exclusive(tmp, bytes)
  if not okw then unlink_name(tmp); return nil, ew end

  local function install()
    local s, w = slot_state(sha)
    if not s then return nil, w end
    -- Another process finished first: never overwrite its (matching) file.
    if s == "ok" then return true end
    if s == "mismatch" then return nil, M.path(sha) .. " appeared with another hash" end
    if s == "absent" then
      local mok, merr = uv.fs_mkdir(M.slot(sha), tonumber("755", 8))
      if not mok then
        local st = uv.fs_lstat(M.slot(sha))
        if not st or st.type ~= "directory" then
          return nil, "cannot create " .. M.slot(sha) .. ": " .. tostring(merr)
        end
      end
    end
    -- POSIX: a hard link never replaces an existing name (a matching file
    -- another process placed meanwhile, perhaps running); a file system
    -- without hard links falls back to the rename. Windows: the rename (an
    -- executable in use there cannot be replaced anyway).
    if not paths.is_windows then
      local okl, el = uv.fs_link(tmp, M.path(sha))
      if okl then return true end
      if tostring(el):find("EEXIST", 1, true) then
        if slot_state(sha) == "ok" then return true end
        return nil, M.path(sha) .. " appeared meanwhile and does not match its hash"
      end
    end
    local okr, er = require("boot.update").rename_with_retry(tmp, M.path(sha))
    if okr then return true end
    if slot_state(sha) == "ok" then return true end
    return nil, er
  end
  local oki, ei = install()
  -- A concurrent cleanup may remove the (new, empty) slot between mkdir and
  -- rename: retry once.
  if not oki and tostring(ei):find("ENOENT", 1, true) then oki, ei = install() end
  unlink_name(tmp)
  if not oki then return nil, "activate " .. asset .. ": " .. tostring(ei) end
  -- What is on disk is what runs: verify it once more.
  local okv, ev = M.verify_before_run(sha)
  if not okv then return nil, "verify " .. asset .. ": " .. tostring(ev) end
  return M.path(sha)
end

return M
