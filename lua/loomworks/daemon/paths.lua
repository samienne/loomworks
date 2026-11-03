--- loomworks/daemon/paths.lua — where the workspace runtime's files live.
---
---   <root>/.nvim/loomworks.daemon-<S>.lock   the runtime lock R
---   <root>/.nvim/loomworks.daemon-<S>.json   the handle: discovery only
---   <root>/.nvim/loomworks.daemon-<S>.log    the runtime log
---   <root>/.nvim/loomworks.daemon.{lock,json,log}  the legacy (unslotted)
---                                        names of lw before slots
---                                        (daemon.legacy)
---   <state>/                             the per-user state directory: the
---                                        daemon's working directory
---   <state>/logs/                        where earlier versions kept the
---                                        runtime logs (legacy)
---
--- `<S>` is this process's slot token (loomworks.daemon.identity):
--- the slot's files only; another slot's are never named here. A process
--- whose slot cannot be determined gets an error, never a shared name.
---
--- `<state>` is `<data dir>/daemon`, the per-user data directory of the `lw`
--- host (boot.paths: %LOCALAPPDATA%\loomworks, $XDG_DATA_HOME/loomworks or
--- ~/.local/share/loomworks; LOOMWORKS_DATA_DIR overrides it).
---
--- Pure path arithmetic; nothing here creates a file.

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

--- A workspace root as the runtime files name it: forward slashes, no
--- trailing slash.
--- @param root string
--- @return string
function M.norm_root(root)
    return (tostring(root):gsub("\\", "/"):gsub("/+$", ""))
end

--- The root as hashed for per-user names: its real path (so a client that
--- reached the workspace through an 8.3 short name, a junction or a symlink
--- names the same files as the daemon), case-folded on Windows, whose
--- filesystems are case-insensitive.
--- @param root string
--- @return string
local function hash_key(root)
    local uv = vim.uv or vim.loop
    local ok, real = pcall(uv.fs_realpath, M.norm_root(root))
    local r = M.norm_root((ok and type(real) == "string") and real or root)
    if is_win() then r = r:lower() end
    return r
end

--- A short hex hash of a string (first 16 hex digits of its SHA-256).
--- @param s string
--- @return string
function M.short_hash(s)
    return vim.fn.sha256(s):sub(1, 16)
end

--- The short hash naming a workspace's per-user files (the POSIX socket;
--- earlier versions also named the runtime log by it).
--- @param root string
--- @return string
function M.root_hash(root)
    return M.short_hash(hash_key(root))
end

--- The base name of this slot's runtime files: `loomworks.daemon-<S>`.
--- @return string
function M.slot_base()
    return "loomworks.daemon-" .. require("loomworks.daemon.identity").slot()
end

--- The runtime lock of this process's slot.
--- @param root string
--- @return string
function M.lock_path(root)
    return M.norm_root(root) .. "/.nvim/" .. M.slot_base() .. ".lock"
end

--- The handle of this process's slot.
--- @param root string
--- @return string
function M.handle_path(root)
    return M.norm_root(root) .. "/.nvim/" .. M.slot_base() .. ".json"
end

--- The legacy (unslotted) file names in `<root>/.nvim/`: never read to
--- connect to a daemon.
M.LEGACY = {
    lock = "loomworks.daemon.lock",
    handle = "loomworks.daemon.json",
    log = "loomworks.daemon.log",
    log1 = "loomworks.daemon.log.1",
}

--- The per-user data directory (shared with the trust key).
--- @return string
function M.data_dir()
    return require("loomworks.trust").data_dir()
end

--- The per-user state directory of the workspace runtime.
--- @return string
function M.state_dir()
    return M.data_dir() .. "/daemon"
end

--- The runtime log of a workspace for this process's slot: inside
--- the workspace, beside the runtime lock and the handle.
--- @param root string
--- @return string
function M.log_path(root)
    return M.norm_root(root) .. "/.nvim/" .. M.slot_base() .. ".log"
end

--- Where earlier versions kept the runtime logs (`<hash>.log`), now
--- only a source of leftovers for housekeeping.
--- @return string
function M.legacy_log_dir()
    return M.state_dir() .. "/logs"
end

M._hash_key = hash_key

return M
