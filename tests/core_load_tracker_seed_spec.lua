--- A write that lands after the load read a workspace file, but before the
--- load starts tracking it, must reach the model on the next sync.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

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

describe("a write between the load's read and its tracking", function()
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

    local function load_with_late_write(root, late)
        local read_files = core._deps.read_files_async
        core._deps.read_files_async = function(list, callback)
            return read_files(list, function(results)
                late()
                callback(results)
            end)
        end
        local handlers = { notify = function() end, refused = function() end, written = function() end,
            files_changed = function() end }
        local ws = cli._load_workspace_soft(root, false, { handlers = handlers })
        assert.is_not_nil(ws, "the load failed")
        rawset(core._deps, "read_files_async", read_files_async)
        return ws
    end

    it("to the working copy is applied by the next sync", function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        local root = H.shell_workspace({ profile = true })
        local user = root .. "/.nvim/loomworks.user.json"
        local old_user = read(user)
        local new_user = trust.sign("user", trust.encode({ _meta = { version = 2 }, debug = { adapters = { ["c++"] = "cppdbg" } },
            profiles = { dev = { configuration_set = "dev" } } }))
        assert.is_string(new_user)

        local ws = load_with_late_write(root, function() write(user, new_user) end)
        assert.equals(old_user, ws._disk_baseline.user.text)
        assert.is_nil(ws._debug_settings)

        ws:sync_light()
        assert.same({ adapters = { ["c++"] = "cppdbg" } }, ws._debug_settings,
            "the working copy written after the load's read was lost")
        assert.equals(new_user, ws._tracker:content(user))
    end)

    it("to loomworks.json or the cache leaves the tracker at the bytes the load read", function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        local root = H.shell_workspace({ profile = true })
        local config, cache = root .. "/loomworks.json", root .. "/.nvim/loomworks.cache.json"
        local old_config = read(config)

        local ws = load_with_late_write(root, function()
            write(config, old_config .. "\n")
            write(cache, "{}")
        end)
        assert.equals(old_config, ws._tracker:content(config))
        -- (The cache did not exist when the load read it.)
        assert.is_nil(ws._tracker:content(cache))
    end)
end)
