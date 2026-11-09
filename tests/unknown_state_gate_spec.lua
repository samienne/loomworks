--- The build gate's `unknown` refusal (API §8.2 / §8.3): a configuration
--- unit whose state is `unknown` (an interrupted delete or reset — its build
--- directory is untrusted) is refused by a build and by a configure, before
--- any step, for a profile, for configuration units and for a launch's unit
--- build. Clean and reset of it stay allowed: they are the remedy.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local build_run = require("loomworks.build_run")
local task_plan = require("loomworks.task_plan")
local real_modules = require("loomworks.modules")

local orig_lookup = cpp.lookup_path

local GCC_TOOL = {
    key = "ninja-gcc-13",
    data = { compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake" },
}

local REFUSAL = "App/Debug: build directory state unknown (interrupted delete or reset); "
    .. "run lw clean or lw reset first"

--- cmake projects App/Debug and Lib/Debug, profile `debug` on gcc + Ninja, in
--- a real temp root; App's unit is in state `unknown`.
local function make_core()
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    vim.fn.mkdir(root .. "/Lib", "p")
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = {
                App = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
                Lib = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
            },
            configuration_sets = { debug = { App = "Debug", Lib = "Debug" } },
        }),
        ["user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = GCC_TOOL.key, data = GCC_TOOL.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = GCC_TOOL.key, tool_data = GCC_TOOL.data, tool_label = GCC_TOOL.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    local app
    for _, pp in ipairs(profile:projects()) do
        if pp._project.key == "App" then app = pp._config_unit end
    end
    app.state_value = "unknown"
    assert.equals("unknown", app:state())
    return ws, profile, app, root
end

local function with_ws(ws, fn)
    local loomworks = require("loomworks.app")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, a, b, c = pcall(fn)
    loomworks.get_workspace = orig
    assert.is_true(ok, tostring(a))
    return a, b, c
end

describe("build gate: a unit in unknown state", function()
    local root
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        cpp.lookup_path = function() return nil end
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    it("refuses a profile configure before any step", function()
        local ws, profile, _, r = make_core()
        root = r
        local steps, err = with_ws(ws, function() return build_run.plan(profile, { configure_only = true }) end)
        assert.is_nil(steps)
        assert.equals("cannot build: " .. REFUSAL, err)
    end)

    it("refuses a profile build before any step", function()
        local ws, profile, _, r = make_core()
        root = r
        local steps, err = with_ws(ws, function() return build_run.plan(profile) end)
        assert.is_nil(steps)
        assert.equals("cannot build: " .. REFUSAL, err)
    end)

    it("refuses a units-scoped configure and build (Build/1 units)", function()
        local ws, _, app, r = make_core()
        root = r
        for _, configure_only in ipairs({ true, false }) do
            local steps, err = with_ws(ws, function()
                return build_run.plan(nil, { units = { app }, configure_only = configure_only or nil })
            end)
            assert.is_nil(steps)
            assert.equals("cannot build: " .. REFUSAL, err)
        end
    end)

    it("refuses a launch's build of the unit", function()
        local ws, profile, app, r = make_core()
        root = r
        local steps, err = with_ws(ws, function() return task_plan.plan_unit_build(ws, app, { profile = profile }) end)
        assert.is_nil(steps)
        assert.equals(REFUSAL, err)
    end)

    it("`lw build` exits 1 with the refusal and spawns nothing", function()
        local ws, profile, _, r = make_core()
        root = r
        local cli = require("loomworks.cli")
        local spawned, errs, code = 0, {}, nil
        local orig_spawn, rw, rs, rx = cli._run_spec, io.write, io.stderr, os.exit
        cli._run_spec = function() spawned = spawned + 1; return 0 end
        io.write = function() end
        io.stderr = { write = function(_, s) errs[#errs + 1] = s end }
        os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
        local app_mod = require("loomworks.app")
        local orig_get = app_mod.get_workspace
        app_mod.get_workspace = function() return ws end
        local ok, e = pcall(cli.cmd_build, ws, { "build", profile.key })
        app_mod.get_workspace = orig_get
        cli._run_spec, io.write, io.stderr, os.exit = orig_spawn, rw, rs, rx
        if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
        assert.equals(1, code)
        assert.equals(0, spawned)
        assert.truthy(table.concat(errs):find("cannot build: " .. REFUSAL, 1, true), table.concat(errs))
    end)

    it("still lets a unit in another state configure", function()
        local ws, profile, app, r = make_core()
        root = r
        app.state_value = nil
        local steps, err = with_ws(ws, function() return build_run.plan(profile, { configure_only = true }) end)
        assert.is_nil(err)
        assert.equals(2, #steps)
    end)

    it("keeps clean and reset allowed (the remedy)", function()
        local ws, profile, app, r = make_core()
        root = r
        vim.fn.mkdir(app:build_dir(), "p")
        local steps = with_ws(ws, function() return task_plan.plan_profile_clean(profile) end)
        local cleans_app = false
        for _, s in ipairs(steps or {}) do
            if s.unit == app then cleans_app = true end
        end
        assert.is_true(cleans_app, vim.inspect(steps))
        local rplan = with_ws(ws, function() return require("loomworks.reset_plan").plan(ws, { profile = profile }) end)
        local resets_app = false
        for _, u in ipairs(rplan.units) do
            if u == app then resets_app = true end
        end
        assert.is_true(resets_app)
    end)
end)
