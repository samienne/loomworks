-- Every module under lua/ may only require modules that exist in this repo
-- (or the few runtime-provided ones listed below). Guards against code that
-- still reaches for an editor-side module of loomworks.nvim, which is not
-- shipped here: such a require only fails when its code path runs.
--
-- Static scan of literal require("...") strings; dynamic requires (a
-- computed module name) are not seen.

local RUNTIME_PROVIDED = {
    -- luvi / libuv runtime of the standalone host
    luv = true,
    uv = true,
    luvi = true,
    miniz = true,
    openssl = true,
    -- LuaJIT
    bit = true,
    ffi = true,
    jit = true,
    ["jit.util"] = true,
    ["jit.vmdef"] = true,
    ["table.new"] = true,
    ["table.clear"] = true,
    -- Lua standard library
    string = true,
    table = true,
    math = true,
    os = true,
    io = true,
    coroutine = true,
    debug = true,
}

local function lua_files(dir, out)
    for name, kind in vim.fs.dir(dir) do
        local path = dir .. "/" .. name
        if kind == "directory" then
            lua_files(path, out)
        elseif kind == "file" and name:match("%.lua$") then
            out[#out + 1] = path
        end
    end
    return out
end

local function module_exists(name)
    local base = "lua/" .. name:gsub("%.", "/")
    return vim.uv.fs_stat(base .. ".lua") ~= nil or vim.uv.fs_stat(base .. "/init.lua") ~= nil
end

describe("require closure", function()
    it("every literal require under lua/ names a module of this repo", function()
        local missing = {}
        for _, file in ipairs(lua_files("lua", {})) do
            local fd = assert(io.open(file, "rb"))
            local src = fd:read("*a")
            fd:close()
            local lnum = 0
            for line in (src .. "\n"):gmatch("([^\n]*)\n") do
                lnum = lnum + 1
                local code = line:gsub("%-%-.*$", "")
                for name in code:gmatch("require[%s,]*%(?%s*[\"']([%w_%.%-]+)[\"']") do
                    -- (A name ending in "." is the prefix of a computed one.)
                    if not name:match("%.$") and not RUNTIME_PROVIDED[name] and not module_exists(name) then
                        missing[#missing + 1] = ("%s:%d requires %s"):format(file, lnum, name)
                    end
                end
            end
        end
        assert.are.same({}, missing)
    end)
end)
