--- loomworks/state_dir.lua — the workspace state directory `<root>/.lw/`
--- (spec headless §16.44).
---
--- Everything lw keeps for one workspace lives in `<root>/.lw/` under
--- unprefixed names. Releases before 0.2.0 kept it in `<root>/.nvim/` under
--- `loomworks.`-prefixed names (the LEGACY_* names below): a 0.2.0+ host
--- reads those only to migrate (loomworks.state_migration) and to report
--- (health), and never writes or removes anything there.
---
--- Self-ignore: whenever lw creates `.lw/`, and whenever it finds `.lw/`
--- without one, it writes `.lw/.gitignore` holding a comment and `*`, created
--- exclusively (never rewritten, never through a link).

local M = {}

local function uv() return vim.uv or vim.loop end

--- The state directory's name, relative to the workspace root.
M.DIR = ".lw"
--- Where releases before 0.2.0 kept the state.
M.LEGACY_DIR = ".nvim"

--- The working copy's legacy path (relative to the root).
M.LEGACY_USER = ".nvim/loomworks.user.json"
--- The legacy workspace operation lock (relative to the root).
M.LEGACY_OP_LOCK = ".nvim/loomworks.op.lock"
--- The legacy commit journal (relative to the root).
M.LEGACY_TXN = ".nvim/loomworks.txn.json"
--- The legacy default build root (relative to the root).
M.LEGACY_BUILD = ".nvim/build"

--- The migration marker's name in `.lw/` (formats §10).
M.MARKER = "migrated.json"

--- The self-ignore file's exact content.
M.GITIGNORE = "# lw workspace state, machine-local: ignore everything here\n*\n"

local function norm_root(root)
    return (tostring(root):gsub("\\", "/"):gsub("/+$", ""))
end

--- `<root>/.lw`.
--- @param root string
--- @return string
function M.dir(root)
    return norm_root(root) .. "/" .. M.DIR
end

--- `<root>/.lw/<name>`.
--- @param root string
--- @param name string
--- @return string
function M.path(root, name)
    return M.dir(root) .. "/" .. name
end

--- `<root>/.nvim/…` for a legacy relative path such as M.LEGACY_USER.
--- @param root string
--- @param rel string
--- @return string
function M.legacy(root, rel)
    return norm_root(root) .. "/" .. rel
end

--- Write `.lw/.gitignore` when `.lw` is a real directory (lstat; never a link
--- or junction) without one. Created exclusively: an existing file — or
--- anything else at that name — is never rewritten. Returns true when the
--- file was written now.
--- @param root string
--- @return boolean written
function M.ensure_ignore(root)
    local dir = M.dir(root)
    local st = uv().fs_lstat(dir)
    if not st or st.type ~= "directory" then return false end
    local path = dir .. "/.gitignore"
    if uv().fs_lstat(path) then return false end
    local fd = uv().fs_open(path, "wx", 420)
    if not fd then return false end
    pcall(uv().fs_write, fd, M.GITIGNORE, 0)
    pcall(uv().fs_close, fd)
    return true
end

--- Ensure `<root>/.lw` exists (only when the root itself exists: the root is
--- never created) and carries its self-ignore file. Returns the directory, or
--- nil + error.
--- @param root string
--- @return string|nil dir, string|nil err
function M.ensure(root)
    local r = norm_root(root)
    local rst = uv().fs_stat(r)
    if not rst or rst.type ~= "directory" then return nil, "no such directory: " .. r end
    local dir = M.dir(r)
    if not uv().fs_lstat(dir) then
        pcall(uv().fs_mkdir, dir, tonumber("755", 8))
    end
    local st = uv().fs_stat(dir)
    if not st or st.type ~= "directory" then return nil, "cannot create " .. dir end
    M.ensure_ignore(r)
    return dir
end

return M
