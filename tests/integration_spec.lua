--- Integration tests of the domain stack (Workspace, merge, cache, profile,
--- config_unit) through model_commands: lifecycles (configuration set,
--- profile, orphan), profile upgrade/downgrade, opaque keys, the two-layer
--- merge, modified state, project variables, operation completion on
--- failure and profile persistence. Only I/O, notifications and scheduling
--- are mocked.
---
--- Ported from the plugin's integration_spec, which drove these through
--- its editor view-model (workspace_view). That view-model is a thin
--- wrapper over model_commands; the `wv` shim below is the same wrapper.
--- The editor-only parts (picker candidates, dialog contexts, path
--- derivation for the add-project dialog) stay in the plugin.

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")
local commands = require("loomworks.model_commands")
local dp = require("loomworks.deletion_plan")

--- Run the confirmed deletion of `target` (model_commands.execute_deletion)
--- to its end; the final outcome (the request's when it was not accepted).
local function run_deletion(ws, target)
    local final
    local r = commands.execute_deletion(ws, target, { yes = true, done = function(o) final = o end })
    if r.outcome ~= "accepted" then return r end
    assert.is_true(vim.wait(5000, function() return final ~= nil end, 10), "deletion never finished")
    return final
end

local Workspace = workspace.Workspace

--- The editor view-model's model_commands wrappers (workspace_view), as used
--- by these tests.
local function as_result(r)
    if r.outcome ~= "ok" then return false, r.message end
    for i, role in ipairs(r.note_roles or {}) do
        if role == "warn" then return false, r.notes[i] end
    end
    return true
end

local wv = {}
function wv.execute_add_project(ws, key, mod_type, path, result)
    local mod = require("loomworks.modules").get(mod_type)
    local mappings = result.mappings
    if mod and mod.has_keyed_tools and not result.tool_entry then mappings = nil end
    local r = commands.project_add(ws, key, mod_type, path, mappings, result.tool_entry)
    local ok, err = as_result(r)
    return ok, err, r.project
end
function wv.execute_create_config_set(ws, name, mappings)
    local r = commands.config_set_add(ws, name, mappings)
    if r.outcome ~= "ok" then return nil, r.message end
    return r.config_set
end
function wv.execute_edit_config_set(cs, new_name, new_mappings)
    return as_result(commands.config_set_update(cs, new_name, new_mappings))
end
function wv.execute_delete_config_set(_, cs)
    return as_result(commands.config_set_remove(cs))
end
function wv.execute_create_profile(cs, tool_entry, activate)
    local r = commands.profile_create(cs._workspace, cs, tool_entry, activate)
    if not r.profile then
        local _, err = as_result(r)
        return nil, err
    end
    return r.profile
end
function wv.get_variables(project)
    if not project.variables then return {} end
    local result = {}
    for name, decl in pairs(project.variables) do
        result[#result + 1] = { name = name, type = decl.type, default = decl.default }
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end
function wv.execute_save_variable(project, old_name, new_name, data)
    return as_result(commands.variable_save(project, old_name, new_name, data))
end
function wv.project_declaration(project)
    return commands.project_declaration(project, function() return nil end)
end

--- Mock modules with info() returning detectable configurations.
--- Under the prefix-namespacing design, modules emit canonical keys
--- (prefix:base) for auto-gens. User overrides land as standalone
--- bare-keyed entries; they are NOT silently merged into same-named
--- auto-gens.
local Configuration = require("loomworks.configuration")
local mock_modules = {
    cmake = {
        id = "cmake",
        has_keyed_tools = true,
        has_options = true,
        tools_match = function(a, b)
            if a == nil and b == nil then return true end
            if a == nil or b == nil then return false end
            return vim.deep_equal(a, b)
        end,
        default_configurations = function()
            return {
                Debug = { prefix = "variant", variant = "Debug" },
                Release = { prefix = "variant", variant = "Release" },
                RelWithDebInfo = { prefix = "variant", variant = "RelWithDebInfo" },
            }
        end,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type then return name end
            end
            return nil
        end,
        tool_key = function(tool_data) return tool_data.id end,
        tool_label = function(tool_data) return tool_data.display end,
        detect_tools_async = function(callback) callback({}) end,
        info = function(path, config)
            local defaults = {
                Debug = { prefix = "variant", variant = "Debug" },
                Release = { prefix = "variant", variant = "Release" },
                RelWithDebInfo = { prefix = "variant", variant = "RelWithDebInfo" },
            }
            return {
                configurations = Configuration.canonicalize(
                    defaults, config and config.configurations, "cmake"),
            }
        end,
    },
    harmony = {
        id = "harmony",
        has_keyed_tools = false,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type or name == variant_type then return name end
            end
            return nil
        end,
        info = function(_, config)
            local defaults = {
                debug = { prefix = "auto", variant = "debug" },
                release = { prefix = "auto", variant = "release" },
            }
            return {
                configurations = Configuration.canonicalize(
                    defaults, config and config.configurations, "harmony"),
            }
        end,
    },
    typescript = {
        id = "typescript",
        has_keyed_tools = false,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type then return name end
            end
            return nil
        end,
        info = function(_, config)
            local defaults = {
                default = { prefix = "variant", variant = "default" },
            }
            return {
                configurations = Configuration.canonicalize(
                    defaults, config and config.configurations, "typescript"),
            }
        end,
    },
}

-- Register mock modules into the global registry too. Some module
-- consumers (merge.lua, profile.lua, overseer.lua) read through
-- `require("loomworks.modules")` directly rather than going through
-- the injected `_deps.modules`, so an inline mock that only
-- intercepts `_deps.modules.get` leaves those paths unmocked. After
-- the ohos extraction the `harmony` module no longer lives in this
-- repo at all; the global lookup MUST hit a registered mock for
-- these tests to work.
do
    local registry = require("loomworks.modules")
    for id, mod in pairs(mock_modules) do
        registry.register(id, mod)
    end
end

--- Common detected tool entries for tests that need tool-qualified profiles.
--- Format matches what merge.get_all_profiles expects in _tools_by_type.
local function make_detected_tools(entries)
    local result = {}
    for _, e in ipairs(entries) do
        local mod_type = e.mod_type or "cmake"
        result[mod_type] = result[mod_type] or {}
        result[mod_type][#result[mod_type] + 1] = {
            tool_key = e.tool_key,
            tool_data = e.tool_data or { id = e.tool_key },
            tool_label = e.tool_label or e.tool_key,
        }
    end
    return result
end

--- Create a real Workspace instance with mock deps for testing.
--- @param config_overrides? table
--- @param user_overrides? table
--- @param cache_overrides? table
--- @param opts? { detected_tools?: table<string, table[]> }
--- @return loomworks.Workspace, table events_log
local function make_ws(config_overrides, user_overrides, cache_overrides, opts)
    opts = opts or {}
    local config_json = h.make_config_json(config_overrides)
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil
    local cache_json = cache_overrides and h.make_cache_json(cache_overrides) or nil

    local data = workspace.assemble("/root", config_json, user_json, cache_json, { trust = require("tests.helpers").trust_all })
    assert(data, "assemble failed")

    local events_log = {}
    local mock_core = {
        _deps = {
            merge = merge,
            -- Never write the fake `/root` (C:\root on Windows): no real cache
            -- save, no real lockfiles.
            cache = setmetatable({ save = function() return true end }, { __index = cache_mod }),
            locks = require("loomworks.op_lock").INERT,
            events = {
                emit = function(event, ev_data)
                    events_log[#events_log + 1] = { event = event, data = ev_data }
                end,
            },
            user = { save = function() return true end },
            io = {
                write_json = function() return true end,
                ensure_dir = function() return true end,
                rm_rf_async = function(_, cb) cb(true, nil) end,
            },
            normalize = function(p) return p end,
            modules = { get = function(id) return mock_modules[id] end },
            notify = function() end,
            schedule = function(fn) fn() end,
            clock = function() return 0 end,
            now = function() return "2000-01-01T00:00:00Z" end,
            log = require("loomworks.log").test(),
            -- Fake `/root` build paths never exist on disk; report them present
            -- so cached built/configured state survives remerge. The missing-
            -- build-dir reset (spec §3.1 rule 7) is covered by its own spec.
            dir_exists = function() return true end,
        },
        _events_log = events_log,
    }

    local ws = Workspace.new(mock_core, data)
    if opts.detected_tools then
        ws._tools_by_type = opts.detected_tools
    end
    ws:_cleanup_orphaned_skeletons(data.cache)
    ws:remerge(data.config, data.cache, data.user)
    return ws, events_log
end

-- =========================================================================
-- Config set lifecycle: create → edit → rename → delete
-- =========================================================================


describe("config set lifecycle", function()
    it("create → edit → rename → delete", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Frontend = { harmony = {} },
            },
        })

        -- 1. Create config set with auto-detected mappings
        local app = h.find_project_in(ws:get_projects(), "App")
        local frontend = h.find_project_in(ws:get_projects(), "Frontend")

        local cs, err = wv.execute_create_config_set(ws, "Debug", {
            [app] = app:get_configuration("variant:Debug"),
            [frontend] = frontend:get_configuration("auto:debug"),
        })
        assert.is_not_nil(cs)
        assert.is_not_nil(h.find_config_set_in(ws:get_config_sets(),"Debug"))

        -- 2. Edit: change Frontend mapping
        local cs0 = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.equals("variant:Debug", h.cs_mapping(cs0, "App"))
        assert.equals("auto:debug", h.cs_mapping(cs0, "Frontend"))

        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        ok = wv.execute_edit_config_set(cs, "Debug",
            { [app] = app:get_configuration("variant:Release"), [frontend] = frontend:get_configuration("auto:release") })
        assert.is_true(ok)
        local debug_cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.equals("variant:Release", h.cs_mapping(debug_cs, "App"))
        assert.equals("auto:release", h.cs_mapping(debug_cs, "Frontend"))

        -- 3. Rename: Debug → Production
        cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        ok = wv.execute_edit_config_set(cs, "Production",
            { [app] = app:get_configuration("variant:Release"), [frontend] = frontend:get_configuration("auto:release") })
        assert.is_true(ok)
        assert.is_nil(h.find_config_set_in(ws:get_config_sets(), "Debug"))
        assert.is_not_nil(h.find_config_set_in(ws:get_config_sets(), "Production"))

        -- 4. Delete
        local prod_cs = h.find_config_set_in(ws:get_config_sets(),"Production")
        ok = wv.execute_delete_config_set(ws, prod_cs)
        assert.is_true(ok)
        -- Last set removed
        assert.is_nil(h.find_config_set_in(ws:get_config_sets(), "Production"))
    end)

    it("renaming config set updates profile key and survives round-trip", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Frontend = { harmony = {} },
                },
                configuration_sets = {
                    Debug = { App = "Debug", Frontend = "debug" },
                },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug")
        assert.is_not_nil(profile)
        assert.equals("Debug", profile.key)
        assert.equals(2, #profile:projects())

        -- Rename config set: Debug → Release
        cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        local app = h.find_project_in(ws:get_projects(), "App")
        local frontend = h.find_project_in(ws:get_projects(), "Frontend")
        local ok = wv.execute_edit_config_set(cs, "Release",
            { [app] = app:get_configuration("variant:Debug"), [frontend] = frontend:get_configuration("auto:debug") })
        assert.is_true(ok)

        -- Config set should be renamed
        assert.is_nil(h.find_config_set_in(ws:get_config_sets(), "Debug"))
        local new_cs = h.find_config_set_in(ws:get_config_sets(), "Release")
        assert.is_not_nil(new_cs)

        -- Profile key must have updated to match new set name
        local new_profile = h.find_profile(ws:get_profiles(), "Release")
        assert.is_not_nil(new_profile, "Profile key should be renamed to 'Release'")
        assert.is_nil(h.find_profile(ws:get_profiles(), "Debug"),
            "Old profile key 'Debug' should no longer exist")

        -- Profile must still have its projects
        assert.equals(2, #new_profile:projects())

        -- Active profile key must track the rename
        assert.equals("Release", ws._active_profile_key)

        -- Round-trip: serialize cache and simulate reload
        local cache = ws:_serialize_cache()
        assert.is_not_nil(h.find_profile(ws._profiles, "Release"),
            "Serialized cache should have profile under new key 'Release'")
        assert.is_nil(h.find_profile(ws._profiles, "Debug"),
            "Serialized cache should not have profile under old key 'Debug'")
        local release_profile = h.find_profile(ws._profiles, "Release")
        assert.is_not_nil(release_profile)
        assert.equals("Release", release_profile._configuration_set_name)
    end)

    it("create validates duplicate names", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        })

        local app = h.find_project_in(ws:get_projects(), "App")
        local cs, err = wv.execute_create_config_set(ws, "Debug", {
            [app] = app:get_configuration("variant:Debug"),
        })
        assert.is_nil(cs)
        assert.is_not_nil(err)
    end)

    it("edit removes mappings set to nil", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Frontend = { harmony = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug", Frontend = "debug" },
            },
        })

        local app = h.find_project_in(ws:get_projects(), "App")
        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        local ok = wv.execute_edit_config_set(cs, "Debug",
            { [app] = app:get_configuration("variant:Debug") }) -- Frontend removed
        assert.is_true(ok)
        local debug_cs2 = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_nil(h.cs_mapping(debug_cs2, "Frontend"))
    end)
end)

-- =========================================================================
-- Profile lifecycle: create from config set → verify state
-- =========================================================================

describe("profile lifecycle", function()
    it("create profile from config set without tools", function()
        local ws = make_ws(
            {
                projects = { Frontend = { harmony = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug")
        assert.is_not_nil(profile)
        assert.equals("Debug", profile.key)
        assert.equals("Debug", ws._active_profile_key)
    end)

    it("materialized profile has projects and config units from config set", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Frontend = { harmony = {} },
                },
                configuration_sets = {
                    Debug = { App = "Debug", Frontend = "debug" },
                },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            },
            {
                configurations = {
                    ["App/Debug"] = { project_key = "App", config_key = "Debug", variant = "Debug", type = "cmake", state = "configured" },
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", variant = "debug", type = "harmony", state = "configured" },
                },
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug")
        assert.is_not_nil(profile)
        assert.equals("Debug", profile.key)

        -- Profile must have ProfileProjects for both config set projects
        local pps = profile:projects()
        assert.equals(2, #pps)

        -- Each PP must have a resolved project and config unit
        local found_app, found_frontend = false, false
        for _, pp in ipairs(pps) do
            assert.is_not_nil(pp._project, "PP must have resolved project")
            assert.is_not_nil(pp._config_unit, "PP must have config unit")
            assert.is_not_nil(pp._config_unit._config_key, "ConfigUnit must have config_key")
            if pp._project.key == "App" then
                found_app = true
                assert.equals("Debug", pp:variant_name())
            elseif pp._project.key == "Frontend" then
                found_frontend = true
                assert.equals("debug", pp:variant_name())
            end
        end
        assert.is_true(found_app, "Profile must include App project")
        assert.is_true(found_frontend, "Profile must include Frontend project")

        -- Config units must be registered in workspace
        local app_unit, frontend_unit
        for _, unit in pairs(ws._config_units) do
            if unit._init_project_key == "App" then app_unit = unit end
            if unit._init_project_key == "Frontend" then frontend_unit = unit end
        end
        assert.is_not_nil(app_unit, "App ConfigUnit must be registered")
        assert.is_not_nil(frontend_unit, "Frontend ConfigUnit must be registered")

        -- Cache must contain entries for both
        local cache = ws:_serialize_cache()
        local found_configs = 0
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "App" or entry.project_key == "Frontend" then
                found_configs = found_configs + 1
            end
        end
        assert.equals(2, found_configs, "Cache must have entries for both projects")
    end)

    it("materialized profile with tool has correct tool-qualified config units", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Frontend = { harmony = {} },
                },
                configuration_sets = {
                    Debug = { App = "Debug", Frontend = "debug" },
                },
            },
            {
                active_profile = "Debug:ninja-gcc",
                profiles = {
                    ["Debug:ninja-gcc"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc", data = { generator = "Ninja" } } },
                    },
                },
            },
            {
                configurations = {
                    ["App/Debug:ninja-gcc"] = {
                        project_key = "App", config_key = "Debug:ninja-gcc", variant = "Debug", type = "cmake",
                        tool_key = "ninja-gcc", tool_data = { generator = "Ninja" },
                        state = "configured",
                    },
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", variant = "debug", type = "harmony", state = "configured" },
                },
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc", tool_data = { generator = "Ninja" } },
                }),
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug:ninja-gcc")
        assert.is_not_nil(profile)

        local pps = profile:projects()
        assert.equals(2, #pps)

        -- App (cmake) should have tool-qualified config key
        -- Frontend (harmony) should have bare config key
        for _, pp in ipairs(pps) do
            if pp._project.key == "App" then
                assert.truthy(pp._config_unit:config_key():find("ninja%-gcc"),
                    "cmake project should have tool-qualified config key")
            elseif pp._project.key == "Frontend" then
                assert.equals("debug", pp._config_unit:config_key(),
                    "harmony project should have bare config key")
            end
        end
    end)

    it("create profile from config set with tool", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Frontend = { harmony = {} },
                },
                configuration_sets = {
                    Debug = { App = "Debug", Frontend = "debug" },
                },
            },
            {
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12", display = "Ninja - GCC 12" } } },
                    },
                },
            },
            {
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "harmony", variant = "debug",
                    },
                },
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12", display = "Ninja - GCC 12" } },
                }),
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug:ninja-gcc-12")
        assert.is_not_nil(profile)
        -- Profile key should include tool
        assert.truthy(profile.key:find("ninja%-gcc%-12"))
    end)
end)

-- =========================================================================
-- Profile upgrade/downgrade when adding/removing keyed-tool projects
-- =========================================================================

describe("profile upgrade and downgrade", function()
    local tool_entry = {
        tool_key = "ninja-gcc-12",
        tool_data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" },
        tool_label = "Ninja - GCC 12",
        tool_mod_type = "cmake",
    }

    pending("adding keyed-tool project upgrades profiles and creates skeletons", function()
        local ws = make_ws(
            {
                projects = { Frontend = { harmony = {} } },
                configuration_sets = {
                    Debug = { Frontend = "debug" },
                },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            },
            {
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "harmony", variant = "debug", state = "configured",
                    },
                },
            }
        )

        -- Add cmake project with tool
        local result = {
            mappings = { Debug = "Debug" },
            tool_entry = tool_entry,
        }
        local ok = wv.execute_add_project(ws, "App", "cmake", nil, result, true)
        assert.is_true(ok)

        -- Profile upgraded: Debug → Debug:ninja-gcc-12
        local cache = ws:_serialize_cache()
        assert.is_nil(h.find_profile(ws._profiles, "Debug"))
        assert.is_not_nil(h.find_profile(ws._profiles, "Debug:ninja-gcc-12"))
        assert.equals("Debug:ninja-gcc-12", ws._active_profile_key)

        -- Skeleton cache entry created for cmake project (build_dir-keyed)
        local cmake_entry = nil
        local frontend_entry = nil
        local frontend_tooled = false
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "App" and entry.variant == "Debug"
                    and entry.tool_key == "ninja-gcc-12" then
                cmake_entry = entry
            end
            if entry.project_key == "Frontend" and entry.variant == "debug" then
                frontend_entry = entry
                if entry.tool_key then frontend_tooled = true end
            end
        end
        assert.is_not_nil(cmake_entry, "cmake skeleton should exist")
        assert.equals("cmake", cmake_entry.type)

        -- Non-keyed entry preserved without tool suffix
        assert.is_not_nil(frontend_entry, "Frontend entry should exist")
        assert.is_false(frontend_tooled, "Frontend should not have tool key")
    end)

    it("removing last keyed-tool project downgrades profiles", function()
        local ws = make_ws(
            {
                projects = {
                    Frontend = { harmony = {} },
                    App = { cmake = {} },
                },
                configuration_sets = {
                    Debug = { Frontend = "debug", App = "Debug" },
                },
            },
            {
                active_profile = "Debug:ninja-gcc-12",
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" } } },
                    },
                },
            },
            {
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "harmony", variant = "debug",
                    },
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App", config_key = "Debug:ninja-gcc-12",
                        type = "cmake", variant = "Debug",
                    },
                },
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" } },
                }),
            }
        )

        local app = h.find_project_in(ws:get_projects(), "App")
        assert.equals(1, #dp.plan(ws, { project = app }).downgrade)

        local r = run_deletion(ws, { project = app })
        assert.equals("ok", r.outcome, r.message)

        -- Profile downgraded: Debug:ninja-gcc-12 → Debug
        local cache = ws:_serialize_cache()
        assert.is_nil(h.find_profile(ws._profiles, "Debug:ninja-gcc-12"))
        assert.is_not_nil(h.find_profile(ws._profiles, "Debug"))
        assert.is_nil(h.find_profile(ws._profiles, "Debug").tools)
        assert.equals("Debug", ws._active_profile_key)
    end)

    -- "pinned ad-hoc profiles are not affected by upgrade" test removed:
    -- pinned profiles no longer exist

    it("downgrade is no-op when other keyed-module projects remain", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Lib = { cmake = {} },
                },
                configuration_sets = { Debug = { App = "Debug", Lib = "Debug" } },
            },
            {
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" } } },
                    },
                },
            },
            {
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = { project_key = "App", config_key = "Debug:ninja-gcc-12", variant = "Debug", type = "cmake" },
                    ["Lib/Debug:ninja-gcc-12"] = { project_key = "Lib", config_key = "Debug:ninja-gcc-12", variant = "Debug", type = "cmake" },
                },
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" } },
                }),
            }
        )

        ws:downgrade_profiles_from_tool("cmake")

        -- Profile unchanged — Lib still uses cmake
        local cache = ws:_serialize_cache()
        assert.is_not_nil(h.find_profile(ws._profiles, "Debug:ninja-gcc-12"))
        assert.is_nil(h.find_profile(ws._profiles, "Debug"))
    end)
end)

-- =========================================================================
-- Orphan lifecycle: delete config set → orphans appear → clean up
-- =========================================================================

describe("orphan lifecycle", function()
    pending("deleting config set orphans configs, cleanup removes them", function()
        -- Scenario: two config sets reference the same project config.
        -- One profile references via "Debug" set, one via "Staging".
        -- A third cache entry is unreferenced (orphan from branch switch).
        local ws = make_ws(
            {
                projects = { Frontend = { harmony = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            },
            {
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "harmony", variant = "debug", state = "built",
                        build_dir = "/root/.nvim/build/Frontend/debug",
                    },
                    -- Orphan: cache entry from a branch switch, no profile references it
                    ["Frontend/release"] = {
                        project_key = "Frontend", config_key = "release",
                        type = "harmony", variant = "release", state = "built",
                        build_dir = "/root/.nvim/build/Frontend/release",
                    },
                },
            }
        )

        -- "release" config is orphaned (no profile references it)
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans)
        assert.equals("Frontend", orphans[1].project_key)
        assert.equals("release", orphans[1].config_key)

        -- Plan the cleanup
        assert.equals(1, #dp.plan(ws, { orphans = true }).orphans)

        -- Execute cleanup
        local r = run_deletion(ws, { orphans = true })
        assert.equals("ok", r.outcome, r.message)

        -- Orphan cleaned, referenced config still exists
        assert.equals(0, #ws:get_orphaned_configs())
        local cache = ws:_serialize_cache()
        local found_debug = false
        local found_release = false
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "Frontend" and entry.variant == "debug" then found_debug = true end
            if entry.project_key == "Frontend" and entry.variant == "release" then found_release = true end
        end
        assert.is_true(found_debug, "referenced config should survive cleanup")
        assert.is_false(found_release, "orphan should be cleaned from cache")
    end)

    pending("editing config set mappings can create orphans", function()
        local ws = make_ws(
            {
                projects = { Frontend = { harmony = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            nil,
            {
                profiles = {
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "harmony", variant = "debug", state = "configured",
                    },
                },
            }
        )

        -- Change mapping from "debug" to "release"
        local frontend = h.find_project_in(ws:get_projects(), "Frontend")
        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        local ok = wv.execute_edit_config_set(cs, "Debug",
            { [frontend] = frontend:get_configuration("auto:release") })
        assert.is_true(ok)
        local debug_cs3 = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.equals("auto:release", h.cs_mapping(debug_cs3, "Frontend"))

        -- Frontend/debug is now orphaned (profile references "release", not "debug")
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans)
        assert.equals("debug", orphans[1].config_key)
    end)
end)

-- =========================================================================
-- Confirmation context builders
-- =========================================================================


-- Opaque key test: arbitrary keys with no semantic structure
-- =========================================================================

describe("opaque keys", function()
    -- Arbitrary project keys, config set names, tool keys, and variant names.
    -- Proves the system doesn't depend on naming conventions for runtime navigation.
    -- Profile keys are derived from config_set × tools; build_dir keys are
    -- computed from project/tool/variant — both are determined at runtime.

    local function make_opaque_ws()
        -- Derived profile key: "set-x:tool-7" (from set_name + cmake tool key)
        local detected = make_detected_tools({
            { tool_key = "tool-7", tool_data = { id = "tool-7", display = "Tool Seven", generator = "Ninja" }, tool_label = "Tool Seven" },
        })
        return make_ws({
            projects = {
                ["proj-alpha"] = { cmake = {} },
                ["proj-beta"] = { harmony = {} },
            },
            configuration_sets = {
                ["set-x"] = {
                    ["proj-alpha"] = "variant:Debug",
                    ["proj-beta"] = "auto:debug",
                },
            },
        }, {
            active_profile = "set-x:tool-7",
            profiles = {
                ["set-x:tool-7"] = {
                    configuration_set = "set-x",
                    tools = { cmake = { key = "tool-7", data = { id = "tool-7", display = "Tool Seven", generator = "Ninja" } } },
                },
            },
        }, {
            -- Build-dir keys carry the canonical configuration name
            -- after prefix namespacing — `variant:Debug:tool-7`,
            -- `auto:debug`. The system stores them as opaque strings;
            -- the test still proves that lookup doesn't care what the
            -- string looks like.
            build_dirs = {
                ["build/proj-alpha/tool-7/variant:Debug"] = {
                    project_key = "proj-alpha",
                    config_key = "variant:Debug:tool-7",
                    type = "cmake", variant = "Debug", tool_key = "tool-7",
                    state = "built",
                    tool_data = { id = "tool-7", display = "Tool Seven", generator = "Ninja" },
                },
                ["build/proj-beta/auto:debug"] = {
                    project_key = "proj-beta", config_key = "auto:debug",
                    type = "harmony", variant = "debug",
                    state = "configured",
                },
            },
        }, {
            detected_tools = detected,
        })
    end

    it("loads workspace with arbitrary keys", function()
        local ws = make_opaque_ws()
        assert.is_not_nil(ws)

        -- Projects resolved
        assert.is_not_nil(h.find_project_in(ws:get_projects(), "proj-alpha"))
        assert.equals("cmake", h.find_project_in(ws:get_projects(), "proj-alpha").type)
        assert.is_not_nil(h.find_project_in(ws:get_projects(), "proj-beta"))
        assert.equals("harmony", h.find_project_in(ws:get_projects(), "proj-beta").type)
    end)

    it("resolves active profile and its projects", function()
        local ws = make_opaque_ws()
        local profile = ws:get_active_profile()
        assert.is_not_nil(profile)
        assert.equals("set-x:tool-7", profile.key)

        local pps = profile:projects()
        assert.equals(2, #pps)

        -- ProfileProjects have correct variants
        local variants = {}
        for _, pp in ipairs(pps) do
            variants[pp._project.key] = pp:variant_name()
        end
        assert.equals("variant:Debug", variants["proj-alpha"])
        assert.equals("auto:debug", variants["proj-beta"])
    end)

    it("ProfileProject references resolve correctly", function()
        local ws = make_opaque_ws()
        local profile = ws:get_active_profile()

        local pp_alpha = profile:project("proj-alpha")
        assert.is_not_nil(pp_alpha)
        assert.is_not_nil(pp_alpha._config_unit)
        assert.is_not_nil(pp_alpha._project)
        assert.equals("proj-alpha", pp_alpha._project.key)

        -- ConfigUnit has first-class fields with arbitrary key
        local unit = pp_alpha._config_unit
        assert.is_not_nil(unit)
        assert.equals("built", unit.state_value)
        assert.equals("/root/.nvim/build/proj-alpha/tool-7/variant:Debug", unit.build_dir_value)
    end)

    it("ConfigUnit state resolves through arbitrary cache keys", function()
        local ws = make_opaque_ws()
        local profile = ws:get_active_profile()

        local pp_alpha = profile:project("proj-alpha")
        assert.equals("built", pp_alpha:status())

        local pp_beta = profile:project("proj-beta")
        assert.equals("configured", pp_beta:status())
    end)

    it("Project:config_units_for_configuration finds units with arbitrary keys", function()
        local ws = make_opaque_ws()
        local proj = h.find_project_in(ws:get_projects(), "proj-alpha")
        local cfg = proj:get_configuration("variant:Debug")
        assert.is_not_nil(cfg)
        local units = proj:config_units_for_configuration(cfg)
        assert.equals(1, #units)
        assert.equals("variant:Debug:tool-7", units[1]:config_key())
    end)

    it("build_dir_refs track arbitrary cache entries", function()
        local ws = make_opaque_ws()
        local refs = ws:get_build_dir_refs("/root/.nvim/build/proj-alpha/tool-7/variant:Debug")
        assert.equals(1, #refs)
        assert.equals("variant:Debug:tool-7", refs[1]:config_key())
    end)

    it("config set mapping updates work with arbitrary project keys", function()
        local ws = make_opaque_ws()
        local cs = h.find_config_set_in(ws:get_config_sets(),"set-x")
        assert.is_not_nil(cs)

        local proj = h.find_project_in(ws:get_projects(), "proj-alpha")
        local release_cfg = proj:get_configuration("variant:Release")
        assert.is_not_nil(release_cfg)
        cs:update_mapping(proj, release_cfg)

        -- Verify mapping changed
        assert.equals("variant:Release", cs.mappings[proj].name)
    end)

    it("save_configuration works on project with arbitrary keys", function()
        local ws = make_opaque_ws()
        local proj = h.find_project_in(ws:get_projects(), "proj-alpha")

        local ok = proj:save_configuration("custom-cfg", {
            options = { MY_FLAG = "ON" },
        })
        assert.is_true(ok)
        local cfg = proj:get_configuration("custom-cfg")
        assert.is_not_nil(cfg)
        assert.is_true(cfg.is_user)
    end)

    it("rename_configuration propagates with arbitrary keys", function()
        local ws = make_opaque_ws()
        local proj = h.find_project_in(ws:get_projects(), "proj-alpha")

        -- Add a user-defined config to rename
        proj:save_configuration("temp-name", { options = { X = "1" } })

        local ok = proj:rename_configuration("temp-name", "new-name", {
            options = { X = "1" },
        })
        assert.is_true(ok)
        assert.is_nil(proj:get_configuration("temp-name"))
        local new_cfg = proj:get_configuration("new-name")
        assert.is_not_nil(new_cfg)
        assert.is_true(new_cfg.is_user)
    end)

    it("delete preserves arbitrary build dirs in cache", function()
        local ws = make_opaque_ws()
        local deleted_dirs = {}
        ws._core._deps.io.rm_rf_async = function(dir, cb)
            deleted_dirs[#deleted_dirs + 1] = dir
            cb(true, nil)
        end

        -- Delete cfg-42's config via profile deletion
        local profile = ws:get_active_profile()
        assert.is_not_nil(profile)

        local done = false
        profile:delete(function() done = true end)
        assert.is_true(done)

        -- Build dir should have been cleaned
        assert.is_true(#deleted_dirs > 0)
    end)

    it("serialization round-trips with arbitrary keys", function()
        local ws = make_opaque_ws()
        local raw = ws:_serialize_config()

        -- Projects preserved
        assert.is_not_nil(raw.projects["proj-alpha"])
        assert.is_not_nil(raw.projects["proj-beta"])

        -- Config sets preserved — the canonical `variant:Debug`
        -- round-trips through serialisation intact.
        assert.is_not_nil(raw.configuration_sets["set-x"])
        assert.equals("variant:Debug",
            raw.configuration_sets["set-x"]["proj-alpha"])
    end)
end)

-- =========================================================================
-- Two-layer merge: user.json + loomworks.json
-- =========================================================================

describe("two-layer merge", function()
    it("shared-only projects have _source = shared", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        assert.equals("shared", app._source)
    end)

    it("user project has _source = user", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },  -- shared
            { projects = { MyLib = { cmake = {} } } }  -- user
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        assert.is_not_nil(app)
        assert.is_not_nil(mylib)
        assert.equals("shared", app._source)
        assert.equals("user", mylib._source)
    end)

    it("user project overrides shared project with same key", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },  -- shared
            { projects = { App = { harmony = {} } } }  -- user overrides type
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        assert.equals("harmony", app.type)
        assert.equals("user", app._source)
    end)

    it("user config_set has _source = user", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { SharedDebug = { App = "Debug" } },
            },
            {
                configuration_sets = { UserDebug = { App = "Release" } },
            }
        )
        local shared_cs = h.find_config_set_in(ws:get_config_sets(), "SharedDebug")
        local user_cs = h.find_config_set_in(ws:get_config_sets(), "UserDebug")
        assert.is_not_nil(shared_cs)
        assert.is_not_nil(user_cs)
        assert.equals("shared", shared_cs._source)
        assert.equals("user", user_cs._source)
    end)

    it("user config_set overrides shared config_set with same name", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                configuration_sets = { Debug = { App = "variant:Release" } },
            }
        )
        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_not_nil(cs)
        assert.equals("user", cs._source)
        -- The mapping should reflect the user override
        assert.equals("variant:Release", h.cs_mapping(cs, "App"))
    end)

    it("serialize_config excludes user-sourced projects", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { projects = { MyLib = { cmake = {} } } }
        )
        local raw = ws:_serialize_config()
        assert.is_not_nil(raw.projects.App)
        assert.is_nil(raw.projects.MyLib)
    end)

    it("serialize_config excludes user-sourced config_sets", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { SharedDebug = { App = "Debug" } },
            },
            {
                configuration_sets = { UserDebug = { App = "Release" } },
            }
        )
        local raw = ws:_serialize_config()
        assert.is_not_nil(raw.configuration_sets.SharedDebug)
        assert.is_nil(raw.configuration_sets and raw.configuration_sets.UserDebug)
    end)

    it("serialize_user includes pin-reachable user-sourced projects", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            {
                projects = { MyLib = { cmake = {} } },
                configuration_sets = { dev = { MyLib = "Debug" } },
                profiles = { dev = { configuration_set = "dev" } },
            }
        )
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.projects)
        assert.is_not_nil(user_data.projects.MyLib)
        assert.is_nil(user_data.projects and user_data.projects.App)
    end)

    it("serialize_user includes all local-intent projects", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { projects = { MyLib = { cmake = {} } } }
        )
        -- No pins but MyLib is in user.json → still serialized
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.projects)
        assert.is_not_nil(user_data.projects.MyLib)
        -- App is shared-only, not in user.json
        assert.is_nil(user_data.projects.App)
    end)

    it("serialize_user includes pin-reachable user-sourced config_sets", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { SharedDebug = { App = "Debug" } },
            },
            {
                configuration_sets = { UserDebug = { App = "Release" } },
                profiles = { ["UserDebug"] = { configuration_set = "UserDebug" } },
            }
        )
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.configuration_sets)
        assert.is_not_nil(user_data.configuration_sets.UserDebug)
        assert.is_nil(user_data.configuration_sets and user_data.configuration_sets.SharedDebug)
    end)

    it("solo dev: pinned items from user.json serialized, no shared projects", function()
        local ws = make_ws(
            { projects = {} },  -- empty shared
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "Debug" } },
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        assert.equals("user", app._source)

        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_not_nil(cs)
        assert.equals("user", cs._source)

        -- Shared config should be empty
        local raw = ws:_serialize_config()
        assert.is_falsy(next(raw.projects))

        -- User config should contain pin-reachable items
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.projects.App)
        assert.is_not_nil(user_data.configuration_sets.Debug)
    end)

    it("remerge after mutation preserves two-layer source", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { projects = { MyLib = { cmake = {} } } }
        )
        -- Remerge without raw config (simulates tool detection callback)
        ws:remerge()

        local app = h.find_project_in(ws:get_projects(), "App")
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        assert.is_not_nil(app)
        assert.is_not_nil(mylib)
        assert.equals("shared", app._source)
        assert.equals("user", mylib._source)
    end)

    -- Published flag tests
    it("shared-only project has intent shared", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        assert.equals("shared", app._intent)
    end)

    it("user-only project has intent local", function()
        local ws = make_ws(
            { projects = {} },
            { projects = { MyLib = { cmake = {} } } }
        )
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        assert.is_not_nil(mylib)
        assert.equals("local", mylib._intent)
        -- _in_user_json replaced by _intent
    end)

    it("shared baseline is captured from raw config", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        })
        assert.is_not_nil(ws._shared_baseline)
        assert.is_not_nil(ws._shared_baseline.projects.App)
        assert.is_not_nil(ws._shared_baseline.configuration_sets.Debug)
    end)

    it("shared-only config set has intent shared", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        })
        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_not_nil(cs)
        assert.equals("shared", cs._intent)
    end)

    it("user-only config set has intent local", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { configuration_sets = { UserDebug = { App = "Debug" } } }
        )
        local cs = h.find_config_set_in(ws:get_config_sets(), "UserDebug")
        assert.is_not_nil(cs)
        assert.equals("local", cs._intent)
        -- _in_user_json replaced by _intent
    end)

    it("per-config merge: shared and user configs combine", function()
        local ws = make_ws(
            {
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = {},
                                Release = {},
                            },
                        },
                    },
                },
            },
            {
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = { toolchain = "user-tc" },
                                Asan = { inherits = "Debug" },
                            },
                        },
                    },
                },
            }
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        -- All configs should be present (shared Release + user Debug + user Asan + defaults)
        local config_names = {}
        for _, cfg in ipairs(app._configurations) do
            config_names[cfg.name] = true
        end
        assert.is_true(config_names["Debug"])
        assert.is_true(config_names["Release"])
        assert.is_true(config_names["Asan"])
    end)

    it("per-config _intent set from baseline", function()
        local ws = make_ws(
            {
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = {},
                                Release = {},
                            },
                        },
                    },
                },
            },
            {
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = { toolchain = "user-tc" },
                                Asan = { inherits = "Debug" },
                            },
                        },
                    },
                },
            }
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        for _, cfg in ipairs(app._configurations) do
            if cfg.name == "Debug" or cfg.name == "Release" then
                -- These are in the shared baseline
                assert.is_true(cfg._intent ~= "local", cfg.name .. " should be published")
            end
            if cfg.name == "Asan" then
                -- This is user-only
                assert.is_false(cfg._intent ~= "local", "Asan should not be published")
            end
        end
    end)

    it("per-config _intent set from provenance", function()
        local ws = make_ws(
            {
                projects = {
                    App = {
                        cmake = {
                            configurations = { Release = {} },
                        },
                    },
                },
            },
            {
                projects = {
                    App = {
                        cmake = {
                            configurations = { Debug = { toolchain = "tc" } },
                        },
                    },
                },
            }
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        for _, cfg in ipairs(app._configurations) do
            if cfg.name == "Debug" then
                assert.is_true(cfg._intent ~= "shared", "Debug should be in user json")
            end
            if cfg.name == "Release" then
                assert.is_false(cfg._intent ~= "shared", "Release should not be in user json")
            end
        end
    end)
end)

-- =========================================================================
-- Modified state computation
-- =========================================================================

describe("modified state", function()
    it("shared-only project is not modified (synced)", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_false(ws:is_project_modified(app))
        assert.is_false(ws:has_any_modified())
    end)

    it("user-only unpublished project is not modified", function()
        local ws = make_ws(
            { projects = {} },
            { projects = { MyLib = { cmake = {} } } }
        )
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        -- unpublished + not in baseline = no-op
        assert.is_false(ws:is_project_modified(mylib))
    end)

    it("published project not in baseline is modified (will add)", function()
        local ws = make_ws(
            { projects = {} },
            { projects = { MyLib = { cmake = {} } } }
        )
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        mylib._intent = "local+shared"
        assert.is_true(ws:is_project_decl_modified(mylib))
        assert.is_true(ws:is_project_modified(mylib))
        assert.is_true(ws:has_any_modified())
    end)

    it("unpublished project in baseline is modified (will remove)", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })
        local app = h.find_project_in(ws:get_projects(), "App")
        app._intent = "local"
        assert.is_true(ws:is_project_decl_modified(app))
        assert.is_true(ws:has_any_modified())
    end)

    it("published config not in baseline is modified", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
            },
            {
                projects = {
                    App = { cmake = { configurations = { Asan = { inherits = "Debug" } } } },
                },
            }
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        -- Find Asan config
        local asan
        for _, cfg in ipairs(app._configurations) do
            if cfg.name == "Asan" then asan = cfg end
        end
        assert.is_not_nil(asan)
        assert.equals("local", asan._intent)
        -- Local intent + not in baseline = not modified
        assert.is_false(ws:is_config_modified(app, asan))
        -- Mark as published → modified (will add)
        asan._intent = "local+shared"
        assert.is_true(ws:is_config_modified(app, asan))
    end)

    it("published config matching baseline is not modified", function()
        local ws = make_ws({
            projects = {
                App = { cmake = { configurations = { Debug = {} } } },
            },
        })
        local app = h.find_project_in(ws:get_projects(), "App")
        local debug_cfg
        for _, cfg in ipairs(app._configurations) do
            if cfg.name == "Debug" then debug_cfg = cfg end
        end
        assert.is_not_nil(debug_cfg)
        assert.is_true(debug_cfg._intent ~= "local")
        assert.is_false(ws:is_config_modified(app, debug_cfg))
    end)

    it("config set matching baseline is not modified", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        })
        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_false(ws:is_config_set_modified(cs))
    end)

    it("user-only unpublished config set is not modified", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { configuration_sets = { UserSet = { App = "Debug" } } }
        )
        local cs = h.find_config_set_in(ws:get_config_sets(), "UserSet")
        assert.is_false(ws:is_config_set_modified(cs))
    end)

    it("published user config set is modified (will add)", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { configuration_sets = { UserSet = { App = "Debug" } } }
        )
        local cs = h.find_config_set_in(ws:get_config_sets(), "UserSet")
        cs._intent = "local+shared"
        assert.is_true(ws:is_config_set_modified(cs))
        assert.is_true(ws:has_any_modified())
    end)

    it("modified config bubbles up to project", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = { configurations = { Debug = {} } } } },
            },
            {
                projects = {
                    App = { cmake = { configurations = {
                        Debug = { toolchain = "changed" },
                    } } },
                },
            }
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        -- Debug is published (in baseline) but content differs → modified
        local debug_cfg
        for _, cfg in ipairs(app._configurations) do
            if cfg.name == "Debug" then debug_cfg = cfg end
        end
        assert.is_true(debug_cfg._intent ~= "local")
        assert.is_true(ws:is_config_modified(app, debug_cfg))
        -- Bubbles up
        assert.is_true(ws:is_project_modified(app))
    end)

    it("intent is persisted in user data", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { projects = { MyLib = { cmake = {} } } }
        )
        -- MyLib is user-only, unpublished by default
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        assert.equals("local", mylib._intent)

        -- Toggle publish
        mylib._intent = "local+shared"
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.intent)
        assert.equals("local+shared", user_data.intent.projects.MyLib)

        -- App is shared, published by default — no override stored
        assert.is_nil(user_data.intent.projects.App)
    end)

    it("intent overrides are restored on remerge", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            {
                projects = { MyLib = { cmake = {} } },
                intent = { projects = { MyLib = "local+shared" } },
            }
        )
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        assert.is_not_nil(mylib)
        assert.equals("local+shared", mylib._intent)
    end)
end)

-- =========================================================================
-- Deploy steps
-- =========================================================================


-- Project variables
-- =========================================================================

describe("project variables", function()
    local variables = require("loomworks.variables")

    describe("validation", function()
        it("accepts valid declarations", function()
            local ok = variables.validate_declarations({
                output_dir = { type = "path", default = "${project_path}/dist" },
                debug_port = { type = "string", default = "9229" },
            })
            assert.is_true(ok)
        end)

        it("rejects reserved name", function()
            local ok, err = variables.validate_declarations({
                workspace_root = { type = "string", default = "bad" },
            })
            assert.is_false(ok)
            assert.truthy(err:find("reserved"))
        end)

        it("rejects invalid type", function()
            local ok, err = variables.validate_declarations({
                foo = { type = "number", default = "42" },
            })
            assert.is_false(ok)
            assert.truthy(err:find("invalid type"))
        end)

        it("rejects non-string default", function()
            local ok, err = variables.validate_declarations({
                foo = { type = "string", default = 42 },
            })
            assert.is_false(ok)
            assert.truthy(err:find("default must be a string"))
        end)

        it("accepts valid overrides", function()
            local decl = { output_dir = { type = "path", default = "/dist" } }
            local ok = variables.validate_overrides({ output_dir = "/dist/debug" }, decl)
            assert.is_true(ok)
        end)

        it("rejects override for undeclared variable", function()
            local decl = { output_dir = { type = "path", default = "/dist" } }
            local ok, err = variables.validate_overrides({ unknown = "val" }, decl)
            assert.is_false(ok)
            assert.truthy(err:find("not declared"))
        end)

        it("rejects non-string override value", function()
            local decl = { output_dir = { type = "path", default = "/dist" } }
            local ok, err = variables.validate_overrides({ output_dir = 42 }, decl)
            assert.is_false(ok)
            assert.truthy(err:find("must be a string"))
        end)
    end)

    describe("resolution", function()
        it("resolves to project default when no configuration", function()
            local mock_project = {
                variables = {
                    output_dir = { type = "path", default = "/dist" },
                },
            }
            local resolved = variables.resolve(mock_project, nil)
            assert.equals("/dist", resolved.output_dir.value)
            assert.is_nil(resolved.output_dir.source_config)
            assert.equals("path", resolved.output_dir.type)
        end)

        it("resolves to project default when config has no override", function()
            local mock_project = {
                variables = {
                    output_dir = { type = "path", default = "/dist" },
                },
            }
            local mock_config = { variables = nil, _inherits = {} }
            local resolved = variables.resolve(mock_project, mock_config)
            assert.equals("/dist", resolved.output_dir.value)
            assert.is_nil(resolved.output_dir.source_config)
        end)

        it("resolves to config override", function()
            local mock_project = {
                variables = {
                    output_dir = { type = "path", default = "/dist" },
                },
            }
            local mock_config = {
                name = "Debug",
                variables = { output_dir = "/dist/debug" },
                _inherits = {},
            }
            local resolved = variables.resolve(mock_project, mock_config)
            assert.equals("/dist/debug", resolved.output_dir.value)
            assert.equals(mock_config, resolved.output_dir.source_config)
        end)

        it("resolves through inheritance chain", function()
            local mock_project = {
                variables = {
                    output_dir = { type = "path", default = "/dist" },
                },
            }
            local parent_config = {
                name = "Base",
                variables = { output_dir = "/dist/base" },
                _inherits = {},
            }
            local child_config = {
                name = "Debug",
                variables = nil,  -- no override
                _inherits = { parent_config },
            }
            local resolved = variables.resolve(mock_project, child_config)
            assert.equals("/dist/base", resolved.output_dir.value)
            assert.equals(parent_config, resolved.output_dir.source_config)
        end)

        it("child override wins over parent", function()
            local mock_project = {
                variables = {
                    output_dir = { type = "path", default = "/dist" },
                },
            }
            local parent_config = {
                name = "Base",
                variables = { output_dir = "/dist/base" },
                _inherits = {},
            }
            local child_config = {
                name = "Debug",
                variables = { output_dir = "/dist/debug" },
                _inherits = { parent_config },
            }
            local resolved = variables.resolve(mock_project, child_config)
            assert.equals("/dist/debug", resolved.output_dir.value)
            assert.equals(child_config, resolved.output_dir.source_config)
        end)

        it("provenance tracks specific config in multi-level chain", function()
            local mock_project = {
                variables = {
                    output_dir = { type = "path", default = "/dist" },
                    debug_port = { type = "string", default = "9229" },
                },
            }
            local grandparent = {
                name = "Root",
                variables = { output_dir = "/dist/root", debug_port = "8080" },
                _inherits = {},
            }
            local parent = {
                name = "Mid",
                variables = { output_dir = "/dist/mid" },  -- overrides output_dir only
                _inherits = { grandparent },
            }
            local child = {
                name = "Leaf",
                variables = nil,
                _inherits = { parent },
            }
            local resolved = variables.resolve(mock_project, child)
            -- output_dir from Mid (nearest override)
            assert.equals("/dist/mid", resolved.output_dir.value)
            assert.equals(parent, resolved.output_dir.source_config)
            -- debug_port from Root (grandparent)
            assert.equals("8080", resolved.debug_port.value)
            assert.equals(grandparent, resolved.debug_port.source_config)
        end)

        it("returns empty table when project has no variables", function()
            local resolved = variables.resolve({ variables = nil }, nil)
            assert.same({}, resolved)
        end)
    end)

    describe("config validation", function()
        it("rejects loomworks.json with reserved variable name", function()
            local config_mod = require("loomworks.config")
            local raw = {
                projects = {
                    App = {
                        cmake = {},
                        variables = {
                            build_dir = { type = "string", default = "bad" },
                        },
                    },
                },
            }
            local config, err = config_mod.validate(raw, "/root")
            assert.is_nil(config)
            assert.truthy(err:find("reserved"))
        end)

        it("rejects config override for undeclared variable", function()
            local config_mod = require("loomworks.config")
            local raw = {
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = { variables = { unknown = "val" } },
                            },
                        },
                        variables = {
                            output_dir = { type = "path", default = "/dist" },
                        },
                    },
                },
            }
            local config, err = config_mod.validate(raw, "/root")
            assert.is_nil(config)
            assert.truthy(err:find("not declared"))
        end)

        it("accepts valid variables with config overrides", function()
            local config_mod = require("loomworks.config")
            local raw = {
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = { variables = { output_dir = "/dist/debug" } },
                            },
                        },
                        variables = {
                            output_dir = { type = "path", default = "/dist" },
                        },
                    },
                },
            }
            local config, err = config_mod.validate(raw, "/root")
            assert.is_not_nil(config, err)
        end)
    end)

    describe("full stack", function()
        it("variables stored on project and configuration after remerge", function()
            local ws = make_ws({
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = {
                                    variables = { output_dir = "${project_path}/dist/debug" },
                                },
                            },
                        },
                        variables = {
                            output_dir = { type = "path", default = "${project_path}/dist" },
                        },
                    },
                },
                configuration_sets = { Debug = { App = "Debug" } },
            }, {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            })

            local app = h.find_project_in(ws:get_projects(), "App")
            assert.is_not_nil(app.variables)
            assert.is_not_nil(app.variables.output_dir)
            assert.equals("path", app.variables.output_dir.type)

            -- Find the Debug configuration
            local debug_cfg
            for _, cfg in ipairs(app._configurations) do
                if cfg.name == "Debug" then debug_cfg = cfg; break end
            end
            assert.is_not_nil(debug_cfg)
            assert.is_not_nil(debug_cfg.variables)
            assert.equals("${project_path}/dist/debug", debug_cfg.variables.output_dir)
        end)

        it("variable expansion in launch context", function()
            local ws = make_ws({
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = {
                                    variables = { output_dir = "${project_path}/dist/debug" },
                                },
                            },
                        },
                        variables = {
                            output_dir = { type = "path", default = "${project_path}/dist" },
                            port = { type = "string", default = "9229" },
                        },
                    },
                },
                configuration_sets = {
                    Debug = { App = "Debug" },
                },
            }, {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            })

            local expand_mod = require("loomworks.expand")
            local app = h.find_project_in(ws:get_projects(), "App")
            local profile = ws._active_profile
            assert.is_not_nil(profile, "active profile must exist")

            local ctx = expand_mod.launch_context(ws, profile, app)
            -- output_dir should be expanded with Debug override + built-in project_path
            assert.equals("App/dist/debug", ctx.output_dir)
            -- port uses project default (no Debug override)
            assert.equals("9229", ctx.port)
        end)
    end)

    describe("editor persistence", function()
        it("save_variable creates declaration on project", function()
            local ws = make_ws({ projects = { App = { cmake = {} } } })
            local app = h.find_project_in(ws:get_projects(), "App")

            local ok, err = app:save_variable("output_dir", {
                type = "path", default = "${project_path}/dist",
            })
            assert.is_true(ok, err)
            assert.is_not_nil(app.variables)
            assert.is_not_nil(app.variables.output_dir)
            assert.equals("path", app.variables.output_dir.type)
            assert.equals("${project_path}/dist", app.variables.output_dir.default)
        end)

        it("save_variable rejects reserved name", function()
            local ws = make_ws({ projects = { App = { cmake = {} } } })
            local app = h.find_project_in(ws:get_projects(), "App")

            local ok, err = app:save_variable("build_dir", {
                type = "string", default = "bad",
            })
            assert.is_false(ok)
            assert.truthy(err:find("reserved"))
        end)

        it("delete_variable removes declaration and config overrides", function()
            local ws = make_ws({
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = {
                                    variables = { output_dir = "/debug" },
                                },
                            },
                        },
                        variables = {
                            output_dir = { type = "path", default = "/dist" },
                        },
                    },
                },
                configuration_sets = { Debug = { App = "Debug" } },
            }, {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            })

            local app = h.find_project_in(ws:get_projects(), "App")
            assert.is_not_nil(app.variables.output_dir)

            local debug_cfg
            for _, cfg in ipairs(app._configurations) do
                if cfg.name == "Debug" then debug_cfg = cfg; break end
            end
            assert.is_not_nil(debug_cfg.variables)

            local ok, err = app:delete_variable("output_dir")
            assert.is_true(ok, err)
            assert.is_nil(app.variables)
            assert.is_nil(debug_cfg.variables)
        end)

        it("workspace_view save/get round-trip", function()
            local ws = make_ws({ projects = { App = { cmake = {} } } })
            local app = h.find_project_in(ws:get_projects(), "App")

            -- Save via workspace_view
            local ok = wv.execute_save_variable(app, nil, "port", {
                type = "string", default = "9229",
            })
            assert.is_true(ok)

            local vars = wv.get_variables(app)
            assert.equals(1, #vars)
            assert.equals("port", vars[1].name)
            assert.equals("string", vars[1].type)
            assert.equals("9229", vars[1].default)
        end)

        it("workspace_view rename variable", function()
            local ws = make_ws({
                projects = {
                    App = {
                        cmake = {},
                        variables = {
                            old_name = { type = "string", default = "val" },
                        },
                    },
                },
            })
            local app = h.find_project_in(ws:get_projects(), "App")

            local ok = wv.execute_save_variable(app, "old_name", "new_name", {
                type = "string", default = "val",
            })
            assert.is_true(ok)
            assert.is_nil(app.variables.old_name)
            assert.is_not_nil(app.variables.new_name)
        end)

        it("the declaration resolves the variables for the configuration editor", function()
            local ws = make_ws({
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                Debug = {
                                    variables = { output_dir = "/debug" },
                                },
                            },
                        },
                        variables = {
                            output_dir = { type = "path", default = "/dist" },
                            port = { type = "string", default = "9229" },
                        },
                    },
                },
                configuration_sets = { Debug = { App = "Debug" } },
            }, {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            })

            local app = h.find_project_in(ws:get_projects(), "App")
            local decl = wv.project_declaration(app)
            local debug
            for _, c in ipairs(decl.configurations) do if c.key == "Debug" then debug = c end end

            -- variables has the declarations
            assert.equals("path", decl.variables.output_dir.type)

            -- the configuration's fields have its own overrides
            assert.equals("/debug", debug.fields.variables.output_dir)
            assert.is_nil(debug.fields.variables.port)  -- not overridden

            -- resolved_variables has full resolution with provenance
            assert.same({
                { name = "output_dir", value = "/debug", from = "configuration", configuration = { key = "Debug" } },
                -- port resolves to project default
                { name = "port", value = "9229", from = "project" },
            }, debug.resolved_variables)
        end)
    end)
end)

-- =========================================================================
-- Operation completion on failure
-- =========================================================================

describe("operation completion on failure", function()
    local Operation = require("loomworks.operation")

    it("operation completes when one unit fails configure", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Lib = { cmake = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug", Lib = "Debug" },
            },
        }, {
            active_profile = "Debug",
            profiles = { Debug = { configuration_set = "Debug" } },
        })

        local profile = ws._active_profile
        assert.is_not_nil(profile)

        -- Find both config units
        local app_unit = h.find_config_unit(ws._config_units, "App", "Debug")
        local lib_unit = h.find_config_unit(ws._config_units, "Lib", "Debug")
        assert.is_not_nil(app_unit, "App/Debug config unit")
        assert.is_not_nil(lib_unit, "Lib/Debug config unit")

        -- Create operation tracking both units
        local completed_op = nil
        local units = { app_unit, lib_unit }
        local target_states = {}
        target_states[app_unit] = "configured"
        target_states[lib_unit] = "configured"

        local op = Operation.new(ws, profile, "configure", units, target_states,
            function(o) completed_op = o end)
        profile:add_operation(op)

        assert.is_false(op.completed)
        assert.is_true(profile:has_active_operation())

        -- Simulate: App configure starts
        app_unit:register_task(100, "configure")
        -- Simulate: Lib configure starts
        lib_unit:register_task(101, "configure")

        assert.is_false(op.completed)  -- still running

        -- Simulate: App configure succeeds
        app_unit.state_value = "configured"
        app_unit:unregister_task(100)

        assert.is_false(op.completed)  -- Lib still running

        -- Simulate: Lib configure fails
        lib_unit.state_value = "failed_configure"
        lib_unit:unregister_task(101)

        -- Operation should be completed now (both units done)
        assert.is_true(op.completed, "operation should be completed after both units finish")
        assert.is_false(op.success, "operation should report failure")
        assert.is_not_nil(completed_op, "completion callback should have fired")

        -- Profile should have no active operations
        profile:complete_operation(op)
        assert.is_false(profile:has_active_operation())
    end)

    it("operation stuck when task completes without on_start (no register_task)", function()
        -- Reproduces: if overseer's on_complete fires without on_start
        -- (e.g., subprocess fails to spawn), unregister_task is a no-op
        -- because _task_id was never set, so listeners never fire.
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        }, {
            active_profile = "Debug",
            profiles = { Debug = { configuration_set = "Debug" } },
        })

        local app_unit = h.find_config_unit(ws._config_units, "App", "Debug")
        assert.is_not_nil(app_unit)

        local completed = false
        local units = { app_unit }
        local target_states = {}
        target_states[app_unit] = "configured"

        local op = Operation.new(ws, ws._active_profile, "configure", units, target_states,
            function() completed = true end)

        -- Simulate: task completes WITHOUT on_start (register_task never called)
        -- record_task_result updates state, but unregister_task is no-op
        app_unit.state_value = "failed_configure"
        app_unit:unregister_task(999)  -- task_id doesn't match (nil ~= 999)

        -- Operation should still complete, but currently it doesn't
        -- because _notify() never fires
        assert.is_true(op.completed,
            "BUG: operation stuck because unregister_task was no-op (task never started)")
    end)

    it("operation completes when single unit fails configure", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug" },
            },
        }, {
            active_profile = "Debug",
            profiles = { Debug = { configuration_set = "Debug" } },
        })

        local app_unit = h.find_config_unit(ws._config_units, "App", "Debug")
        assert.is_not_nil(app_unit)

        local completed = false
        local units = { app_unit }
        local target_states = {}
        target_states[app_unit] = "configured"

        local op = Operation.new(ws, ws._active_profile, "configure", units, target_states,
            function() completed = true end)

        -- Simulate: task starts
        app_unit:register_task(100, "configure")
        assert.is_false(op.completed)

        -- Simulate: task fails
        app_unit.state_value = "failed_configure"
        app_unit:unregister_task(100)

        assert.is_true(op.completed, "operation should complete on failure")
        assert.is_false(op.success)
        assert.is_true(completed, "callback should fire")
    end)

    it("operation completes when task is canceled (state reverts to unconfigured)", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        }, {
            active_profile = "Debug",
            profiles = { Debug = { configuration_set = "Debug" } },
        })

        local app_unit = h.find_config_unit(ws._config_units, "App", "Debug")
        assert.is_not_nil(app_unit)

        local completed = false
        local units = { app_unit }
        local target_states = {}
        target_states[app_unit] = "configured"

        local op = Operation.new(ws, ws._active_profile, "configure", units, target_states,
            function() completed = true end)

        -- Simulate: task starts
        app_unit:register_task(100, "configure")

        -- Simulate: task canceled (record_task_result NOT called)
        -- state_value stays nil (unconfigured)
        app_unit:unregister_task(100)

        -- State is now "unconfigured" — Operation should treat this as failure
        assert.equals("unconfigured", app_unit:state())
        assert.is_true(op.completed,
            "operation should complete when unit reverts to unconfigured (canceled task)")
        assert.is_false(op.success)
        assert.is_true(completed)
    end)

    it("operation completes when record_task_result is skipped (unknown state path)", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        }, {
            active_profile = "Debug",
            profiles = { Debug = { configuration_set = "Debug" } },
        })

        local app_unit = h.find_config_unit(ws._config_units, "App", "Debug")
        assert.is_not_nil(app_unit)

        local completed = false
        local units = { app_unit }
        local target_states = {}
        target_states[app_unit] = "configured"

        local op = Operation.new(ws, ws._active_profile, "configure", units, target_states,
            function() completed = true end)

        -- Simulate: task starts
        app_unit:register_task(100, "configure")

        -- Simulate: something sets state to unknown (crash recovery, etc.)
        app_unit.state_value = "unknown"
        app_unit:unregister_task(100)

        assert.equals("unknown", app_unit:state())
        assert.is_true(op.completed, "operation should complete on unknown state")
        assert.is_false(op.success)
    end)
end)

-- =========================================================================
-- Inherited options through abstract mixins
-- =========================================================================


-- Profile persistence
-- =========================================================================

describe("profile persistence", function()
    it("created profile has local intent and is serialized in user data", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug" },
            },
        })

        -- No profiles initially
        assert.equals(0, #ws._profiles)

        -- Create a profile via workspace_view
        local cs
        for _, c in pairs(ws._config_sets) do
            if c.name == "Debug" then cs = c; break end
        end
        assert.is_not_nil(cs, "Debug config set should exist")

        local profile = wv.execute_create_profile(cs, nil, false)
        assert.is_not_nil(profile, "profile should be created")
        assert.is_true(profile._intent ~= "shared", "profile should be in user json")

        -- Serialize user data and check profiles
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.profiles, "user data should have profiles")
        assert.is_not_nil(user_data.profiles[profile.key],
            "profile key should be in profiles")
        assert.equals("Debug",
            user_data.profiles[profile.key].configuration_set,
            "profile should reference config set")
    end)

    it("created profile survives remerge", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug" },
            },
        })

        local cs
        for _, c in pairs(ws._config_sets) do
            if c.name == "Debug" then cs = c; break end
        end

        local profile = wv.execute_create_profile(cs, nil, true)
        assert.is_not_nil(profile)
        local profile_key = profile.key

        -- Remerge (simulates what happens on file change or mutation)
        ws:remerge()

        -- Profile should still exist
        local found = false
        for _, p in pairs(ws._profiles) do
            if p.key == profile_key then
                found = true
                assert.is_true(p._intent ~= "shared", "profile should still be in user json after remerge")
                break
            end
        end
        assert.is_true(found, "profile should survive remerge")
    end)

    it("activated profile persists active_profile in user data", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug" },
            },
        })

        local cs
        for _, c in pairs(ws._config_sets) do
            if c.name == "Debug" then cs = c; break end
        end

        local profile = wv.execute_create_profile(cs, nil, true)
        assert.is_not_nil(profile)

        local user_data = ws:_serialize_user()
        assert.equals(profile.key, user_data.active_profile,
            "active_profile should be set in user data")
    end)
end)
