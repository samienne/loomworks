--- A load superseded by `shutdown` (and a later load of another workspace)
--- must not be applied when its file read completes late.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

local USER = "/.nvim/loomworks.user.json"

local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local function write(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

describe("a superseded workspace load", function()
    after_each(function()
        require("loomworks.app").core():shutdown()
        trust._set_key_path(nil)
    end)

    it("still reading when the core shuts down is not applied to the next workspace", function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        local root_a = H.shell_workspace({ profile = true })
        local root_b = H.shell_workspace({ profile = true })
        local handlers = { notify = function() end, refused = function() end, written = function() end,
            files_changed = function() end }
        local ws_a = assert(cli._load_workspace_soft(root_a, false, { handlers = handlers }))

        -- A's working copy no longer verifies: the tracker reloads A, whose
        -- read is still in flight when the core shuts down and B loads.
        local text = read(root_a .. USER)
        write(root_a .. USER, (text:gsub('"_sig": "%x+"', '"_sig": "' .. string.rep("0", 64) .. '"', 1)))
        ws_a._tracker:sync()
        local core = require("loomworks.app").core()
        core:shutdown()

        local ws_b, _, fail = cli._load_workspace_soft(root_b, false, { handlers = handlers })
        assert.is_not_nil(ws_b, "load of B refused: " .. vim.inspect(fail and fail.trust and fail.trust.path))
        assert.equals(root_b, ws_b.root)
        vim.wait(500)
        assert.equals(ws_b, core:get_workspace())
        assert.is_nil(core._setup_error)
    end)
end)
