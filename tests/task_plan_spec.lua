--- Tests for loomworks/task_plan.lua: test planning helpers, JUnit paths,
--- task result recording and task configurations.

local h = require("tests.helpers")

describe("_unit_tests_self_rebuild", function()
    local task_plan = require("loomworks.task_plan")

    --- A stub test unit. `rebuilds` may be a boolean or nil; `has_runner`
    --- controls whether `run_command_all` is present at all.
    local function tu(rebuilds, has_runner)
        local t = {}
        if has_runner ~= false then t.run_command_all = function() return {} end end
        t.run_command_all_rebuilds = function() return rebuilds and true or false end
        return t
    end

    --- A stub ConfigUnit exposing `test_units()`.
    local function unit(tus)
        return { test_units = function() return tus end }
    end

    it("true when every native runner self-rebuilds (meson)", function()
        assert.is_true(task_plan._unit_tests_self_rebuild(unit({ tu(true) })))
    end)

    it("false when a native runner does not self-rebuild (ctest)", function()
        assert.is_false(task_plan._unit_tests_self_rebuild(unit({ tu(false) })))
    end)

    it("false for a mixed unit (one self-rebuilds, one does not)", function()
        assert.is_false(task_plan._unit_tests_self_rebuild(unit({ tu(true), tu(false) })))
    end)

    it("false when the unit has no test units", function()
        assert.is_false(task_plan._unit_tests_self_rebuild(unit({})))
    end)

    it("false when no test unit has a native runner", function()
        assert.is_false(task_plan._unit_tests_self_rebuild(unit({ tu(true, false) })))
    end)

    it("false for a unit that cannot enumerate test units", function()
        assert.is_false(task_plan._unit_tests_self_rebuild({}))
        assert.is_false(task_plan._unit_tests_self_rebuild(nil))
    end)
end)

describe("junit_dest_for (spec §16.16 per-unit JUnit paths)", function()
    local f = require("loomworks.task_plan")._junit_dest_for

    it("returns the path verbatim for a single unit", function()
        assert.equals("/out/report.xml", f("/out/report.xml", "app:Debug", false))
    end)

    it("inserts a sanitized label before the extension for multiple units", function()
        assert.equals("/out/report.app-Debug.xml", f("/out/report.xml", "app:Debug", true))
        assert.equals("/out/report.lib-Release.xml", f("/out/report.xml", "lib:Release", true))
    end)

    it("handles a path with no extension", function()
        assert.equals("/out/report.app-Debug", f("/out/report", "app:Debug", true))
    end)

    it("handles a bare filename with no directory", function()
        assert.equals("r.app-Debug.xml", f("r.xml", "app:Debug", true))
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: record_task_result does not downgrade built → configured
-- ---------------------------------------------------------------------------

describe("record_task_result state protection", function()
    local Core = require("loomworks.core")

    local function make_core_with_state(project_key, config_key, cached_state)
        local config_json = h.make_config_json({
            projects = { [project_key] = { cmake = {} } },
        })
        local cache_key = project_key .. "/" .. config_key
        local cache_json = h.make_cache_json({
            configurations = {
                [cache_key] = {
                    project_key = project_key,
                    config_key = config_key,
                    type = "cmake",
                    state = cached_state,
                    variant = config_key,
                },
            },
        })
        local deps = h.make_test_deps({
            ["loomworks.json"] = config_json,
            ["cache.json"] = cache_json,
        }, {
            modules = {
                get = function(mod_type)
                    if mod_type ~= "cmake" then return nil end
                    return {
                        validate = function() return { valid = true, warnings = {} } end,
                        info = function() return { configurations = { [config_key] = {} } } end,
                    }
                end,
            },
        })
        local core = Core.new(deps)
        core:setup({ root = "/test" })
        return core
    end

    pending("does not downgrade built to configured on successful configure", function()
        local core = make_core_with_state("App", "Debug", "built")

        -- Verify initial state
        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        assert.equals("built", unit:state())

        -- Record a configure success
        core:record_task_result({
            unit = unit,
            action = "configure",
            success = true,
        })

        -- State should still be built
        assert.equals("built", unit:state())
    end)

    pending("updates last_configured even when state stays built", function()
        local core = make_core_with_state("App", "Debug", "built")

        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        core:record_task_result({
            unit = unit,
            action = "configure",
            success = true,
        })

        assert.equals("built", unit.state_value)
        assert.is_not_nil(unit.last_configured)
    end)

    it("sets configured state when previously unconfigured", function()
        local core = make_core_with_state("App", "Debug", "unconfigured")

        -- The "unconfigured" skeleton may be cleaned up by _cleanup_orphaned_skeletons
        -- since no profile references it. Use ensure_config_unit to create it.
        local project = h.find_project_in(core:get_projects(), "App")
        local unit = core._workspace:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
        core:record_task_result({
            unit = unit,
            action = "configure",
            success = true,
        })

        assert.equals("configured", unit:state())
    end)

    pending("sets configure_failed on failed configure", function()
        local core = make_core_with_state("App", "Debug", "built")

        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        core:record_task_result({
            unit = unit,
            action = "configure",
            success = false,
        })

        assert.equals("configure_failed", unit:state())
    end)

    pending("sets built state on successful build", function()
        local core = make_core_with_state("App", "Debug", "configured")

        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        core:record_task_result({
            unit = unit,
            action = "build",
            success = true,
        })

        assert.equals("built", unit:state())
    end)

    pending("sets build_failed on failed build", function()
        local core = make_core_with_state("App", "Debug", "configured")

        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        core:record_task_result({
            unit = unit,
            action = "build",
            success = false,
        })

        assert.equals("build_failed", unit:state())
    end)
end)

describe("task_plan task_configurations (preset merge)", function()
    local task_plan = require("loomworks.task_plan")

    it("merges preset_configurations into the task-context configurations", function()
        -- The task path must see presets under their canonical key, or
        -- config_info is nil in module.tasks and the --preset path is dead.
        local merged = task_plan._task_configurations({
            configurations = { ["variant:Debug"] = { variant = "Debug" } },
            preset_configurations = {
                ["preset:dev"] = { from_preset = true, base_name = "dev" },
            },
        })
        assert.is_not_nil(merged["variant:Debug"])
        assert.is_not_nil(merged["preset:dev"])
        assert.is_true(merged["preset:dev"].from_preset)
    end)

    it("is a no-op for modules without presets", function()
        local merged = task_plan._task_configurations({
            configurations = { Debug = { variant = "Debug" } },
        })
        assert.is_not_nil(merged.Debug)
        assert.is_nil(merged["preset:dev"])
    end)
end)

