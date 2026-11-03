--- The runtime "deleting"/"cleaning" mark a clean or deletion puts on its
--- config units must be cleared on EVERY exit path — success, failed task,
--- cancellation, refusal before start, and a throw — or the unit stays
--- "deleting" for the rest of the session (status row stuck on "cleaning",
--- data_model won't drop it, rename skips it, operations never finish).
---
--- Drives the real execute_deletion / clean_wipe_build_dir paths on a real
--- Core.

local h = require("tests.helpers")
local Core = require("loomworks.core")
local future_mod = require("loomworks.future")

local function make_core()
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { typescript = {} } },
            configuration_sets = { debug = { App = "dev" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({
            profiles = { debug = { configuration_set = "debug" } },
        }),
        ["loomworks.cache.json"] = h.make_cache_json({
            configurations = {
                ["App/dev"] = {
                    project_key = "App", config_key = "dev", variant = "dev",
                    type = "typescript", state = "built",
                },
            },
        }),
    }
    local deps = h.make_test_deps(files, { cache = { save = function() return true end } })
    local core = Core.new(deps)
    core:setup({ root = "/root" })
    return core
end

local function the_unit(core)
    local profile = h.find_profile(core:get_profiles(), "debug")
    local pp = profile:projects()[1]
    return pp._config_unit, profile
end

describe("clean/deletion runtime mark", function()
    local orig_notify

    before_each(function()
        orig_notify = vim.notify
        vim.notify = function() end
    end)

    after_each(function()
        vim.notify = orig_notify
    end)

    describe("execute_deletion", function()
        it("clears the mark when the deletion throws before removing anything", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            ws._mark_cache_unknown = function() error("boom") end
            local rejected = false
            ws:execute_deletion({ items = { { unit = unit, project_key = "App",
                config_key = "dev", disposition = "clean" } } }):catch(function() rejected = true end)
            assert.is_true(rejected)
            assert.is_false(unit:is_deleting())
        end)

        it("keeps the mark while a cancelled deletion's rm-rf still runs", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            local rm_done
            ws._core._deps.io.rm_rf_async = function(_, cb) rm_done = cb end
            local f = ws:execute_deletion({ items = { { unit = unit, project_key = "App",
                config_key = "dev", disposition = "clean",
                build_dir = "/root/.nvim/build/App-dev" } } })
            f:catch(function() end)
            assert.is_function(rm_done, "the removal started")
            f:cancel()
            assert.is_true(unit:is_deleting(),
                "the mark is the only guard while the rm-rf may still run")
            rm_done(true, nil)
            assert.is_false(unit:is_deleting(), "cleared once the removal finishes")
        end)

        it("clears the mark when a deletion is cancelled before its removal starts", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            local started = false
            ws._core._deps.io.rm_rf_async = function() started = true end
            ws.stop_tasks_then = function() return future_mod.create(function() end) end
            local f = ws:execute_deletion({ items = { { unit = unit, project_key = "App",
                config_key = "dev", disposition = "clean",
                build_dir = "/root/.nvim/build/App-dev" } } })
            f:catch(function() end)
            f:cancel()
            assert.is_false(started)
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark when finding the running tasks throws", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            ws.find_running_tasks_for_items = function() error("boom") end
            assert.has_error(function()
                ws:execute_deletion({ items = { { unit = unit, project_key = "App",
                    config_key = "dev", disposition = "clean" } } })
            end)
            assert.is_false(unit:is_deleting())
        end)

        -- A clean_wipe step runs a deletion of the clean's own units while the
        -- clean still runs: its end must not clear the clean's mark.
        it("a nested clean_wipe deletion keeps the outer clean's mark", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            ws._core._deps.io.rm_rf_async = function(_, cb) cb(true, nil) end
            unit:mark_deleting(true, "cleaning") -- the outer clean
            assert.is_true(unit:is_deleting())
            local done
            ws:clean_wipe_build_dir({ unit }, "/root/.nvim/build/App-dev"):next(function(ok) done = ok end)
            assert.is_true(done)
            assert.is_true(unit:is_deleting(), "the clean still runs")
            assert.equals("cleaning", unit:deleting_reason())
            unit:mark_deleting(false) -- the outer clean ends
            assert.is_false(unit:is_deleting())
        end)

        -- Marks are counted (they nest), so an unbalanced change never heals:
        -- a state-change listener that raises must not skip the count change
        -- nor the clearing of the mark.
        it("a listener raising while the mark is set leaves it balanced", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            ws._core._deps.io.rm_rf_async = function(_, cb) cb(true, nil) end
            local armed = true
            unit:on_state_change(function(u)
                if armed and u:is_deleting() then error("listener boom") end
            end)
            pcall(function()
                ws:execute_deletion({ items = { { unit = unit, project_key = "App",
                    config_key = "dev", disposition = "clean" } } })
            end)
            armed = false
            assert.is_false(unit:is_deleting())
            assert.equals(0, unit._deleting_marks or 0)
        end)

        it("a listener raising while the mark is cleared still clears every unit", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            local Unit = getmetatable(unit).__index
            local other = setmetatable({ _listeners = {}, _workspace = ws }, getmetatable(unit))
            assert.equals(Unit, getmetatable(other).__index)
            unit:mark_deleting(true); other:mark_deleting(true)
            unit:on_state_change(function(u)
                if not u:is_deleting() then error("listener boom") end
            end)
            pcall(ws:_deleting_mark_clearer({ unit, other }))
            assert.is_false(unit:is_deleting())
            assert.is_false(other:is_deleting())
        end)

        it("clears the mark when stopping the running tasks fails", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            ws.stop_tasks_then = function() return future_mod.rejected("stop failed") end
            local rejected = false
            ws:execute_deletion({ items = { { unit = unit, project_key = "App",
                config_key = "dev", disposition = "clean" } } }):catch(function() rejected = true end)
            assert.is_true(rejected)
            assert.is_false(unit:is_deleting())
        end)
    end)
end)
