--- Unit tests of the daemon's `lw run` handling (spec §19.15 "Run"): the
--- cross-kit decline in Service:_accept, and the `--prefix` refusal of a
--- device target in the runner's preparation (before any deploy, as the
--- in-process `_run_launch_target_impl`); and of `Launch/1.prepare_debug`
--- (§19.15 "Debug") and the target build scope of both preparations
--- (§19.15 "Build scope of a launch").

local service = require("loomworks.daemon.service")
local runner = require("loomworks.daemon.runner")
local build_run = require("loomworks.build_run")
local run_prep = require("loomworks.run_prep")

local function stub(tbl, key, fn)
    local orig = tbl[key]
    tbl[key] = fn
    return function() tbl[key] = orig end
end

describe("daemon run preparation (§19.15 Run)", function()
    local restores
    before_each(function() restores = {} end)
    after_each(function()
        for i = #restores, 1, -1 do restores[i]() end
    end)
    local function with(tbl, key, fn) restores[#restores + 1] = stub(tbl, key, fn) end

    it("declines a run of a profile whose kit builds for another platform, before any task", function()
        local profile = { key = "ohos-debug" }
        with(build_run, "resolve_target", function() return profile end)
        with(run_prep, "kit_platform", function(p) return p == profile and "ohos-arm64" or nil end)
        local created = false
        local svc = setmetatable({
            live = function() return { root = "/ws" } end,
            tasks = { create = function() created = true end },
        }, service.Service)
        local reply
        svc:_accept({ op = "run", conn = { closed = false }, args = {}, interactive = false,
            reply = function(f) reply = f end })
        assert.is_false(created)
        assert.are.same({ outcome = "declined", reason = "profile 'ohos-debug' builds for ohos-arm64; "
            .. "device runs stay in this process" }, reply)
    end)

    it("does not decline a build of that profile (only a run is a device run)", function()
        local profile = { key = "ohos-debug" }
        with(build_run, "resolve_target", function() return profile end)
        local asked = false
        with(run_prep, "kit_platform", function() asked = true; return "ohos-arm64" end)
        local svc = setmetatable({
            live = function() return { root = "/ws" } end,
            tasks = { create = function() error("stop here") end },
        }, service.Service)
        assert.has_error(function()
            svc:_accept({ op = "build", conn = { closed = false }, args = {}, reply = function() end })
        end)
        assert.is_false(asked)
    end)

    --- Run the runner's preparation (`--no-build`: no lock, straight to it)
    --- for a launch target `lt`; returns the task's `done` record.
    local function prepare(lt, args)
        with(run_prep, "select", function() return lt end)
        with(run_prep, "validity_error", function() return nil end)
        with(run_prep, "foreign_of", function() return nil end)
        with(run_prep, "resolve_spec", function()
            return { name = "app", config_key = ck, cmd = "/bin/app", args = {}, cwd = "/ws" }
        end)
        with(run_prep, "env_overrides", function() return {} end)
        local ws = { root = "/ws" }
        local done
        local task = {
            start = function() end, line = function() end,
            done = function(_, code, err, fields) done = { code = code, err = err, fields = fields } end,
        }
        local profile = { key = "dbg", projects = function() return {} end }
        local svc = { ws = ws, ids = require("loomworks.daemon.snapshot").registry(1) }
        runner.run(svc, { op = "run", task = task, ws = ws, profile = profile, env = {},
            args = vim.tbl_extend("force", { no_build = true }, args) })
        return done
    end

    it("--prefix refuses a device target with the in-process message, before deploy", function()
        local deployed = false
        local lt = {
            requires_device = function() return true end,
            display_name = function() return "phone-app" end,
            deploy_sync = function() deployed = true; return true end,
        }
        local done = prepare(lt, { prefix = true })
        assert.are.equal(1, done.code)
        assert.are.equal("--prefix cannot wrap a device target ('phone-app') — a local wrapper does not "
            .. "apply to on-device execution.", done.err)
        assert.is_false(deployed)
    end)

    it("--cwd refuses a device target as a usage error (exit 2), before deploy", function()
        local deployed = false
        local lt = {
            requires_device = function() return true end,
            display_name = function() return "phone-app" end,
            deploy_sync = function() deployed = true; return true end,
        }
        local done = prepare(lt, { cwd = "sub" })
        assert.are.equal(2, done.code)
        assert.are.equal("--cwd does not apply to a device run ('phone-app') — set the project's "
            .. "device.working_dir instead", done.err)
        assert.is_false(deployed)
    end)

    it("--prefix with a local target prepares the launch", function()
        local lt = {
            requires_device = function() return false end,
            display_name = function() return "app" end,
        }
        local done = prepare(lt, { prefix = true })
        assert.are.equal(0, done.code)
        assert.are.equal("/bin/app", done.fields.launch.cmd)
    end)
    -- A run naming no target (the editor's default target, loomworks.nvim spec/plugin.md §19.16) is
    -- resolved by the daemon to the profile's own default target: its
    -- descriptor's `working_dir` override is where the program runs.
    it("a run naming no target runs the profile's default target in its working_dir", function()
        local Target = require("loomworks.target")
        local LaunchTarget = require("loomworks.launch_target")
        local expand = require("loomworks.expand")
        with(expand, "launch_context", function() return {} end)
        with(run_prep, "validity_error", function() return nil end)
        with(run_prep, "foreign_of", function() return nil end)
        with(run_prep, "env_overrides", function() return {} end)
        local unit = {
            build_dir = function() return "/b" end,
            _project = { key = "app", abs_path = function() return "/ws/app" end },
            run_env = require("loomworks.config_unit").run_env,
        }
        local ws = { root = "/ws" }
        local default_lt = setmetatable({ _workspace = ws, _project = unit._project,
            _target = Target.new(unit, "app", { type = "executable", artifact = "app.exe" }),
            _target_id = "app", _working_dir = "/data/run" }, LaunchTarget)
        local profile = { key = "dbg", projects = function() return {} end,
            default_target = function() return default_lt end }
        local done
        local task = {
            start = function() end, line = function() end,
            done = function(_, code, err, fields) done = { code = code, err = err, fields = fields } end,
        }
        local svc = { ws = ws, ids = require("loomworks.daemon.snapshot").registry(1) }
        runner.run(svc, { op = "run", task = task, ws = ws, profile = profile, env = {},
            args = { no_build = true, extra = {} } })
        assert.are.equal(0, done.code, done.err)
        assert.are.equal("/b/app.exe", done.fields.launch.cmd)
        assert.are.equal("/data/run", done.fields.launch.cwd)
    end)

    -- ---- Launch/1.prepare_debug (§19.15 "Debug") ----------------------------

    it("never declines a debug of a profile whose kit builds for another platform", function()
        local profile = { key = "ohos-debug" }
        with(build_run, "resolve_target", function() return profile end)
        local asked = false
        with(run_prep, "kit_platform", function() asked = true; return "ohos-arm64" end)
        local svc = setmetatable({
            live = function() return { root = "/ws" } end,
            tasks = { create = function() error("stop here") end },
        }, service.Service)
        local reply
        assert.has_error(function()
            svc:_accept({ op = "debug", conn = { closed = false }, args = {}, reply = function(f) reply = f end })
        end)
        assert.is_false(asked)
        assert.is_nil(reply)
    end)

    it("refuses a debug request with run-only arguments or an unknown build scope as malformed", function()
        local svc = setmetatable({ server = {} }, service.Service)
        local env = { PATH = "/bin" }
        for _, args in ipairs({ { quiet = true }, { prefix = false }, { build_scope = "everything" } }) do
            local reply
            svc:_on_operation("debug", { closed = false }, { args = args, env = env }, function(f) reply = f end)
            assert.are.same({ outcome = "declined", reason = "malformed request" }, reply)
        end
        local reply
        svc:_on_operation("run", { closed = false }, { args = { build_scope = 7 }, env = env },
            function(f) reply = f end)
        assert.are.same({ outcome = "declined", reason = "malformed request" }, reply)
    end)

    --- A configuration unit stub's key.
    local function ck() return "Debug" end

    --- A launch target stub of project `app` (module language c++).
    local function launch_target(fields)
        local lt = {
            requires_device = function() return false end,
            display_name = function() return "app: hello" end,
            deploy_count = function() return 1 end,
            _project = { key = "app", _module = { primary_language = function() return "c++" end } },
        }
        for k, v in pairs(fields or {}) do lt[k] = v end
        return lt
    end

    --- Run the runner (op `op`) with the resolution stubbed; returns the
    --- task's `done` record and the lines it printed.
    local function run_op(op, lt, args, opts)
        opts = opts or {}
        with(run_prep, "select", opts.select or function() return lt end)
        with(run_prep, "validity_error", function() return nil end)
        with(run_prep, "foreign_of", function(...)
            if type(opts.foreign) == "function" then return opts.foreign(...) end
            return opts.foreign
        end)
        with(run_prep, "resolve_spec", function()
            return { name = "app: hello", cmd = "/bin/app", args = { "--x" }, cwd = "/ws/app" }
        end)
        with(run_prep, "env_overrides", function() return opts.env or { APP_MODE = "dev" } end)
        local ws = { root = "/ws" }
        local done, lines = nil, {}
        local task = {
            start = function(_, meta) if opts.meta then opts.meta.start = meta end end,
            step = function(_, index, state, err)
                if opts.steps then opts.steps[#opts.steps + 1] = { index, state, err } end
            end,
            progress = function(_, f) if opts.progress then opts.progress[#opts.progress + 1] = f end end,
            output = function() end, end_output = function() end, set_flow = function() end,
            line = function(_, _, text) lines[#lines + 1] = text end,
            done = function(_, code, err, fields) done = { code = code, err = err, fields = fields } end,
        }
        local profile = { key = "dbg", projects = function() return {} end }
        local svc = { ws = ws, host = {}, ids = require("loomworks.daemon.snapshot").registry(1),
            with_model = function(_, _, fn) return fn() end }
        runner.run(svc, { op = op, task = task, ws = ws, profile = profile, env = {}, args = args })
        return done, lines, profile
    end

    it("ends a debug preparation with the run's resolved launch and the ordered adapters", function()
        local lt = launch_target({ _launch = { command = "/bin/app", debug = { "typescript", "c++" } } })
        local done = run_op("debug", lt, { no_build = true })
        assert.are.equal(0, done.code)
        assert.is_nil(done.fields.launch)
        assert.are.same({
            name = "app: hello", program = "/bin/app", args = { "--x" }, cwd = "/ws/app", env = { APP_MODE = "dev" },
            language = "typescript",
            adapters = { { language = "typescript", adapter = "pwa-node" }, { language = "c++", adapter = "codelldb" } },
        }, done.fields.result.debug)
    end)

    it("debugs a module target in its primary language with the workspace's adapter", function()
        local done = run_op("debug", launch_target(), { no_build = true })
        assert.are.equal(0, done.code)
        assert.are.equal("c++", done.fields.result.debug.language)
        assert.are.same({ { language = "c++", adapter = "codelldb" } }, done.fields.result.debug.adapters)
    end)

    it("refuses a device target nonzero before any deploy, never as a device run", function()
        local deployed = false
        local lt = launch_target({
            requires_device = function() return true end,
            deploy_sync = function() deployed = true; return true end,
        })
        local done = run_op("debug", lt, { no_build = true })
        assert.are.equal(1, done.code)
        assert.matches("device target; this host cannot debug it", done.err, 1, true)
        assert.is_nil(done.fields)
        assert.is_false(deployed)
    end)

    it("refuses a foreign artifact found by probing with the in-process refusal, before deploy", function()
        local foreign = require("loomworks.remote.foreign")
        with(foreign, "refusal", function(f) return "REFUSED " .. f.name end)
        local deployed = false
        with(build_run, "profile_build_dirs", function() return {} end)
        with(build_run, "plan", function() return {} end)
        local lt = launch_target({ deploy_sync = function() deployed = true; return true end })
        local done = run_op("debug", lt, {}, { foreign = { reason = "probe", name = "app" } })
        assert.are.equal(1, done.code)
        assert.are.equal("REFUSED app", done.err)
        assert.is_false(deployed)
    end)

    it("refuses a target its kit tells is foreign before the build", function()
        local foreign = require("loomworks.remote.foreign")
        with(foreign, "refusal", function(f) return "REFUSED " .. f.name end)
        with(build_run, "profile_build_dirs", function() error("no lock may be taken") end)
        local done = run_op("debug", launch_target(), {}, { foreign = { reason = "token", name = "app" } })
        assert.are.equal(1, done.code)
        assert.are.equal("REFUSED app", done.err)
    end)

    -- ---- build_scope = "target" (§19.15 "Build scope of a launch") ----------

    it("builds the dependencies, deploys around the launch's own unit, then prepares; not the profile", function()
        local overseer = require("loomworks.task_plan")
        local calls = {}
        local lib_unit, app_unit = { name = "lib", config_key = ck }, { name = "app", config_key = ck }
        local planned_for = {}
        with(overseer, "plan_unit_build", function(_, unit, o)
            calls[#calls + 1] = "build " .. unit.name .. (o.target_id and (":" .. o.target_id) or "")
            planned_for[#planned_for + 1] = o.profile
            return {}
        end)
        with(build_run, "plan", function() error("the profile is not planned") end)
        with(build_run, "profile_build_dirs", function() error("no profile lock") end)
        local lt = launch_target({
            _launch = { command = "/bin/app" }, _config_unit = app_unit,
            abstract_error = function() return nil end,
            build_dependencies = function() return { { project = { key = "lib" } } } end,
            _resolve_dep_config_unit = function() return lib_unit end,
            _deploy_phase = function(_, phase, cb) calls[#calls + 1] = "deploy " .. phase; cb(true) end,
            deploy_sync = function() error("deployed twice") end,
        })
        local done, lines, profile = run_op("run", lt, { build_scope = "target", target = "hello" })
        assert.are.equal(0, done.code, done.err)
        assert.are.same({ "build lib", "deploy pre_build", "build app", "deploy post_build" }, calls)
        -- Each unit is planned against the REQUESTED profile, not the active one.
        assert.are.equal(2, #planned_for)
        assert.are.equal(profile, planned_for[1])
        assert.are.equal(profile, planned_for[2])
        assert.are.equal("/bin/app", done.fields.launch.cmd)
        assert.are.same({ "building launch target: app: hello", "building dependency: lib",
            "deploying (pre_build): 1 copy", "deploying (post_build): 1 copy" }, lines)
    end)

    -- ---- the profile build scope: resolve before the build (headless §16.17 "Order") ----

    --- Stub the profile plans: the configure phase returns `configures`, the
    --- build phase nothing; every plan's opts are recorded in `plans`.
    local function profile_plans(plans, configures)
        with(build_run, "profile_build_dirs", function() return {} end)
        with(build_run, "plan", function(_, o)
            plans[#plans + 1] = o
            if o.configure_pending then return configures or {} end
            return {}
        end)
    end

    it("a run with no launch target is refused after the configure phase, before any build", function()
        local plans = {}
        profile_plans(plans)
        local deploy = { deploy_sync = function() return true end }
        local done = run_op("run", launch_target(deploy), {})
        assert.are.equal(0, done.code, done.err)
        done = run_op("run", launch_target(deploy), {}, {
            select = function() return nil, "no default target set for profile 'dbg'." end })
        assert.are.equal(1, done.code)
        assert.are.equal("no default target set for profile 'dbg'.", done.err)
        -- (The first run planned configure + build; the refused one only its configure.)
        assert.are.equal(3, #plans)
        assert.is_true(plans[3].configure_pending)
    end)

    it("a run builds only its resolved target and the projects it depends on", function()
        local plans = {}
        profile_plans(plans)
        local App, Lib = { key = "app" }, { key = "lib" }
        local lt = launch_target({ _project = App, _target = { id = "hello" },
            deploy_sync = function() return true end,
            build_dependencies = function() return { { project = Lib } } end })
        -- (run_op's profile has every project.)
        local orig_picks = run_prep.build_picks
        with(run_prep, "build_picks", function(_, l)
            return orig_picks({ project = function() return {} end }, l)
        end)
        local done = run_op("run", lt, {})
        assert.are.equal(0, done.code, done.err)
        assert.are.equal(2, #plans)
        assert.is_true(plans[1].configure_pending)
        assert.are.same({ [App] = { "hello" }, [Lib] = {} }, plans[2].build_targets_for)
        assert.are.equal("/bin/app", done.fields.launch.cmd)
    end)

    it("a run always refreshes the target lists before it selects, configured or not", function()
        local plans, sel_opts = {}, {}
        profile_plans(plans)
        local lt = launch_target({ deploy_sync = function() return true end })
        local done = run_op("run", lt, {}, { select = function(_, _, _, _, _, o)
            sel_opts[#sel_opts + 1] = o or false
            return lt
        end })
        assert.are.equal(0, done.code, done.err)
        -- (The first select is the build phase's; the preparation selects again.)
        assert.is_true(sel_opts[1] and sel_opts[1].refresh, "the daemon's units may have outlived a build")
    end)

    --- Plans that hand out real steps (spawned through a stubbed
    --- runner.spawn): the configure phase `configures`, a reconfigure
    --- (`configure_only`) `reconfigures`, a build one build step; every
    --- spawned step's kind lands in `spawned`, every plan's opts in `plans`.
    local function step_plans(plans, spawned, configures, reconfigures, on_spawn)
        with(build_run, "profile_build_dirs", function() return {} end)
        with(build_run, "unit_build_dirs", function() return {} end)
        with(build_run, "plan", function(_, o)
            plans[#plans + 1] = o
            if o.configure_pending then return configures or {} end
            if o.configure_only then return reconfigures or {} end
            return { { kind = "build", name = "build", cmd = { "x" } } }
        end)
        with(build_run, "spawn_spec", function() return { cmd = { "x" }, cwd = "/ws" } end)
        with(build_run, "before_step", function() return true end)
        with(build_run, "step_lines", function() return {} end)
        with(build_run, "after_step", function() end)
        local cur
        with(build_run, "spawn_spec", function(step) cur = step; return { cmd = { "x" }, cwd = "/ws" } end)
        with(runner, "spawn", function(_, sink)
            spawned[#spawned + 1] = cur.kind .. ":" .. cur.name
            if on_spawn then on_spawn(cur) end
            sink.done(0)
        end)
    end

    it("the configure phase runs its steps, then the select, then the target's build", function()
        local plans, spawned = {}, {}
        local selected_after = nil
        step_plans(plans, spawned, { { kind = "configure", name = "app", cmd = { "x" } },
            { kind = "configure", name = "lib", cmd = { "x" } } })
        local lt = launch_target({ deploy_sync = function() return true end })
        local done = run_op("run", lt, {}, { select = function()
            selected_after = selected_after or #spawned
            return lt
        end })
        assert.are.equal(0, done.code, done.err)
        assert.are.equal(2, selected_after, "selected after both configures ran")
        assert.are.same({ "configure:app", "configure:lib", "build:build" }, spawned)
    end)

    it("the configure phase runs, the select fails: no build step is spawned", function()
        local plans, spawned = {}, {}
        step_plans(plans, spawned, { { kind = "configure", name = "app", cmd = { "x" } } })
        local done = run_op("run", launch_target(), {}, {
            select = function() return nil, "no default target set for profile 'dbg'." end })
        assert.are.equal(1, done.code)
        assert.are.equal("no default target set for profile 'dbg'.", done.err)
        assert.are.same({ "configure:app" }, spawned)
    end)

    it("a named target missing from a configured tree: its project reconfigured once, then found", function()
        local plans, spawned, sel = {}, {}, {}
        local unit = { name = "app" }
        with(run_prep, "reconfigure_units", function(_, name) return name == "NewTool" and { unit } or {} end)
        step_plans(plans, spawned, {}, { { kind = "configure", name = "app", cmd = { "x" } } })
        local lt = launch_target({ deploy_sync = function() return true end })
        local done = run_op("run", lt, { target = "NewTool" }, { select = function(_, _, _, _, _, o)
            sel[#sel + 1] = { spawned = #spawned, refresh = o and o.refresh }
            if #spawned == 0 then return nil, "no launch target 'NewTool' ...", "missing" end
            return lt
        end })
        assert.are.equal(0, done.code, done.err)
        assert.are.same({ "configure:app", "build:build" }, spawned)
        assert.is_true(#sel >= 2)
        assert.are.equal(0, sel[1].spawned)
        assert.are.equal(1, sel[2].spawned, "selected again after the reconfigure, before the build")
        assert.is_true(sel[2].refresh)
        local re
        for _, o in ipairs(plans) do if o.configure_only then re = o end end
        assert.truthy(re, "a reconfigure was planned")
        assert.is_true(re.reconfigure)
        assert.are.same({ unit }, re.units)
    end)

    it("a named target still missing after the reconfigure: refused, nothing built", function()
        local plans, spawned, n = {}, {}, 0
        with(run_prep, "reconfigure_units", function() return { { name = "app" } } end)
        step_plans(plans, spawned, {}, { { kind = "configure", name = "app", cmd = { "x" } } })
        local done = run_op("run", launch_target(), { target = "Nope" }, { select = function()
            n = n + 1
            return nil, "no launch target 'Nope'", "missing"
        end })
        assert.are.equal(1, done.code)
        assert.are.equal("no launch target 'Nope'", done.err)
        assert.are.equal(2, n, "selected once more after the one reconfigure")
        assert.are.same({ "configure:app" }, spawned)
    end)

    it("no named target: a failed select is never retried with a reconfigure", function()
        local plans, spawned, n = {}, {}, 0
        with(run_prep, "reconfigure_units", function() error("not for the default case") end)
        step_plans(plans, spawned, {})
        local done = run_op("run", launch_target(), {}, { select = function()
            n = n + 1
            return nil, "no default target set", "missing"
        end })
        assert.are.equal(1, done.code)
        assert.are.equal(1, n)
        assert.are.same({}, spawned)
    end)

    it("builds a module target's one target, and with no_build neither builds nor deploys", function()
        local overseer = require("loomworks.task_plan")
        local calls = {}
        with(overseer, "plan_unit_build", function(_, unit, o)
            calls[#calls + 1] = unit.name .. ":" .. tostring(o.target_id)
            return {}
        end)
        local lt = launch_target({
            _target = { id = "hello", _config_unit = { name = "app", config_key = ck } },
            abstract_error = function() return nil end,
            build_dependencies = function() return {} end,
            _deploy_phase = function(_, _, cb) cb(true) end,
        })
        local done = run_op("debug", lt, { build_scope = "target" })
        assert.are.equal(0, done.code, done.err)
        assert.are.same({ "app:hello" }, calls)
        calls = {}
        lt._deploy_phase = function() error("no deploy under no_build") end
        done = run_op("debug", lt, { build_scope = "target", no_build = true })
        assert.are.equal(0, done.code, done.err)
        assert.are.same({}, calls)
    end)

    it("ends at the first failing phase with the in-process message, the later phases not run", function()
        local overseer = require("loomworks.task_plan")
        local planned = false
        with(overseer, "plan_unit_build", function() planned = true; return {} end)
        local lt = launch_target({
            _launch = { command = "/bin/app" }, _config_unit = { name = "app", config_key = ck },
            abstract_error = function() return nil end,
            build_dependencies = function() return { { project = { key = "lib" } } } end,
            _resolve_dep_config_unit = function() return nil end,
            _deploy_phase = function() error("no deploy after a failure") end,
        })
        local done = run_op("run", lt, { build_scope = "target" })
        assert.are.equal(1, done.code)
        assert.matches("cannot resolve a configuration to build for dependency 'lib'", done.err, 1, true)
        assert.is_false(planned)
    end)

    -- ---- review fixes: probe before the post-build deploy, env object ------

    --- A target-scoped launch whose artifact is found foreign only by probing
    --- once its own unit has built.
    local function probed_foreign_target(calls)
        local overseer = require("loomworks.task_plan")
        local built = false
        with(overseer, "plan_unit_build", function(_, unit)
            calls[#calls + 1] = "build " .. unit.name
            if unit.name == "app" then built = true end
            return {}
        end)
        local lt = launch_target({
            _launch = { command = "/bin/app" }, _config_unit = { name = "app", config_key = ck },
            abstract_error = function() return nil end,
            build_dependencies = function() return {} end,
            _deploy_phase = function(_, phase, cb) calls[#calls + 1] = "deploy " .. phase; cb(true) end,
            deploy_sync = function() error("deployed by prepare") end,
        })
        return lt, function() return built and { reason = "probe", name = "app" } or nil end
    end

    it("refuses a target-scoped debug of a probed-foreign artifact before the post-build deploy", function()
        local foreign = require("loomworks.remote.foreign")
        with(foreign, "refusal", function(f) return "REFUSED " .. f.name end)
        local calls = {}
        local lt, foreign_of = probed_foreign_target(calls)
        local done = run_op("debug", lt, { build_scope = "target" }, { foreign = foreign_of })
        assert.are.equal(1, done.code)
        assert.are.equal("REFUSED app", done.err)
        assert.are.same({ "deploy pre_build", "build app" }, calls)
    end)

    it("hands a target-scoped run of a probed-foreign artifact to the client before the post-build deploy", function()
        local calls = {}
        local lt, foreign_of = probed_foreign_target(calls)
        local done = run_op("run", lt, { build_scope = "target" }, { foreign = foreign_of })
        assert.are.equal(0, done.code, done.err)
        assert.is_true(done.fields.device)
        assert.is_nil(done.fields.launch)
        assert.are.same({ "deploy pre_build", "build app" }, calls)
    end)

    it("encodes an empty launch environment as a JSON object (Common/1 env: object)", function()
        local done = run_op("debug", launch_target(), { no_build = true }, { env = {} })
        assert.are.equal(0, done.code, done.err)
        assert.matches('"env":{}', vim.json.encode(done.fields.result.debug), 1, true)
        done = run_op("run", launch_target(), { no_build = true }, { env = {} })
        assert.are.equal(0, done.code, done.err)
        assert.matches('"env":{}', vim.json.encode(done.fields.launch), 1, true)
    end)

    it("reports a target-scoped build's progress monotonically, unit steps inside their phase", function()
        local overseer = require("loomworks.task_plan")
        with(overseer, "plan_unit_build", function(_, unit)
            local steps = {}
            for n = 1, unit.steps do steps[n] = { kind = "build", name = unit.name .. n, cmd = { "x" } } end
            return steps
        end)
        with(build_run, "spawn_spec", function() return { cmd = { "x" }, cwd = "/ws" } end)
        with(build_run, "before_step", function() return true end)
        with(build_run, "step_lines", function() return {} end)
        with(build_run, "after_step", function() end)
        with(runner, "spawn", function(_, sink) sink.done(0) end)
        local lt = launch_target({
            _launch = { command = "/bin/app" }, _config_unit = { name = "app", config_key = ck, steps = 2 },
            abstract_error = function() return nil end,
            build_dependencies = function() return { { project = { key = "lib" } } } end,
            _resolve_dep_config_unit = function() return { name = "lib", config_key = ck, steps = 1 } end,
            _deploy_phase = function(_, _, cb) cb(true) end,
        })
        local prog = {}
        local done = run_op("run", lt, { build_scope = "target" }, { progress = prog })
        assert.are.equal(0, done.code, done.err)
        assert.is_true(#prog > 4)
        for n = 2, #prog do
            assert.is_true(prog[n] >= prog[n - 1], "progress went back: " .. table.concat(prog, ", "))
        end
        assert.is_true(prog[#prog] <= 1)
    end)
end)
