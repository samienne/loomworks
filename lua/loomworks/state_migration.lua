--- loomworks/state_migration.lua — the one-time, automatic copy of a
--- working copy from `.nvim/` (releases before 0.2.0) into `.lw/`
--- (spec headless §16.44 *Migration from `.nvim/`*, formats §10).
---
--- Copy only: nothing under `.nvim/` is written, renamed or removed — except
--- the legacy operation lock this module itself creates exclusively while it
--- copies, which it removes again only while it still carries its own record
--- (nonce-checked; a lock that is not ours is never touched). A lock file
--- left by a dead older holder is not reclaimed: the copy then runs without
--- the legacy lock.
---
--- Deletion safety, under `.lw/`: the only file removed is a temporary copy,
--- `user.json.migrate-<hex>`, by that exact name (`^user%.json%.migrate%-%x+$`),
--- directly in `<root>/.lw`, which must be a real directory (lstat; never a
--- link or junction) whose realpath is the root's realpath + "/.lw"
--- (separator-bounded); the copy itself must be a regular file (lstat).
---
--- Crash safety: the marker `.lw/migrated.json` is written last (the commit
--- point). A run that finds `.lw/user.json` without a marker completes the
--- migration only when that file is byte-identical (sha256) to the legacy
--- working copy, else refuses saying what to do; a copy is never made over an
--- existing `.lw/user.json`. A temporary copy left by a failed unlink is
--- removed by a later run, or after the migration by `tidy`.

local M = {}

local state_dir = require("loomworks.state_dir")
local lock_record = require("loomworks.lock_record")

local function uv() return vim.uv or vim.loop end

local function norm(p) return (tostring(p):gsub("\\", "/"):gsub("/+$", "")) end

local IS_WINDOWS = (uv().os_uname().sysname or ""):find("Windows") ~= nil
local function cmp(p)
    p = norm(p)
    return IS_WINDOWS and p:lower() or p
end

--- The temporary copy's exact-name pattern.
M.TEMP_PATTERN = "^user%.json%.migrate%-%x+$"

--- The one-line report of a completed migration.
M.REPORT = "lw: this workspace's state is now in .lw/ (working copy copied from .nvim/, "
    .. "which is left as it was for older lw versions; builds now go to .lw/build/)"

--- The refusal when `.lw/user.json` exists without a marker and is not
--- byte-identical to `.nvim/loomworks.user.json`.
M.UNFINISHED = "lw: .lw/user.json exists but differs from .nvim/loomworks.user.json and the copy "
    .. "was never finished (no .lw/migrated.json): an interrupted copy, or a file put there by hand. "
    .. "To copy .nvim/loomworks.user.json anew, move .lw/user.json out of .lw/ and retry; to keep "
    .. ".lw/user.json instead, copy it over .nvim/loomworks.user.json and retry"

local function lstat_type(p)
    local st = uv().fs_lstat(p)
    return st and st.type or nil
end

local function read_bytes(p)
    local fd = uv().fs_open(p, "r", 438)
    if not fd then return nil end
    local st = uv().fs_fstat(fd)
    local data = st and uv().fs_read(fd, st.size, 0) or nil
    uv().fs_close(fd)
    return data
end

local function sha256(s) return vim.fn.sha256(s) end

--- `<root>/.lw` when it is a real directory (lstat) whose realpath is the
--- root's realpath + "/.lw"; nil otherwise.
local function verified_lw(root)
    local d = state_dir.dir(root)
    if lstat_type(d) ~= "directory" then return nil end
    local rr, rd = uv().fs_realpath(root), uv().fs_realpath(d)
    if not rr or not rd then return nil end
    if cmp(rd) ~= cmp(norm(rr) .. "/.lw") then return nil end
    return d
end

--- Remove a temporary copy `name` of `<root>/.lw` (exact name, regular file,
--- directly in a verified `.lw`). Returns true when removed.
local function remove_temp(root, name)
    if type(name) ~= "string" or not name:match(M.TEMP_PATTERN) then return false end
    local d = verified_lw(root)
    if not d then return false end
    local p = d .. "/" .. name
    -- Directly in `.lw` (separator-bounded), never a nested path.
    local prefix = cmp(d)
    local pc = cmp(p)
    if not (pc:sub(1, #prefix + 1) == prefix .. "/" and not pc:sub(#prefix + 2):find("/", 1, true)) then
        return false
    end
    if lstat_type(p) ~= "file" then return false end
    return uv().fs_unlink(p) == true
end

--- Leftover temporary copies of a crashed run (exact names only).
local function remove_leftover_temps(root)
    local d = verified_lw(root)
    if not d then return end
    local h = uv().fs_scandir(d)
    if not h then return end
    local found = {}
    while true do
        local name, t = uv().fs_scandir_next(h)
        if not name then break end
        if t == "file" and name:match(M.TEMP_PATTERN) then found[#found + 1] = name end
    end
    for _, n in ipairs(found) do remove_temp(root, n) end
end

--- After the migration (the marker present): remove a temporary copy a run
--- could not unlink. Safe without a lock: a run writes temporary copies only
--- before the marker exists and removes its own before writing the marker,
--- so one found beside the marker belongs to no running migration. Same
--- exact-name checks as during a run. Never raises.
--- @param root string
function M.tidy(root)
    pcall(function()
        root = norm(root)
        if lstat_type(state_dir.path(root, state_dir.MARKER)) ~= "file" then return end
        remove_leftover_temps(root)
    end)
end

--- The marker's state: "absent", "file" (parsed table or false when it does
--- not parse), or "other" (exists, not a regular file).
--- @return string kind, table|false|nil data
function M.read_marker(root)
    local p = state_dir.path(root, state_dir.MARKER)
    local t = lstat_type(p)
    if not t then return "absent" end
    if t ~= "file" then return "other" end
    local text = read_bytes(p)
    local ok, data = pcall(vim.json.decode, text or "")
    if ok and type(data) == "table" then return "file", data end
    return "file", false
end

--- The legacy working copy's path when it is a regular file (lstat).
--- @param root string
--- @return string|nil
function M.legacy_user(root)
    local p = state_dir.legacy(root, state_dir.LEGACY_USER)
    return lstat_type(p) == "file" and p or nil
end

--- The refusal (without the "lw: " prefix) of a host that must not load,
--- migrate or create workspace state because the repository pins a release
--- before `.lw/` (§16.23), set by main.lua; nil otherwise.
--- @return string|nil
function M.legacy_pin_refusal()
    local m = rawget(_G, "__loomworks_legacy_pin")
    if type(m) ~= "string" or m == "" then return nil end
    return (m:gsub("^lw: ", ""))
end

--- The pinned release before `.lw/` whose refusal `legacy_pin_refusal` is
--- (set by main.lua alongside it), or nil. `lw reset --state` deletes that
--- release's caches under their legacy names (§16.30, §16.44 *Deletion*).
--- @return string|nil
function M.legacy_pin_version()
    if not M.legacy_pin_refusal() then return nil end
    local v = rawget(_G, "__loomworks_legacy_pin_version")
    return type(v) == "string" and v ~= "" and v or nil
end

--- The one line `lw worktree add` prints instead of seeding the new worktree
--- under such a pin (set by main.lua), or nil when there is no such pin.
--- @return string|nil
function M.legacy_pin_pull_note()
    if not M.legacy_pin_refusal() then return nil end
    local m = rawget(_G, "__loomworks_legacy_pin_pull")
    if type(m) == "string" and m ~= "" then return m end
    return "pull skipped - the pinned lw keeps its state in .nvim/, which this lw does not write"
end

--- Is a migration (or its completion) pending for `root`? No `.lw` working
--- copy or marker, and a legacy working copy — or `.lw/user.json` without a
--- marker beside a legacy working copy (an interrupted run).
--- @param root string
--- @return boolean
function M.pending(root)
    root = norm(root)
    if lstat_type(state_dir.path(root, state_dir.MARKER)) then return false end
    return M.legacy_user(root) ~= nil
end

--- The live (or hung) holders of the legacy locks: every
--- `.nvim/loomworks.daemon-<S>.lock`, the pre-slot `.nvim/loomworks.daemon.lock`
--- and `.nvim/loomworks.op.lock`. Read only.
--- @param root string
--- @return table[] list of lock infos (with `path`, `state`)
function M.legacy_holders(root)
    root = norm(root)
    local dir = root .. "/" .. state_dir.LEGACY_DIR
    local names = {}
    local h = uv().fs_scandir(dir)
    if h then
        while true do
            local name = uv().fs_scandir_next(h)
            if not name then break end
            if name:match("^loomworks%.daemon%-%x+%.lock$") or name == "loomworks.daemon.lock"
                or name == "loomworks.op.lock" then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    local out = {}
    local stale = require("loomworks.build_lock").STALE_SECONDS or 300
    for _, n in ipairs(names) do
        local p = dir .. "/" .. n
        if lstat_type(p) == "file" then
            local info = lock_record.read(p, stale)
            if info then
                info.state = lock_record.classify(info)
                if info.state == "live" or info.state == "hung" then
                    info.path = p
                    out[#out + 1] = info
                end
            end
        end
    end
    return out
end

--- The refusal naming an older lw at work in `.nvim/`.
--- @param info table
--- @return string
function M.busy_message(info)
    local who = "lw"
    if type(info.version) == "string" then who = "lw " .. info.version
    elseif type(info.written_by) == "string" then who = "lw " .. info.written_by end
    if info.kind == "daemon" or (info.path or ""):find("daemon", 1, true) then who = who .. " daemon" end
    local where = {}
    if info.pid then where[#where + 1] = "pid " .. tostring(info.pid) end
    if info.host then where[#where + 1] = "on " .. tostring(info.host) end
    local holder = who .. (#where > 0 and (" (" .. table.concat(where, " ") .. ")") or "")
    return holder .. " is using this workspace's .nvim/ state — stop it or let it finish, then retry"
        .. (info.state == "hung" and " (it has stopped updating its lock: if it is gone, `lw daemon stop` or ending that process frees it)" or "")
end

local function write_marker(root, source_sha, version)
    local body = vim.json.encode({
        from = state_dir.LEGACY_USER,
        source_sha256 = source_sha,
        written_by = version,
        migrated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }) .. "\n"
    return require("loomworks.io").write_file_atomic(state_dir.path(root, state_dir.MARKER), body, { backup = false })
end

local function version()
    local ok, v = pcall(function() return require("loomworks.save_guard").version() end)
    return ok and v or "unknown"
end

--- Take the legacy operation lock exclusively (never reclaiming another's).
--- Returns a release function, or nil + the live holder's info, or
--- nil when it could not be taken for another reason (proceed without it).
local function take_legacy_op(root)
    local p = state_dir.legacy(root, state_dir.LEGACY_OP_LOCK)
    local dir = state_dir.legacy(root, state_dir.LEGACY_DIR)
    if lstat_type(dir) ~= "directory" then return function() end end
    local rec = lock_record.new("migrate")
    local ok, _, code = lock_record.create(p, rec)
    if ok then
        return function()
            -- Only our own lock file, still carrying our record.
            if lstat_type(p) == "file" and lock_record.still_ours(p, rec) then
                pcall(uv().fs_unlink, p)
            end
        end
    end
    if code == "EEXIST" then
        local info = lock_record.read(p, require("loomworks.build_lock").STALE_SECONDS or 300)
        if info then
            info.state = lock_record.classify(info)
            if info.state == "live" or info.state == "hung" then
                info.path = p
                return nil, info
            end
        end
    end
    return function() end
end

--- Migrate `root` when pending. Returns:
---   nil                       nothing to do (or done before)
---   "migrated", report_line    the copy was made now
---   "completed"                an interrupted run was completed
---   "refused", message         the command must stop with `message`
--- `opts.op_lock` (tests) replaces loomworks.op_lock.
--- @param root string
--- @param opts? { op_lock?: table }
--- @return string|nil status, string|nil message
function M.run(root, opts)
    opts = opts or {}
    root = norm(root)
    local marker_kind = M.read_marker(root)
    if marker_kind == "other" then
        return "refused", "lw: .lw/migrated.json is not a regular file — remove it, then retry"
    end
    if marker_kind == "file" then return nil end
    local legacy = M.legacy_user(root)
    if not legacy then return nil end

    -- 1. An older lw at work in `.nvim/`.
    local busy = M.legacy_holders(root)
    if #busy > 0 then return "refused", "lw: " .. M.busy_message(busy[1]) end

    -- 2. Exclusion: `.lw/op.lock`, then the legacy one; re-check under them.
    local dir, derr = state_dir.ensure(root)
    if not dir then return "refused", "lw: cannot create .lw/ (" .. tostring(derr) .. ")" end
    if not verified_lw(root) then
        return "refused", "lw: " .. dir .. " is not a real directory of the workspace (a link or junction?) — "
            .. "replace it with a directory, then retry"
    end
    local op_lock = opts.op_lock or require("loomworks.op_lock")
    local tok, msg
    local deadline = uv().hrtime() + 5e9
    repeat
        tok, msg = op_lock.acquire(root, "migrate", { no_recover = true })
        if tok then break end
        vim.wait(50)
    until uv().hrtime() > deadline
    if not tok then return "refused", "lw: " .. tostring(msg) end
    local release_legacy, holder = take_legacy_op(root)
    if not release_legacy then
        op_lock.release(tok)
        return "refused", "lw: " .. M.busy_message(holder)
    end
    local function done(...)
        release_legacy()
        op_lock.release(tok)
        return ...
    end

    marker_kind = M.read_marker(root)
    if marker_kind == "other" then
        return done("refused", "lw: .lw/migrated.json is not a regular file — remove it, then retry")
    end
    if marker_kind == "file" then return done(nil) end
    legacy = M.legacy_user(root)
    if not legacy then return done(nil) end
    busy = M.legacy_holders(root)
    for _, b in ipairs(busy) do
        -- (our own legacy operation lock is not a holder)
        if not lock_record.same_host(b) or b.pid ~= lock_record.this_pid() then
            return done("refused", "lw: " .. M.busy_message(b))
        end
    end

    -- 3. An interrupted legacy commit: left to the older lw that wrote it.
    if lstat_type(state_dir.legacy(root, state_dir.LEGACY_TXN)) then
        return done("refused", "lw: an older lw left an unfinished commit in .nvim/ (.nvim/loomworks.txn.json) — "
            .. "run that older lw once in this workspace so it completes it, then retry")
    end

    remove_leftover_temps(root)

    -- An interrupted run: `.lw/user.json` exists without a marker. Complete
    -- it only when it is byte-identical to the legacy working copy (a copy
    -- that was made in full); anything else — a partial copy of the
    -- non-atomic fallback, or a file put there by hand — is refused, saying
    -- what to do. Never copied over.
    local target = state_dir.path(root, "user.json")
    local tt = lstat_type(target)
    if tt then
        if tt ~= "file" then
            return done("refused", "lw: .lw/user.json is not a regular file — remove it, then retry")
        end
        local bytes = read_bytes(target)
        if not bytes then return done("refused", "lw: cannot read .lw/user.json") end
        local lbytes = read_bytes(legacy)
        if not lbytes then return done("refused", "lw: cannot read " .. legacy) end
        local have, want = sha256(bytes), sha256(lbytes)
        if have ~= want then
            return done("refused", M.UNFINISHED)
        end
        local ok, err = write_marker(root, have, version())
        if not ok then return done("refused", "lw: cannot write .lw/migrated.json (" .. tostring(err) .. ")") end
        return done("completed")
    end

    -- 4. Copy byte for byte through a temporary name, verified, then
    -- create-if-absent under the final name.
    local bytes = read_bytes(legacy)
    if not bytes then return done("refused", "lw: cannot read " .. legacy) end
    local want = sha256(bytes)
    local tmp_name = "user.json.migrate-" .. lock_record.new_nonce():gsub("[^%x]", "")
    if not tmp_name:match(M.TEMP_PATTERN) then tmp_name = "user.json.migrate-" .. string.format("%08x", os.time()) end
    local tmp = dir .. "/" .. tmp_name
    local io_mod = require("loomworks.io")
    local okw, werr = io_mod.write_exclusive(tmp, bytes, 438)
    if not okw then return done("refused", "lw: cannot write " .. tmp .. " (" .. tostring(werr) .. ")") end
    local back = read_bytes(tmp)
    if not back or sha256(back) ~= want then
        remove_temp(root, tmp_name)
        return done("refused", "lw: the copy of .nvim/loomworks.user.json did not verify — retry")
    end
    local linked, _, lcode = uv().fs_link(tmp, target)
    if not linked then
        if lcode == "EEXIST" then
            remove_temp(root, tmp_name)
            return done("refused", "lw: .lw/user.json appeared while copying — retry")
        end
        -- No hard links here: an exclusive create of the final name.
        -- Not atomic: a crash can leave a partial file, which the next run
        -- refuses (it differs from the legacy copy) instead of accepting.
        local okc, cerr, ccode = io_mod.write_exclusive(target, bytes, 438)
        if not okc then
            remove_temp(root, tmp_name)
            if ccode == "EEXIST" then return done("refused", "lw: .lw/user.json appeared while copying — retry") end
            return done("refused", "lw: cannot write .lw/user.json (" .. tostring(cerr) .. ")")
        end
        local wrote = read_bytes(target)
        if not wrote or sha256(wrote) ~= want then
            remove_temp(root, tmp_name)
            return done("refused", M.UNFINISHED)
        end
    end
    remove_temp(root, tmp_name)

    -- 5. Commit point.
    local okm, merr = write_marker(root, want, version())
    if not okm then return done("refused", "lw: cannot write .lw/migrated.json (" .. tostring(merr) .. ")") end
    -- 6. Report.
    return done("migrated", M.REPORT)
end

--- The divergence (health): the legacy working copy changed after it was
--- copied. Returns the finding's message, or nil.
--- @param root string
--- @return string|nil
function M.divergence(root)
    root = norm(root)
    local kind, data = M.read_marker(root)
    if kind ~= "file" or type(data) ~= "table" or type(data.source_sha256) ~= "string" then return nil end
    local legacy = M.legacy_user(root)
    if not legacy then return nil end
    local bytes = read_bytes(legacy)
    if not bytes or sha256(bytes) == data.source_sha256 then return nil end
    return ".nvim/loomworks.user.json changed after it was copied to .lw/ (an older lw ran here); "
        .. "lw 0.2.0 and later keep using .lw/user.json. To take the older copy instead, stop the "
        .. "older lw, move .lw/user.json and .lw/migrated.json out of .lw/, and run lw again: "
        .. "it copies .nvim/loomworks.user.json anew"
end

return M
