--- Tests for the standalone shim's `vim.fn.system` (lua/loomworks/shim/init.lua):
--- like Neovim's, its result carries the child's stderr along with its stdout
--- (#197), and it sets `vim.v.shell_error` to the exit code.
---
--- The shim installs itself onto `_G.vim`, so it is loaded here onto a fresh
--- table (with nvim's libuv as its `uv`) and `_G.vim` is restored at once.

local function load_shim()
    local real_vim = _G.vim
    -- Resolve what the shim requires while the real `vim` (whose module
    -- loader they need) is in place.
    require("loomworks.shim.json")
    require("loomworks.exe")
    local path = real_vim.api.nvim_get_runtime_file("lua/loomworks/shim/init.lua", false)[1]
    local saved_uv = package.loaded.uv
    package.loaded.uv = real_vim.uv
    _G.vim = {}
    local ok, shim = pcall(dofile, path)
    _G.vim = real_vim
    package.loaded.uv = saved_uv
    assert(ok, shim)
    return shim
end

--- A Lua script that writes `out` to stdout, `err` to stderr, and exits `code`.
local function script(out, err, code)
    local path = vim.fn.tempname() .. ".lua"
    local f = assert(io.open(path, "wb"))
    f:write(("io.stdout:write(%q) io.stdout:flush() io.stderr:write(%q) io.stderr:flush() os.exit(%d)")
        :format(out, err, code))
    f:close()
    return path
end

describe("shim vim.fn.system", function()
    local shim
    local nvim = vim.v.progpath
    before_each(function() shim = shim or load_shim() end)

    it("returns the child's stderr along with its stdout, as Neovim does (#197)", function()
        local s = script("to-stdout\n", "to-stderr\n", 0)
        local got = shim.fn.system({ nvim, "--clean", "-l", s })
        os.remove(s)
        assert.equals(0, shim.v.shell_error)
        assert.truthy(got:find("to-stdout", 1, true), got)
        assert.truthy(got:find("to-stderr", 1, true), got)
    end)

    it("keeps a failing child's error text and sets shell_error", function()
        local s = script("", "the reason it failed\n", 3)
        local got = shim.fn.system({ nvim, "--clean", "-l", s })
        os.remove(s)
        assert.equals(3, shim.v.shell_error)
        assert.truthy(got:find("the reason it failed", 1, true), got)
    end)
end)
