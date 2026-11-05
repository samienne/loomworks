--- loomworks/host_env.lua — the host-internal values (spec §16.22 "Host-internal
--- values"): the pinned-context marker (`LOOMWORKS_PINNED`) and the workspace
--- root a launcher or a forwarding host passes (`LW_ROOT`).
---
--- The luvi host (main.lua) reads both once at startup, keeps them in
--- `_G.__loomworks_host_env` and removes them from its environment, so
--- nothing it starts (a build, run or test step; a request's environment)
--- inherits them. Code that needs them reads them here, never from the
--- environment. Without that state — the nvim-hosted CLI, or this code run by
--- an older host through a transitional bundle — the environment still holds
--- them, and is read instead.

local M = {}

local KEPT = { LOOMWORKS_PINNED = "pinned", LW_ROOT = "root" }

--- `os.getenv`, except that the host-internal values come from the host's
--- kept state when there is one.
--- @param name string
--- @return string|nil
function M.getenv(name)
  local field = KEPT[name]
  if field then
    local s = rawget(_G, "__loomworks_host_env")
    if type(s) == "table" then return s[field] end
  end
  return os.getenv(name)
end

--- The pinned-context marker (the pinned version), or nil.
--- @return string|nil
function M.pinned() return M.getenv("LOOMWORKS_PINNED") end

--- The workspace root passed by a launcher or a forwarding host, or nil.
--- @return string|nil
function M.root() return M.getenv("LW_ROOT") end

return M
