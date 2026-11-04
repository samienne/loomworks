--- Clean of a profile with an invalid ProfileProject (core state-lifecycle
--- §5.4 "Invalid ProfileProjects", §8 `info`): the valid ProfileProjects are
--- cleaned; an invalid one (a tool compat error, or a configuration the
--- module reported an error for) is not, and the clean fails naming it. A
--- core-performed wipe never removes a build directory a refused project
--- shares. Ported from loomworks.nvim's profile_invalid_pp_spec.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local task_plan = require("loomworks.task_plan")
local build_run = require("loomworks.build_run")
local cli = require("loomworks.cli")
local real_modules = require("loomworks.modules")

local REASON = "targets OpenHarmony but profile tool is HarmonyOS"


--- Shell projects `app` and `lib`, set + profile `dev` (app=Debug, lib=Debug).
--- `opts.collide`: lib's build directory is app's (`out/app/Debug`), so
--- lib/Debug is refused (core §1.7 "One build directory per configuration").
--- `opts.clean`: each project has a `cln-<name>` clean command and its build
--- directory exists (so a clean plans a step for it). `opts.invalid`: the
--- named projects' build_dir template names a variable a shell template may
--- not use, so the module reports an `error` for their Debug (§8 `info`): the
--- configuration is invalid. `opts.exe`: each command
--- runs this nvim with the name as its argument (resolvable on PATH, for the
--- editor's task hardening).
local function make_ws(opts)
    opts = opts or {}
    local function cmd(word)
        if opts.exe then return { (vim.v.progpath:gsub("\\", "/")), word } end
        return { word }
    end
    local root = (vim.fn.tempname():gsub("\\", "/"))
    for _, d in ipairs({ "app", "lib" }) do
        vim.fn.mkdir(root .. "/" .. d, "p")
        if opts.clean then vim.fn.mkdir(root .. "/out/" .. d .. "/Debug", "p") end
    end
    local function proj(name)
        return { path = name, shell = {
            build_dir = (opts.invalid and opts.invalid[name])
                and "${workspace_root}/out/${LW_PIPP_UNDECLARED}/${variant}"
                or (opts.collide and name == "lib" and "${workspace_root}/out/app/${variant}")
                or ("${workspace_root}/out/" .. name .. "/${variant}"),
            configure_cmd = cmd("cfg-" .. name), build_cmd = cmd("bld-" .. name),
            clean_cmd = opts.clean and cmd("cln-" .. name) or nil,
            configurations = { Debug = vim.empty_dict() },
        } }
    end
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { app = proj("app"), lib = proj("lib") },
            configuration_sets = { dev = { app = "Debug", lib = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({
            profiles = { dev = { configuration_set = "dev" } },
            active_profile = "dev",
        }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    return ws, profile, root
end

--- Give the named projects' ProfileProjects a tool compat error.
local function mark_incompatible(profile, names)
    for _, pp in ipairs(profile:projects()) do
        if names[pp._project.key] then pp._tool_compat_error = REASON end
    end
end


local function step_projects(steps)
    local out = {}
    for _, s in ipairs(steps or {}) do
        local u = s.unit
        out[#out + 1] = (u and u._project and u._project.key or "?") .. ":" .. s.kind
    end
    return out
end

--- Run headless `lw clean dev` against `ws`; returns the spawned commands'
--- first words, the exit code and stderr.
local function run_clean(ws)
    local orig_spawn, orig_stderr, orig_exit, orig_write = cli._run_spec, io.stderr, os.exit, io.write
    local spawned, err = {}, {}
    cli._run_spec = function(s) spawned[#spawned + 1] = s.cmd[1]; return 0 end
    io.write = function() end
    io.stderr = { write = function(_, s) err[#err + 1] = s end }
    local code
    os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
    local ok, e = pcall(cli.cmd_clean, ws, { "clean", "dev" })
    cli._run_spec, io.stderr, os.exit, io.write = orig_spawn, orig_stderr, orig_exit, orig_write
    if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
    if ok then code = e end
    return spawned, code, table.concat(err)
end

describe("profile clean with an invalid ProfileProject (§5.4)", function()
    local root
    local io_mod = require("loomworks.io")
    local real_rm, real_rm_sync
    before_each(function() real_rm, real_rm_sync = io_mod.rm_rf_async, io_mod.rm_rf end)
    after_each(function()
        io_mod.rm_rf_async, io_mod.rm_rf = real_rm, real_rm_sync
        require("loomworks.op_lock").release_all()
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    --- Record every tree removal (synchronous, no subprocess), through the
    --- workspace's io dependency and the io module alike.
    local function record_removals(ws)
        local removed = {}
        local function async(path, cb)
            removed[#removed + 1] = path
            vim.fn.delete(path, "rf")
            if cb then vim.schedule(function() cb(true, nil) end) end
            return require("loomworks.future").resolved(true)
        end
        local function sync(path) removed[#removed + 1] = path; vim.fn.delete(path, "rf"); return true end
        local io_dep = ws._core._deps.io
        if io_dep then io_dep.rm_rf_async, io_dep.rm_rf = async, sync end
        io_mod.rm_rf_async, io_mod.rm_rf = async, sync
        return removed
    end

    it("shell's default wipe clean keeps a build directory a refused project shares", function()
        local function run(refuse)
            local ws, profile, r = make_ws()
            root = r
            -- `lw clean` takes the real operation and build-directory locks
            -- (the root exists on disk), not the test deps' in-memory ones.
            ws._core._deps.locks = nil
            if refuse then mark_incompatible(profile, { lib = true }) end
            -- Both configured into one directory, as a module's shared
            -- tree would be (two shell templates resolving to one
            -- directory are a collision, core §1.7, so it is set here).
            vim.fn.mkdir(r .. "/out/shared", "p")
            for _, pp in ipairs(profile:projects()) do
                pp._config_unit.build_dir_value = r .. "/out/shared"
                pp._config_unit.state_value = "configured"
            end
            ws:_sync_build_dir_refs()
            local removed = record_removals(ws)
            local steps = build_run.plan_clean(profile)
            local planned = {}
            for _, st in ipairs(steps or {}) do
                if st.wipe_build_dir then planned[#planned + 1] = st.build_dir end
            end
            local _, code, err = run_clean(ws)
            io_mod.rm_rf_async, io_mod.rm_rf = real_rm, real_rm_sync
            require("loomworks.op_lock").release_all()
            vim.fn.delete(r, "rf"); root = nil
            return removed, code, err, planned
        end
        -- Control: nothing refused, the shared directory is wiped.
        local removed, code, err, planned = run(false)
        assert.equals(0, code, err)
        assert.truthy(#planned >= 1, "the plan wipes it")
        assert.truthy(#removed >= 1, "the wipe ran")
        -- lib refused: the valid project's wipe keeps the directory lib uses.
        removed, code, err, planned = run(true)
        assert.equals(1, code, err)
        assert.truthy(err:find("lib/Debug not run", 1, true), err)
        assert.same({}, planned)
        for _, p in ipairs(removed) do
            assert.is_nil(p:find("out/shared", 1, true), "removed " .. p)
        end
    end)
end)

describe("clean of a configuration the module reported an error for (§8 info, §5.4)", function()
    local root
    after_each(function()
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    it("plan_profile_clean cleans the valid project and names the invalid one with its error", function()
        local ws, profile, r = make_ws({ clean = true, invalid = { lib = true } })
        root = r
        local steps, refused = task_plan.plan_profile_clean(profile)
        assert.same({ "app:clean" }, step_projects(steps))
        assert.equals(1, #(refused or {}), vim.inspect(refused))
        assert.truthy(refused[1]:find("lib/Debug not run", 1, true), refused[1])
        assert.truthy(refused[1]:find("LW_PIPP_UNDECLARED", 1, true), refused[1])
        assert.is_not_nil(ws)
    end)

    it("is an invalid ProfileProject with the module's error and its remedy, marking the profile", function()
        local ws, profile, r = make_ws({ invalid = { lib = true } })
        root = r
        local reason, remedy = profile:project("lib"):invalid_reason()
        assert.truthy(reason and reason:find("LW_PIPP_UNDECLARED", 1, true), tostring(reason))
        assert.equals("fix the configuration in loomworks.json or user.json", remedy)
        local view = require("loomworks.view_state").workspace(ws, {})
        local row
        for _, p in ipairs(view.profiles) do if p.key == profile.key then row = p end end
        assert.equals(reason, row.compat_error)
    end)

    it("headless lw clean cleans the valid project, then exits non-zero naming the invalid one", function()
        local ws, _, r = make_ws({ clean = true, invalid = { lib = true } })
        root = r
        local spawned, code, text = run_clean(ws)
        assert.same({ "cln-app" }, spawned)
        assert.equals(1, code)
        assert.truthy(text:find("lib/Debug not run", 1, true), text)
        assert.truthy(text:find("LW_PIPP_UNDECLARED", 1, true), text)
    end)
end)
