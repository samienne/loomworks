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
    local core, read_files_async

    before_each(function()
        core = require("loomworks.app").core()
        read_files_async = rawget(core._deps, "read_files_async")
    end)

    after_each(function()
        rawset(core._deps, "read_files_async", read_files_async)
        core:shutdown()
        trust._set_key_path(nil)
    end)

    it("still reading when the core shuts down is not applied to the next workspace", function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        local root_a = H.shell_workspace({ profile = true })
        local root_b = H.shell_workspace({ profile = true })
        local handlers = { notify = function() end, refused = function() end, written = function() end,
            files_changed = function() end }
        local ws_a = assert(cli._load_workspace_soft(root_a, false, { handlers = handlers }))

        -- The next read (A's reload) is held back until B is loaded.
        local read_files = core._deps.read_files_async
        local held
        core._deps.read_files_async = function(paths, callback)
            if held then return read_files(paths, callback) end
            held = { paths = paths, callback = callback }
        end

        -- A's working copy no longer verifies: the tracker reloads A.
        local text = read(root_a .. USER)
        write(root_a .. USER, (text:gsub('"_sig": "%x+"', '"_sig": "' .. string.rep("0", 64) .. '"', 1)))
        ws_a._tracker:sync()
        assert.is_not_nil(held, "the tracker did not reload A")
        core:shutdown()

        local ws_b, _, fail = cli._load_workspace_soft(root_b, false, { handlers = handlers })
        assert.is_not_nil(ws_b, "load of B refused: " .. vim.inspect(fail and fail.trust and fail.trust.path))

        -- Complete A's read, then run what it scheduled.
        local delivered = false
        read_files(held.paths, function(results)
            held.callback(results)
            delivered = true
        end)
        assert.is_true(vim.wait(10000, function() return delivered end, 10), "A's read never completed")
        local flushed = false
        vim.schedule(function() flushed = true end)
        assert.is_true(vim.wait(10000, function() return flushed end, 10))

        assert.equals(ws_b, core:get_workspace())
        assert.is_nil(core._setup_error)
    end)
end)
