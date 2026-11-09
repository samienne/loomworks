--- The cmake module's qmlls lsp_configs entry: the
--- active profile's build_dir and the `project.cached.build_dir` fallback,
--- the `compile_commands_from` redirect, and `type_config.qmlls`,
--- `qmlls_required` and `qml_import_paths` reaching the entry. Exercised with
--- a fake project/workspace fixture, so no qmlls process is ever spawned.

package.loaded["loomworks.modules.cmake"] = nil
local cmake = require("loomworks.modules.cmake")

describe("cmake lsp_configs qmlls entry", function()
    --- Build a minimal fake Project + Workspace for cmake.lsp_configs.
    --- Mirrors shell_spec.lua's fake_project. The active profile carries a
    --- ProfileProject whose build_dir feeds both the clangd and qmlls entries.
    local function fake_project(opts)
        opts = opts or {}
        local build_dir = opts.build_dir
        local ws = {
            root = opts.ws_root or "/work",
            get_active_profile = function()
                if not build_dir then return nil end
                return {
                    project = function(_, _key)
                        return {
                            build_dir = function() return build_dir end,
                            -- Configured on this machine (spec §9.1) unless asked.
                            configured_here = function() return opts.unconfigured ~= true end,
                        }
                    end,
                    tool_for = function() return nil end,
                }
            end,
        }
        return {
            key = opts.key or "myapp",
            path = opts.path or "myapp",
            type = "cmake",
            type_config = opts.type_config or {},
            tool_data = opts.tool_data,
            cached = opts.cached,
            _workspace = ws,
        }
    end

    it("emits a qmlls entry as the second config", function()
        local cfgs = cmake.lsp_configs(fake_project({
            build_dir = "/work/.lw/build/myapp/Debug",
        }))
        assert.equals(2, #cfgs)
        assert.equals("clangd", cfgs[1].server)
        assert.equals("qmlls", cfgs[2].server)
    end)

    it("carries the active profile build_dir and project root_dir", function()
        local cfgs = cmake.lsp_configs(fake_project({
            build_dir = "/work/.lw/build/myapp/Debug",
        }))
        local q = cfgs[2]
        assert.equals("/work/.lw/build/myapp/Debug", q.build_dir)
        assert.equals("/work/myapp", q.root_dir)
        -- clangd now routes through the loomworks-owned generated DB dir for
        -- every cmake generator (cmake.md §12), so it no longer equals the
        -- qmlls build dir; qmlls still resolves against the real build dir.
        assert.are_not.equal(q.build_dir, cfgs[1].compile_commands_dir)
        assert.is_truthy(cfgs[1].compile_commands_dir:find("/.lw/cache/cc/", 1, true))
    end)

    it("qmlls keeps the project.cached.build_dir fallback without an active profile", function()
        local cfgs = cmake.lsp_configs(fake_project({
            cached = { build_dir = "/work/.lw/build/myapp/Cached" },
        }))
        assert.equals("/work/.lw/build/myapp/Cached", cfgs[2].build_dir)
        -- clangd never gets a database without a unit configured here (§9.1).
        assert.is_nil(cfgs[1].compile_commands_dir)
        assert.equals("unconfigured", cfgs[1].db_state)
    end)

    it("qmlls follows a compile_commands_from redirect's first unit, as before", function()
        local function unit(bd, here)
            return { build_dir = function() return bd end, configured_here = function() return here end }
        end
        local p = fake_project({ type_config = { compile_commands_from = "Release" } })
        p.get_configuration = function() return {} end
        p.config_units_for_configuration = function()
            return { unit("/work/out/A", false), unit("/work/out/B", true) }
        end
        local cfgs = cmake.lsp_configs(p)
        assert.equals("/work/out/A", cfgs[2].build_dir)
        assert.equals("/work/out/B", cfgs[1].compile_commands_dir)
        -- clangd reads the redirect target's database: that is its db_dir
        -- (core §8.4). qmlls sets none (core fills in the active dir).
        assert.equals("/work/out/B", cfgs[1].db_dir)
        assert.is_nil(cfgs[2].db_dir)
    end)

    it("clangd's db_dir is the active build dir without a redirect", function()
        local cfgs = cmake.lsp_configs(fake_project({ build_dir = "/work/.lw/build/myapp/Debug" }))
        assert.equals("/work/.lw/build/myapp/Debug", cfgs[1].db_dir)
    end)

    it("core's state keeps qmlls's own build_dir (its -b) under a redirect", function()
        local lsp_config = require("loomworks.lsp_config")
        lsp_config.clear_memo()
        local function unit(bd, here)
            return { build_dir = function() return bd end, configured_here = function() return here end }
        end
        local p = fake_project({
            build_dir = "/work/active",
            type_config = { compile_commands_from = "Release" },
        })
        p.get_configuration = function() return {} end
        p.config_units_for_configuration = function()
            return { unit("/work/out/A", false), unit("/work/out/B", true) }
        end
        p._module = { impl = cmake }
        local ws = p._workspace
        -- The memo key also reads the unit's config key and status.
        local active = ws.get_active_profile
        ws.get_active_profile = function()
            local prof = active()
            local project = prof.project
            prof.project = function(self, key)
                local pp = project(self, key)
                pp.config_key = function() return "Debug" end
                pp.status = function() return "configured" end
                return pp
            end
            return prof
        end
        local entries = lsp_config.entries(ws, p)
        assert.equals("/work/out/B", entries[1].db_dir)
        assert.equals("/work/out/A", entries[2].build_dir, "the module's field passes through")
        assert.equals("/work/active", entries[2].db_dir)
        -- db_rev of the clangd entry follows the redirect target.
        lsp_config.bump_db_rev(ws, "/work/active")
        assert.equals(0, lsp_config.entries(ws, p)[1].db_rev)
        lsp_config.bump_db_rev(ws, "/work/out/B")
        assert.equals(1, lsp_config.entries(ws, p)[1].db_rev)
        lsp_config.clear_memo()
    end)

    it("type_config.qmlls flows into entry.binary; absent ⇒ nil", function()
        local with = cmake.lsp_configs(fake_project({
            build_dir = "/work/out",
            type_config = { qmlls = "/opt/qt/bin/qmlls" },
        }))
        assert.equals("/opt/qt/bin/qmlls", with[2].binary)

        local without = cmake.lsp_configs(fake_project({ build_dir = "/work/out" }))
        assert.is_nil(without[2].binary)
    end)

    it("type_config.qmlls_required flows into entry.binary_required", function()
        local cfgs = cmake.lsp_configs(fake_project({
            build_dir = "/work/out",
            type_config = { qmlls = "/opt/qt/bin/qmlls", qmlls_required = true },
        }))
        assert.is_true(cfgs[2].binary_required)

        local dflt = cmake.lsp_configs(fake_project({ build_dir = "/work/out" }))
        assert.is_false(dflt[2].binary_required)
    end)

    it("type_config.qml_import_paths flows into entry.import_paths", function()
        local cfgs = cmake.lsp_configs(fake_project({
            build_dir = "/work/out",
            type_config = { qml_import_paths = { "/a/qml", "/b/qml" } },
        }))
        assert.same({ "/a/qml", "/b/qml" }, cfgs[2].import_paths)

        local none = cmake.lsp_configs(fake_project({ build_dir = "/work/out" }))
        assert.is_nil(none[2].import_paths)
    end)
end)
