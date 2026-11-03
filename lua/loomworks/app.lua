--- loomworks/app.lua — the lw process's Core.
---
--- One Core per lw process (a CLI command or the workspace daemon), created
--- on first require. The CLI and the daemon load the workspace through it;
--- tests reach it to inspect or reset that state.

local M = {}

--- @type loomworks.Core
local core = require("loomworks.core").new()

--- The process's Core.
--- @return loomworks.Core
function M.core()
    return core
end

--- The workspace the process has loaded, or nil.
--- @return loomworks.Workspace|nil
function M.get_workspace()
    return core:get_workspace()
end

return M
