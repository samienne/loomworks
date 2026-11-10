--- `lw run` resolves its launch target before building (headless §16.17
--- "Order", samienne/loomworks#163).
---
--- The bug: `lw run` built the whole profile first and only then resolved the
--- launch target, so a profile without a default target failed with "no
--- default target set" after a full build — and a resolved target still built
--- the whole profile. Now a run configures what is not configured, resolves
--- the target (failing there, before any build), then builds that target only.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local real_modules = require("loomworks.modules")

local orig_lookup = cpp.lookup_path

local function has_seq(cmd, seq)
    for i = 1, #cmd - #seq + 1 do
        local ok = true
        for j = 1, #seq do
            if cmd[i + j - 1] ~= seq[j] then ok = false; break end
        end
        if ok then return true end
    end
    return false
end

local TOOL = { key = "ninja-gcc-13", data = {
    compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake",
} }

--- Two cmake projects App + Lib in profile `debug`, in a real temp root.
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
            tools = { cmake = { key = TOOL.key, data = TOOL.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = TOOL.key, tool_data = TOOL.data, tool_label = TOOL.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    return ws, ws._profiles[1], root
end

local function unit_of(profile, key)
    for _, pp in ipairs(profile:projects()) do
        if pp._project and pp._project.key == key then return pp._config_unit end
    end
end

--- Make a unit look configured on this machine with the given target list.
local function configured(unit, targets)
    unit.configure_reason = function() return nil end
    unit:set_targets(targets)
end

local function with_ws(ws, fn)
    local loomworks = require("loomworks.app")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, res = pcall(fn)
    loomworks.get_workspace = orig
    if not ok then error(res, 0) end
    return res
end

--- `lw run` on `profile` (`target` named or nil) with the spawn and the
--- launch stubbed. `on_spawn(step)` may return an exit code. Returns the
--- spawned steps, the launched LaunchTarget (nil: none), the exit code (nil:
--- success) and stderr.
local function run(ws, profile, target, extra, on_spawn)
    local cli = require("loomworks.cli")
    local spawned, err_buf, launched = {}, {}, nil
    local orig = { cli._run_spec, cli._run_selection, cli._run_launch_target, io.write, io.stderr, os.exit }
    local exit_code
    cli._run_spec = function(step)
        spawned[#spawned + 1] = step
        return on_spawn and on_spawn(step) or 0
    end
    cli._run_selection = function(w) return profile, target, w end
    cli._run_launch_target = function(lt) launched = lt; return 0 end
    io.write = function() end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    os.exit = function(c) exit_code = c or 0; error({ __exit = true }, 0) end
    local argv = { "run" }
    for _, a in ipairs(extra or {}) do argv[#argv + 1] = a end
    local ok, err = pcall(function()
        with_ws(ws, function() return cli.cmd_run(ws, argv) end)
    end)
    cli._run_spec, cli._run_selection, cli._run_launch_target, io.write, io.stderr, os.exit =
        orig[1], orig[2], orig[3], orig[4], orig[5], orig[6]
    if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
    return spawned, launched, exit_code, table.concat(err_buf)
end

local function of_kind(spawned, kind)
    local out = {}
    for _, s in ipairs(spawned) do if s.kind == kind then out[#out + 1] = s end end
    return out
end

describe("lw run: the launch target resolves before the build (§16.17 Order)", function()
    local root, ws, profile
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        cpp.lookup_path = function() return nil end
        ws, profile, root = make_core()
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    local function both_known()
        configured(unit_of(profile, "App"), {
            AppRunner = { type = "executable", artifact = "AppRunner" },
            Common = { type = "static_library" } })
        configured(unit_of(profile, "Lib"), {
            LibTool = { type = "executable", artifact = "LibTool" },
            Common = { type = "static_library" } })
    end

    it("no default target and several candidates: refused before any build", function()
        both_known()
        local spawned, launched, code, stderr = run(ws, profile, nil)
        assert.equals(1, code)
        assert.truthy(stderr:find("no default target set", 1, true), stderr)
        assert.truthy(stderr:find("lw target set", 1, true), stderr)
        assert.equals(0, #spawned, "nothing was built")
        assert.is_nil(launched)
    end)

    it("an unknown named target: refused before any build", function()
        both_known()
        local spawned, launched, code, stderr = run(ws, profile, "Nope")
        assert.equals(1, code)
        assert.truthy(stderr:find("no launch target 'Nope'", 1, true), stderr)
        assert.equals(0, #spawned, "nothing was built")
        assert.is_nil(launched)
    end)

    it("a named target builds that target in its project only", function()
        both_known()
        local spawned, launched, code, stderr = run(ws, profile, "LibTool")
        assert.is_nil(code, stderr)
        local b = of_kind(spawned, "build")
        assert.equals(1, #b, "only Lib is built")
        assert.equals(unit_of(profile, "Lib"), b[1].unit)
        assert.is_true(has_seq(b[1].cmd, { "--target", "LibTool" }), table.concat(b[1].cmd, " "))
        assert.truthy(launched)
        assert.equals("LibTool", launched._target.id)
    end)

    it("the sole launchable target builds that target only", function()
        configured(unit_of(profile, "App"), { AppRunner = { type = "executable", artifact = "AppRunner" } })
        configured(unit_of(profile, "Lib"), { Common = { type = "static_library" } })
        local spawned, launched, code, stderr = run(ws, profile, nil)
        assert.is_nil(code, stderr)
        local b = of_kind(spawned, "build")
        assert.equals(1, #b, "only App is built")
        assert.equals(unit_of(profile, "App"), b[1].unit)
        assert.is_true(has_seq(b[1].cmd, { "--target", "AppRunner" }), table.concat(b[1].cmd, " "))
        assert.truthy(launched)
    end)

    it("an unconfigured profile is configured first, then resolved, then the target built", function()
        local app, lib = unit_of(profile, "App"), unit_of(profile, "Lib")
        -- Not configured: the configure step makes the targets known.
        app.configure_reason = function() return "unconfigured" end
        lib.configure_reason = function() return "unconfigured" end
        local spawned, launched, code, stderr = run(ws, profile, "AppRunner", nil, function(step)
            if step.kind == "configure" then
                if step.unit == app then
                    configured(app, { AppRunner = { type = "executable", artifact = "AppRunner" } })
                else
                    configured(lib, { LibTool = { type = "executable", artifact = "LibTool" } })
                end
            end
            return 0
        end)
        assert.is_nil(code, stderr)
        assert.equals(2, #of_kind(spawned, "configure"))
        local b = of_kind(spawned, "build")
        assert.equals(1, #b)
        assert.equals(app, b[1].unit)
        assert.is_true(has_seq(b[1].cmd, { "--target", "AppRunner" }), table.concat(b[1].cmd, " "))
        -- Every configure ran before the build.
        assert.equals("build", spawned[#spawned].kind)
        assert.truthy(launched)
    end)

    it("an unconfigured profile without a default: configured, then refused before any build", function()
        local app, lib = unit_of(profile, "App"), unit_of(profile, "Lib")
        app.configure_reason = function() return "unconfigured" end
        lib.configure_reason = function() return "unconfigured" end
        local spawned, _, code, stderr = run(ws, profile, nil, nil, function(step)
            if step.kind == "configure" then
                configured(step.unit, { [step.unit == app and "AppRunner" or "LibTool"] =
                    { type = "executable", artifact = "x" } })
            end
            return 0
        end)
        assert.equals(1, code)
        assert.truthy(stderr:find("no default target set", 1, true), stderr)
        assert.equals(0, #of_kind(spawned, "build"), "nothing was built")
    end)

    it("--no-build runs nothing and still resolves the target", function()
        both_known()
        local spawned, launched, code, stderr = run(ws, profile, "AppRunner", { "--no-build" })
        assert.is_nil(code, stderr)
        assert.equals(0, #spawned)
        assert.truthy(launched)
    end)
end)

describe("run_prep.build_picks", function()
    local rp = require("loomworks.run_prep")
    local App, Lib, Other = { key = "App" }, { key = "Lib" }, { key = "Other" }
    local profile = { project = function(_, key) return (key == "App" or key == "Lib") and {} or nil end }

    it("a build target: its project for that target, its in-profile dependencies whole", function()
        local lt = { _project = App, _target = { id = "AppRunner" },
            build_dependencies = function() return { { project = Lib }, { project = Other } } end }
        assert.same({ [App] = { "AppRunner" }, [Lib] = {} }, rp.build_picks(profile, lt))
    end)

    it("a target-backed launch configuration: its target", function()
        local lt = { _project = App, _launch = { target = "AppRunner" }, _config_target = { id = "AppRunner" },
            build_dependencies = function() return {} end }
        assert.same({ [App] = { "AppRunner" } }, rp.build_picks(profile, lt))
    end)

    it("a command launch configuration builds the whole profile", function()
        local lt = { _project = App, _launch = { command = "x" },
            build_dependencies = function() return {} end }
        assert.is_nil(rp.build_picks(profile, lt))
    end)
end)
