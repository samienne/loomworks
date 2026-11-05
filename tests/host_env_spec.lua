-- Host-internal values (spec §16.22): the pinned-context marker and the
-- forwarded workspace root are read from the luvi host's kept state, never
-- from the environment it cleared; without that state (the nvim-hosted CLI,
-- or an older host running this code through a transitional bundle) from the
-- environment. A daemon this process starts gets them explicitly.

local host_env = require("loomworks.host_env")
local launch = require("loomworks.daemon.launch")

local function with_state(state, fn)
    local saved = rawget(_G, "__loomworks_host_env")
    local saved_pinned, saved_root = vim.env.LOOMWORKS_PINNED, vim.env.LW_ROOT
    _G.__loomworks_host_env = state
    local ok, err = pcall(fn)
    _G.__loomworks_host_env = saved
    vim.env.LOOMWORKS_PINNED, vim.env.LW_ROOT = saved_pinned, saved_root
    if not ok then error(err, 0) end
end

local function entry(env, name)
    for _, kv in ipairs(env) do
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k and k:upper() == name then return v end
    end
    return nil
end

describe("host_env", function()
    it("reads the host's kept values, never the environment, when the host kept them", function()
        with_state({ pinned = "1.2.3", root = "/w" }, function()
            vim.env.LOOMWORKS_PINNED, vim.env.LW_ROOT = "9.9.9", "/elsewhere"
            assert.equals("1.2.3", host_env.pinned())
            assert.equals("/w", host_env.root())
            assert.equals("1.2.3", host_env.getenv("LOOMWORKS_PINNED"))
        end)
        with_state({}, function()
            vim.env.LOOMWORKS_PINNED, vim.env.LW_ROOT = "9.9.9", "/elsewhere"
            assert.is_nil(host_env.pinned())
            assert.is_nil(host_env.root())
        end)
    end)

    it("falls back to the environment without host state (nvim-hosted, older host)", function()
        with_state(nil, function()
            vim.env.LOOMWORKS_PINNED, vim.env.LW_ROOT = "0.1.40", "/repo"
            assert.equals("0.1.40", host_env.pinned())
            assert.equals("/repo", host_env.root())
            vim.env.LOOMWORKS_PINNED, vim.env.LW_ROOT = nil, nil
            assert.is_nil(host_env.pinned())
            assert.is_nil(host_env.root())
        end)
    end)

    it("passes other variables through", function()
        with_state({ pinned = "1.2.3" }, function()
            assert.equals(os.getenv("PATH"), host_env.getenv("PATH"))
        end)
    end)
end)

describe("daemon launch environment", function()
    it("passes the pinned marker and the root explicitly in a pinned context", function()
        with_state({ pinned = "1.2.3", root = "/user/cwd" }, function()
            vim.env.LOOMWORKS_PINNED, vim.env.LW_ROOT = nil, nil
            local env = launch.env("/ws")
            assert.equals("1.2.3", entry(env, "LOOMWORKS_PINNED"))
            assert.equals("/ws", entry(env, "LW_ROOT"))
        end)
    end)

    it("carries no pinned marker outside a pinned context", function()
        with_state({ root = "/user/cwd" }, function()
            vim.env.LOOMWORKS_PINNED = nil
            local env = launch.env("/ws")
            assert.is_nil(entry(env, "LOOMWORKS_PINNED"))
            assert.equals("/ws", entry(env, "LW_ROOT"))
        end)
    end)
end)
