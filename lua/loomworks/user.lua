local notify = require("loomworks.notify").notify
local M = {}

local io_mod = require("loomworks.io")

local CURRENT_VERSION = 2
--- The working-copy schema this version reads and writes (`_meta.version`).
M.CURRENT_VERSION = CURRENT_VERSION

--- Return the file path for a workspace root.
--- @param root string
--- @return string
function M.filepath(root)
    return root .. "/.lw/user.json"
end

--- The working copy to READ from a source checkout that is not loaded (a pull
--- or worktree seed, §16.25): `.lw/user.json`, or, while the source is not
--- migrated (neither that file nor the marker exists), the legacy
--- `.nvim/loomworks.user.json` of a release before 0.2.0. The source is
--- never migrated by this (§16.44).
--- @param root string
--- @return string
function M.source_filepath(root)
    local uv = vim.uv or vim.loop
    local p = M.filepath(root)
    if uv.fs_stat(p) or uv.fs_lstat(root .. "/.lw/migrated.json") then return p end
    local legacy = root .. "/.nvim/loomworks.user.json"
    local st = uv.fs_lstat(legacy)
    if st and st.type == "file" then return legacy end
    return p
end

--- Return a default (empty) UserData structure.
--- @return loomworks.UserData
function M.default()
    return { _meta = { version = CURRENT_VERSION } }
end

--- Migrate v1 user data to v2 format.
--- Converts active_profile string key to structural active selection.
--- @param raw table raw v1 data
--- @return table migrated v2 data
local function migrate_v1(raw)
    local data = { _meta = { version = CURRENT_VERSION } }
    if raw.active_profile then
        data.active_profile = raw.active_profile
    end
    if raw.default_target then
        data.default_target = raw.default_target
    end
    if raw.projects then data.projects = raw.projects end
    if raw.configuration_sets then data.configuration_sets = raw.configuration_sets end
    return data
end

--- Parse raw JSON content into UserData.
--- Returns defaults on invalid content. Second return value is true when a
--- version mismatch was detected (valid JSON but unsupported version).
--- Accepts v1 and v2 formats (v1 is auto-migrated). The third return value
--- is the file's `_meta` when the mismatch is a NEWER schema than this version
--- understands (such a file is never rewritten).
--- @param content string raw JSON content
--- @return loomworks.UserData data, boolean version_mismatch, table|nil newer_meta
function M.parse(content)
    local ok, raw = pcall(vim.json.decode, content)
    if not ok or type(raw) ~= "table" then
        return M.default(), false
    end
    if not raw._meta then
        return M.default(), true
    end
    if require("loomworks.save_guard").schema_newer(raw._meta, CURRENT_VERSION) then
        return M.default(), true, raw._meta
    end
    if raw._meta.version == 1 then
        return migrate_v1(raw), false
    end
    if raw._meta.version ~= CURRENT_VERSION then
        return M.default(), true
    end
    -- back-compat: pinned_profiles was renamed to profiles
    if raw.pinned_profiles and not raw.profiles then
        raw.profiles = raw.pinned_profiles
        raw.pinned_profiles = nil
    end
    return raw, false
end

--- Load user preferences for a workspace.
--- Returns defaults if file doesn't exist. A working copy that is not signed
--- by this machine is never read: it returns nil plus the
--- verification status (`"unsigned"` / `"invalid"`). One written with a newer
--- schema than this version understands returns nil, `"newer"` and the
--- message — never defaults, which a caller could write back.
--- `opts.source`: read a source checkout's working copy (`source_filepath`).
--- @param root string
--- @param opts? { source?: boolean }
--- @return loomworks.UserData|nil data, string|nil trust_status, string|nil message
function M.load(root, opts)
    local path = (opts and opts.source) and M.source_filepath(root) or M.filepath(root)
    local text = io_mod.read_file(path)
    if not text then
        return M.default()
    end
    local status, body = require("loomworks.trust").verify("user", text)
    if status ~= "valid" then
        return nil, status
    end
    local ok, data = pcall(vim.json.decode, body)
    if not ok or type(data) ~= "table" then
        return M.default()
    end

    if not data._meta then
        notify("loomworks: user.json has unexpected version, using defaults", vim.log.levels.WARN)
        return M.default()
    end

    local sg = require("loomworks.save_guard")
    if sg.schema_newer(data._meta, CURRENT_VERSION) then
        return nil, "newer", sg.newer_schema_message(path, data._meta, CURRENT_VERSION)
    end

    if data._meta.version == 1 then
        return migrate_v1(data)
    end

    if data._meta.version ~= CURRENT_VERSION then
        notify("loomworks: user.json has unexpected version, using defaults", vim.log.levels.WARN)
        return M.default()
    end

    return data
end

--- Save user preferences for a workspace. Stamps the schema and the writer's
--- loomworks version (`_meta.written_by`, inside the signed bytes).
--- @param root string
--- @param data loomworks.UserData
--- @return boolean ok, string|nil err, string|nil sign_err, string|nil written exact bytes written
function M.save(root, data)
    data._meta = { version = CURRENT_VERSION, written_by = require("loomworks.save_guard").version() }

    local dir = root .. "/.lw"
    local ok, dir_err = io_mod.ensure_dir(dir)
    if not ok then return false, "mkdir: " .. (dir_err or "unknown") end
    require("loomworks.state_dir").ensure_ignore(root)

    -- Signed with the machine key: only a signed working copy is
    -- ever used, so every loomworks write signs it.
    return io_mod.write_json_signed(M.filepath(root), "user", data)
end

return M
