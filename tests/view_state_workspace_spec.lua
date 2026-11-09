-- The status page's body as `loomworks.view.Workspace/1` (spec §19.13
-- "Views"): Workspace:view_workspace builds plain data with the caller's ids,
-- carries intent, removed_upstream and the device shape, carries no progress,
-- and every fixture's view is a valid `/$defs/Workspace`. Also the header
-- view's version (`loomworks.view.Header/1`): view_state.header carries it and
-- leaves it out when unknown.

local Core = require("loomworks.core")
local h = require("tests.helpers")

--- The view must not depend on the machine: the toolchain search path (a
--- compiler-cache launcher on PATH shows in the profile's view and drives the
--- "no compiler cache" health suggestion) is stubbed empty while a fixture
--- loads and builds its view.
local function without_path(fn)
    local cc = require("loomworks.cpp_compilers")
    local saved = cc.lookup_path
    cc.lookup_path = function() return nil end
    local ok, res = pcall(fn)
    cc.lookup_path = saved
    if not ok then error(res, 0) end
    return res
end

--- A stub module: keyed tools for cmake, resolved options with sources, test
--- targets; the real shell module for `shell` (its editable fields).
local function modules_dep(tools)
    local real = require("loomworks.modules")
    return {
        get = function(mod_type)
            if not mod_type then return nil end
            if mod_type == "shell" then return real.get("shell") end
            return {
                -- `tools`: the detected tools of a keyed-tool module.
                detect_tools_async = tools and function(callback)
                    local out = {}
                    for _, td in ipairs(tools) do out[#out + 1] = { tool_data = td } end
                    callback(out)
                end or nil,
                tool_key = tools and function(td) return td.id end or nil,
                tool_label = tools and function(td) return td.display or td.id end or nil,
                validate = tools and function() return { valid = true, warnings = {} } end or nil,
                id = mod_type,
                api_version = 1,
                has_keyed_tools = (mod_type == "cmake"),
                tools_match = function(a, b)
                    if a == nil and b == nil then return true end
                    if a == nil or b == nil then return false end
                    return vim.deep_equal(a, b)
                end,
                info = function(_, type_config)
                    local configs = {}
                    if type_config and type_config.configurations then
                        for name, data in pairs(type_config.configurations) do
                            configs[name] = vim.tbl_extend("force", { is_user = true }, data)
                        end
                    end
                    return { configurations = configs }
                end,
            }
        end,
    }
end

local FIXTURES = {
    cmake = {
        config = {
            projects = {
                App = {
                    cmake = { description = "The application.\n\nIt does things.", configurations = {
                        Base = { options = { WARN = "ON" } },
                        Debug = { variant = "Debug", inherits = "Base", options = { OPT = "1" } },
                        -- One dependent of Base only: Configuration:dependents()
                        -- has no fixed order.
                        Release = { variant = "Release", inherits = { "Gone" } },
                    } },
                    launch = {
                        run = { command = "app", args = { "--x", "1" }, description = "Run it" },
                        tgt = { target = "app" },
                    },
                    deploy = {
                        ["${workspace_root}/out/"] = {
                            { project = "Lib", target = "lib", pre_build = true },
                            { project = "Lib", path = "x.dat", configuration = "Debug" },
                        },
                    },
                    variables = { home = { type = "path", default = "/h" } },
                },
                Lib = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
            },
            configuration_sets = {
                debug = { App = "Debug", Lib = "Debug" },
                release = { App = "Release", Lib = "Nope" },
            },
        },
        user = {
            active_profile = "debug",
            profiles = {
                debug = { configuration_set = "debug", description = "Day to day" },
                release = { configuration_set = "release" },
                ghost = { configuration_set = "vanished" },
            },
        },
        cache = {
            configurations = {
                ["App/Debug"] = { project_key = "App", config_key = "Debug", variant = "Debug",
                    type = "cmake", state = "built", build_dir = "/root/build/App/Debug" },
                ["Old/Debug"] = { project_key = "Old", config_key = "Debug", variant = "Debug",
                    type = "cmake", state = "configured", build_dir = "/root/build/Old/Debug" },
            },
        },
    },
    shell = {
        config = {
            projects = {
                Tool = { shell = {
                    configure = { "sh", "configure.sh" },
                    build = { "make" },
                    build_dir = "${workspace_root}/out",
                    env = { CC = "gcc" },
                } },
            },
            configuration_sets = { only = { Tool = "variant:default" } },
        },
        user = {
            active_profile = "only",
            profiles = { only = { configuration_set = "only" } },
        },
    },
    empty = {
        config = { projects = {} },
    },
    tools = {
        tools = { { id = "ninja-gcc-12", display = "Ninja + GCC 12", compiler_path = "/usr/bin/gcc-12",
            generator = "Ninja" } },
        config = {
            projects = { App = { cmake = { configurations = { Debug = { variant = "Debug" } } } } },
            configuration_sets = { debug = { App = "Debug" } },
        },
        user = {
            active_profile = "debug:ninja-gcc-12",
            profiles = {
                ["debug:ninja-gcc-12"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12",
                        display = "Ninja + GCC 12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" } } },
                },
            },
        },
        cache = {
            build_dirs = {
                ["build/App/ninja-gcc-12/Debug"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc-12", variant = "Debug",
                    type = "cmake", state = "built", tool_key = "ninja-gcc-12",
                    tool_data = { id = "ninja-gcc-12", display = "Ninja + GCC 12",
                        compiler_path = "/usr/bin/gcc-12", generator = "Ninja" },
                },
            },
        },
    },
}

--- A loaded test Core of fixture `name`.
local function fixture_core(name)
    local fx = FIXTURES[name]
    local files = { ["loomworks.json"] = h.make_config_json(fx.config) }
    if fx.user then files["user.json"] = h.make_user_json(fx.user) end
    if fx.cache then files["cache.json"] = h.make_cache_json(fx.cache) end
    local core = Core.new(h.make_test_deps(files, { modules = modules_dep(fx.tools),
        notify = function() end }))
    core:setup({ root = "/root" })
    return core
end

describe("view_state.workspace (loomworks.view.Workspace/1)", function()
    --- Every value plain data: no functions, no objects (metatables other than
    --- the JSON empty-object marker).
    local function plain(v, path)
        if type(v) == "function" then error("function at " .. path) end
        if type(v) ~= "table" then return end
        local mt = getmetatable(v)
        if mt and mt ~= vim._empty_dict_mt then error("object at " .. path) end
        for k, x in pairs(v) do plain(x, path .. "." .. tostring(k)) end
    end

    it("is plain data, with ids only from the caller's id function", function()
        local ws = fixture_core("cmake"):get_workspace()
        local bound = 0
        local v = ws:view_workspace({ bind = function() bound = bound + 1 end })
        plain(v, "view")
        assert.is_true(bound > 0)
        assert.is_nil(v.profiles[1].id)
        assert.is_nil(v.projects[1].id)
        local ids = ws:view_workspace({ id = function(o) return "id:" .. tostring(o.key or o.name) end })
        plain(ids, "view")
        assert.equals("id:" .. ids.profiles[1].key, ids.profiles[1].id)
        assert.equals("id:" .. ids.config_sets[1].name, ids.config_sets[1].id)
        assert.equals("id:" .. ids.projects[1].key, ids.projects[1].id)
    end)

    it("carries intent, removed_upstream and the device shape", function()
        local v = fixture_core("tools"):get_workspace():view_workspace()
        local p = v.profiles[1]
        assert.equals("debug:ninja-gcc-12", p.key)
        assert.is_false(p.removed_upstream)
        assert.equals(p.key, p.label)
        assert.is_nil(p.device) -- no device-capable module
        assert.is_nil(p.device_capable)
        assert.equals(1, #p.tools)
        assert.equals("cmake", p.tools[1].module)
        assert.equals("ninja-gcc-12", p.tools[1].key)
        assert.same({ { project = { key = "App" }, configuration = { key = "Debug" }, missing = false } },
            v.config_sets[1].mappings)
        local cfg = v.projects[1].configurations[1]
        assert.equals("Debug", cfg.key)
        assert.equals("Debug", cfg.label)
        assert.is_false(cfg.removed_upstream)
        assert.equals("built", p.units[1].state)
    end)

    it("carries no progress and no publish state of a launch; the last result is state", function()
        local ws = fixture_core("cmake"):get_workspace()
        local profile = ws:get_active_profile()
        local v = ws:view_workspace()
        local p
        for _, row in ipairs(v.profiles) do if row.key == profile.key then p = row end end
        assert.is_nil(p.last_result)
        for _, k in ipairs({ "pct", "elapsed", "message" }) do assert.is_nil(p[k], k) end
        for _, u in ipairs(p.units) do
            assert.is_nil(u.progress)
            assert.is_nil(u.elapsed)
        end
        local proj = v.projects[1]
        assert.is_true(#proj.launches > 0)
        for _, l in ipairs(proj.launches) do
            for _, k in ipairs({ "name", "modified", "intent", "removed_upstream" }) do assert.is_nil(l[k], k) end
        end
        for _, c in ipairs(proj.configurations) do
            assert.is_nil(c.object)
            assert.is_nil(c.name)
        end
        profile:set_last_result("failed", "build failed in 3s")
        v = ws:view_workspace()
        for _, row in ipairs(v.profiles) do if row.key == profile.key then p = row end end
        assert.same({ status = "failed", message = "build failed in 3s" }, p.last_result)
    end)
end)

describe("view_state.workspace against the view.Workspace/1 schema", function()
    local documents = require("loomworks.proto.documents")
    local set = documents.set()
    for _, name in ipairs({ "cmake", "shell", "empty", "tools" }) do
        it("the " .. name .. " fixture's view is a valid /$defs/Workspace", function()
            local n = 0
            local v = without_path(function()
                return fixture_core(name):get_workspace():view_workspace({
                    id = function() n = n + 1; return "o" .. n end })
            end)
            local ok, err = set:validate("interfaces/loomworks/view.Workspace.1.json", "/$defs/Workspace", v)
            assert.is_true(ok, err)
        end)
    end
end)

describe("view_state.header version (loomworks.view.Header/1)", function()
    local save_guard = require("loomworks.save_guard")
    local view_state = require("loomworks.view_state")
    local views = require("loomworks.daemon.views")
    local real_version = save_guard.version()

    after_each(function() save_guard._set_version(real_version) end)

    --- A stand-in for the daemon's build service: its header model is `ws`.
    local function service(ws)
        return {
            server = { root = ws.root, pid = 1, identity = "lw-test", generation = 1 },
            header_model = function() return ws end,
            ids = { id = function(_, obj) return "id:" .. tostring(obj.key or obj.name) end },
        }
    end

    it("carries the version it is given, loaded or not", function()
        local ws = fixture_core("cmake"):get_workspace()
        assert.equals("0.1.50", view_state.header(ws, nil, { version = "0.1.50" }).version)
        local err = view_state.header(nil, { root = "/x", message = "boom" }, { version = "0.1.43" })
        assert.equals("0.1.43", err.version)
    end)

    it("the daemon's header carries save_guard.version()", function()
        local ws = fixture_core("cmake"):get_workspace()
        assert.is_truthy(real_version)
        assert.equals(real_version, views.header(service(ws)).version)
        save_guard._set_version("0.1.43")
        assert.equals("0.1.43", views.header(service(ws)).version)
    end)

    it("leaves it out when unknown", function()
        local ws = fixture_core("cmake"):get_workspace()
        assert.is_nil(view_state.header(ws, nil, {}).version)
        save_guard._set_version(nil)
        assert.is_nil(views.header(service(ws)).version)
    end)
end)
