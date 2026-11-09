-- Saved test targets (spec §1.3.4, §16.9, §16.16, §17.6), in-process: the
-- `tests` array's parsing and resolution (bases depth-first, `[]` stops the
-- walk, duplicates by occurrence, invalid entries kept verbatim), the
-- `lw config set tests` refusal, the trust stripping and regraft of entry
-- args by name + occurrence, and the `lw test` plan (order, continuing
-- after a failure, `--saved` / `--discovered`). The daemon path is covered
-- by daemon_test_cli_spec; the editor's TestUnit / loomtest / status-page
-- wiring is tested in the plugin.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local tt = require("loomworks.test_targets")
local ConfigUnit = require("loomworks.config_unit")
local Target = require("loomworks.target")
local set_launches = require("tests.helpers").set_launches

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local rw, rs, rex, rstd = io.write, io.stderr, os.exit, io.stdout
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stdout = { write = function(_, s) out_buf[#out_buf + 1] = s end, flush = function() end }
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit, io.stdout = rw, rs, rex, rstd
    if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
    return { exit_code = exit_code, ret = ok and ret or nil,
        stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a"); f:close()
    return vim.json.decode(c)
end

--- Temp workspace: a typescript App with the given loomworks.json `App`
--- module section, plus a `Dev` set mapping App to `mapped` and a profile.
local created = {}
local function make_ws(section, mapped)
    local root = vim.fn.tempname():gsub("\\", "/")
    created[#created + 1] = root
    vim.fn.mkdir(root .. "/App", "p")
    local lw = { projects = { App = { typescript = section or vim.empty_dict() } },
        configuration_sets = { Dev = { App = mapped or "variant:default" } } }
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode(lw)); f:close()
    capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
    return root
end

local function load(root)
    local ws
    capture(function() ws = cli._load_workspace(root, false) end)
    return ws
end

local function project(ws, key)
    for _, p in pairs(ws._projects) do if p.key == key then return p end end
end

local function names(entries)
    local out = {}
    for _, e in ipairs(entries or {}) do out[#out + 1] = e.name or "<invalid>" end
    return out
end

-- ===========================================================================
describe("tests field: shape and resolution (§1.3.4)", function()
    after_each(function()
        for _, d in ipairs(created) do vim.fn.delete(d, "rf") end
        created = {}
    end)

    local SECTION = {
        tests = { "P1" },
        configurations = {
            Base = { inherits = "variant:default", tests = { "A", { "B", "--f" } } },
            Other = { inherits = "variant:default" },
            Child = { inherits = "Base" },
            Mix = { inherits = { "Other", "Base" } },
            Off = { inherits = "Base", tests = {} },
            Dups = { inherits = "variant:default", tests = { "A", { "A", "--two" }, "C", { "A" } } },
            Bad = { inherits = "variant:default", tests = { "A", { target = "X", args = { "--x" } }, 5, {}, { "Y", 3 } } },
            BadDecl = { inherits = "variant:default", tests = { targets = { "A" } } },
            BadChild = { inherits = "BadDecl" },
        },
    }

    it("own list, then bases depth-first left-to-right, then project-wide; [] stops", function()
        local ws = load(make_ws(SECTION, "Child"))
        local p = project(ws, "App")
        local base = p:get_configuration("Base")
        local r = p:get_configuration("Child"):test_targets()
        assert.same({ "A", "B" }, names(r.entries))
        assert.equals(base, r.source)             -- an object reference
        -- args from loomworks.json are program-bearing: dropped, entry kept (§17.6)
        assert.is_nil(r.entries[2].args)
        assert.equals(base, p:get_configuration("Mix"):test_targets().source)
        local off = p:get_configuration("Off"):test_targets()
        assert.same({}, off.entries)              -- explicit opt-out
        local gen = p:get_configuration("variant:default"):test_targets()
        assert.same({ "P1" }, names(gen.entries))
        assert.equals(p, gen.source)              -- project-wide
        assert.equals("inherited from Base", tt.source_text(r.source, p:get_configuration("Child")))
        assert.equals("project-wide", tt.source_text(gen.source, p:get_configuration("variant:default")))
    end)

    it("keeps duplicates, told apart by occurrence index (not position)", function()
        local decl = tt.parse({ "A", { "A", "--two" }, "C", { "A" } }, "App/Dups")
        assert.same({ "A", "A", "C", "A" }, names(decl.entries))
        local idx = {}
        for _, e in ipairs(decl.entries) do idx[#idx + 1] = e.index end
        assert.same({ 1, 2, 1, 3 }, idx)
        assert.is_true(decl.entries[1].repeated)
        assert.is_nil(decl.entries[3].repeated)
        assert.same({ "--two" }, decl.entries[2].args)
        assert.is_nil(decl.entries[4].args)       -- ["A"] is the same entry as "A"
        assert.equals("A #2", tt.entry_label(decl.entries[2]))
        assert.equals("C", tt.entry_label(decl.entries[3]))
        assert.equals("target:A", tt.entry_id(decl.entries[1], "target"))
        assert.equals("launch:A#3", tt.entry_id(decl.entries[4], "launch"))
        -- Serialized: a string without args, an array with args.
        assert.same({ "A", { "A", "--two" }, "C", "A" }, tt.serialize(decl))
        -- From the file too (the working copy keeps them all).
        local ws = load(make_ws(SECTION, "Child"))
        local d = project(ws, "App"):get_configuration("Dups")
        assert.same({ "A", "A", "C", "A" }, names(d:own_test_targets()))
    end)

    it("an invalid entry is kept verbatim and is missing; a non-array declaration stops the walk", function()
        local raw = { "A", { target = "X", args = { "--x" } }, 5, {}, { "Y", 3 } }
        local decl = tt.parse(raw, "App/Bad")
        assert.equals(5, #decl.entries)
        assert.same({ "A", "<invalid>", "<invalid>", "<invalid>", "<invalid>" }, names(decl.entries))
        assert.same(raw, tt.serialize(decl))      -- written back verbatim
        local r = tt.resolve_entry(decl.entries[2], { targets = {}, level = "App/Bad" })
        assert.equals("missing", r.state)
        -- Even with targets unknown, an invalid entry is missing.
        assert.equals("missing", tt.resolve_entry(decl.entries[3], { level = "App/Bad" }).state)

        local d2, invalid = tt.parse({ targets = { "A" } }, "App/BadDecl")
        assert.is_true(d2.invalid)
        assert.same({}, d2.entries)
        assert.same({ targets = { "A" } }, tt.serialize(d2, invalid))

        local ws = load(make_ws(SECTION, "Child"))
        local p = project(ws, "App")
        local bd = p:get_configuration("BadDecl")
        local eff = p:get_configuration("BadChild"):test_targets()
        assert.equals(bd, eff.source)             -- not the project-wide P1
        assert.is_true(eff.invalid)
        assert.same({ targets = { "A" } }, bd:serialize_user_override().tests)
    end)

    it("an editor edit emits tests_invalidated only (no active_set_changed / LSP re-evaluation)", function()
        local ws = load(make_ws(SECTION, "Child"))
        local events = ws._core._deps.events
        local seen = {}
        local on_inv = function() seen.inv = (seen.inv or 0) + 1 end
        local on_set = function() seen.set = (seen.set or 0) + 1 end
        events.on("tests_invalidated", on_inv)
        events.on("active_set_changed", on_set)
        local ok, err = project(ws, "App"):get_configuration("Child"):set_test_targets({ { name = "Z" } })
        events.off("tests_invalidated", on_inv)
        events.off("active_set_changed", on_set)
        assert.is_true(ok, err)
        assert.truthy((seen.inv or 0) >= 1)
        assert.is_nil(seen.set)
    end)

    it("is persisted only where declared, and a module never sees it", function()
        local root = make_ws(SECTION, "Child")
        local ws = load(root)
        local p = project(ws, "App")
        assert.is_true(p:get_configuration("Other"):set_test_targets({ { name = "Z" }, { name = "Z", args = { "--z" } } }))
        local user = read_json(root .. "/.lw/user.json")
        local cfgs = user.projects.App.typescript.configurations
        assert.same({ "Z", { "Z", "--z" } }, cfgs.Other.tests)
        assert.is_nil(cfgs.Child.tests)           -- derived: never a copy
        assert.same({ "P1" }, user.projects.App.typescript.tests)
        -- What the module is handed carries no `tests` anywhere.
        local tc = p:_type_config_for_module()
        assert.is_nil(tc.tests)
        for _, c in pairs(tc.configurations or {}) do assert.is_nil(c.tests) end
        assert.is_nil(p:get_configuration("Other").module_config.tests)
        -- …and a reload reads it back.
        local ws2 = load(root)
        assert.same({ "Z", "Z" }, names(project(ws2, "App"):get_configuration("Other"):own_test_targets()))
    end)

    it("never makes a unit stale; an older snapshot with `tests` compares without it", function()
        local unit = setmetatable({
            _configuration = { module_config = { variant = "Debug" } },
            _cached_options = {}, _cached_module_config = { variant = "Debug", tests = { "A" } },
            record_outdated = function() return false end,
            resolved_option_fingerprint = function() return {} end,
            env_changed = function() return false end,
            launcher_changed = function() return false end,
        }, { __index = ConfigUnit })
        assert.is_nil(ConfigUnit.stale_reason(unit))
        unit._cached_module_config = { variant = "Release", tests = { "A" } }
        assert.equals("module configuration changed", ConfigUnit.stale_reason(unit))
    end)

    it("`lw config set/unset tests…` is refused, naming lw test-target", function()
        local root = make_ws(SECTION, "Child")
        local r = capture(function() cli.cmd_configuration("set", root, "App", "Base", "tests", "A") end)
        assert.equals(2, r.exit_code)
        assert.truthy(r.stderr:find("lw test-target", 1, true))
        r = capture(function() cli.cmd_configuration("unset", root, "App", "Base", "tests") end)
        assert.equals(2, r.exit_code)
    end)

    it("resolves a launch configuration first, else an executable target; a trust-ignored launch is missing", function()
        local targets = {
            Both = { id = "Both", is_executable = function() return true end, display_name = function() return "Both" end },
            T = { id = "T", is_executable = function() return true end, display_name = function() return "T" end },
            Lib = { id = "Lib", is_executable = function() return false end, display_name = function() return "Lib" end },
            Ign = { id = "Ign", is_executable = function() return true end, display_name = function() return "Ign" end },
        }
        local ctx = {
            launches = { Both = { command = "tool" }, Chk = { target = "T" }, Dead = { target = "Lib" } },
            launch_ignored = function(n) return n == "Ign" end,
            targets = targets, level = "App/Tests",
        }
        local function r(n) return tt.resolve_entry({ name = n, index = 1 }, ctx) end
        assert.equals("launch", r("Both").kind)
        assert.is_true(r("Both").also_target)
        assert.equals("launch", r("Chk").kind)
        assert.equals(targets.T, r("Chk").target)
        assert.equals("missing", r("Dead").state)  -- its target is not an executable
        assert.equals("target", r("T").kind)
        assert.equals("missing", r("Lib").state)
        assert.equals("missing", r("Gone").state)
        local ign = r("Ign")                          -- never falls back to the same-named target
        assert.equals("missing", ign.state)
        assert.truthy(ign.reason:find("ignored", 1, true))
        -- A launch with neither `command` nor `target` is still the launch
        -- (missing), never the same-named build target.
        targets.Empty = { id = "Empty", is_executable = function() return true end, display_name = function() return "Empty" end }
        ctx.launches.Empty = { args = { "--x" } }
        local empty = r("Empty")
        assert.equals("launch", empty.kind)
        assert.equals("missing", empty.state)
        assert.is_nil(empty.target)
        -- Targets unknown: a command launch still resolves; a name does not.
        ctx.targets = nil
        assert.equals("ok", r("Both").state)
        assert.equals("unknown", r("T").state)
        assert.equals("unknown", r("Chk").state)
    end)
end)

-- ===========================================================================
describe("trust: entry args are program-bearing, regrafted by name + occurrence (§17.6)", function()
    after_each(function()
        for _, d in ipairs(created) do vim.fn.delete(d, "rf") end
        created = {}
    end)

    local pf = require("loomworks.program_fields")
    local SHARED = { projects = { App = { cmake = {
        tests = { { "PW", "--pw" } },
        configurations = { Tests = { variant = "Release", tests = {
            "BaseTests", { "RenderTests", "--gtest_filter=-*Slow*" }, { "RenderTests", "--gtest_filter=*Slow*" } } } },
    } } } }

    local function stripped()
        local cfg = require("loomworks.config").parse(vim.json.encode(SHARED), "/root")
        return cfg, pf.strip(cfg, require("loomworks.modules"))
    end

    it("strips only the args; the names still apply; the diagnostic names the occurrence", function()
        local cfg, ignored = stripped()
        local labels = {}
        for _, e in ipairs(ignored) do labels[#labels + 1] = e.label end
        table.sort(labels)
        assert.same({ "projects.App.cmake.configurations.Tests.tests", "projects.App.cmake.configurations.Tests.tests",
            "projects.App.cmake.tests" }, labels)
        assert.same({ "BaseTests", "RenderTests", "RenderTests" },
            cfg.projects.App.type_config.configurations.Tests.tests)
        assert.same({ "PW" }, cfg.projects.App.tests)
        local msgs = {}
        for _, d in ipairs(pf.diagnostics(ignored, cfg)) do msgs[#msgs + 1] = d.message end
        assert.truthy(vim.tbl_contains(msgs, "loomworks.json sets projects.App.cmake.configurations.Tests.tests "
            .. "(RenderTests #2 args = --gtest_filter=*Slow*) — ignored: program settings are used only "
            .. "from your local config (lw help trust)"), vim.inspect(msgs))
        assert.truthy(vim.tbl_contains(msgs, "loomworks.json sets projects.App.cmake.tests "
            .. "(PW args = --pw) — ignored: program settings are used only from your local config (lw help trust)"))
    end)

    it("a working copy that gives the same occurrence args silences only that diagnostic", function()
        local cfg, ignored = stripped()
        local merged = vim.deepcopy(cfg)
        merged.projects.App.type_config.configurations.Tests.tests[3] = { "RenderTests", "--mine" }
        local msgs = {}
        for _, d in ipairs(pf.diagnostics(ignored, merged)) do msgs[#msgs + 1] = d.message end
        assert.equals(2, #msgs)                       -- #1 and PW still reported
        for _, m in ipairs(msgs) do assert.falsy(m:find("RenderTests #2", 1, true)) end
    end)

    it("regraft restores args by name + occurrence index, never by position", function()
        local _, ignored = stripped()
        -- Published list reordered, another name inserted, a working-copy arg on #1.
        local raw = { projects = { App = { cmake = {
            tests = { "PW" },
            configurations = { Tests = { tests = { "New", { "RenderTests", "--mine" }, "BaseTests", "RenderTests" } } } } } } }
        local _, dropped = pf.regraft(raw, ignored)
        local t = raw.projects.App.cmake.configurations.Tests.tests
        assert.same({ "New", { "RenderTests", "--mine" }, "BaseTests", { "RenderTests", "--gtest_filter=*Slow*" } }, t)
        assert.same({ { "PW", "--pw" } }, raw.projects.App.cmake.tests)
        assert.same({}, dropped)
    end)

    it("fewer published entries of a name: the surplus args are dropped and named; extra entries get none", function()
        local _, ignored = stripped()
        local raw = { projects = { App = { cmake = { tests = { "PW" },
            configurations = { Tests = { tests = { "RenderTests" } } } } } } }
        local _, dropped = pf.regraft(raw, ignored)
        assert.same({ { "RenderTests", "--gtest_filter=-*Slow*" } }, raw.projects.App.cmake.configurations.Tests.tests)
        assert.equals(1, #dropped)
        assert.truthy(dropped[1]:find("RenderTests #2 args = --gtest_filter=*Slow*", 1, true), dropped[1])
        -- More entries named N than the shared layer had: the extra one gets nothing.
        local raw2 = { projects = { App = { cmake = { tests = { "PW" },
            configurations = { Tests = { tests = { "RenderTests", "RenderTests", "RenderTests" } } } } } } }
        local _, d2 = pf.regraft(raw2, ignored)
        local t2 = raw2.projects.App.cmake.configurations.Tests.tests
        assert.equals("RenderTests", t2[3])
        assert.same({ "RenderTests", "--gtest_filter=*Slow*" }, t2[2])
        assert.same({}, d2)
    end)

    it("a published entry dropping the item drops its args silently (item not published)", function()
        local _, ignored = stripped()
        local raw = { projects = {} }
        local _, dropped = pf.regraft(raw, ignored)
        assert.same({}, dropped)
    end)
end)

-- ===========================================================================
-- Fakes for the headless plan: a unit with an optional batch runner, a saved
-- list (file shape) and parsed targets.
local function fake_target(name, kind)
    return { id = name, is_executable = function() return kind ~= "lib" end,
        display_name = function() return name end, artifact = name }
end

local function fake_unit(key, o)
    o = o or {}
    local cfg = { name = o.cfg or "Tests", _project = nil, variables = o.cfg_vars }
    local project = set_launches({ key = key, variables = o.variables,
        _module = { impl = { parse_targets = function() return {} end } } }, o.launch)
    cfg._project = project
    local unit = {
        _project = project, targets = o.targets, _configuration = cfg, build_dir_value = o.build_dir,
        variant = function() return "Debug" end,
        configured_here = function() return o.here ~= false end,
        tool_object = function() return o.foreign and { key = "kit", execution_platform = function() return "arm64" end } or nil end,
        batch_runner_test_units = function()
            return o.batch and { { run_command_all = function() return { cmd = { "ctest" } } end } } or {}
        end,
        saved_test_targets = function()
            if not o.saved then return nil end
            local decl = tt.parse(o.saved, key .. "/Tests")
            return { entries = decl.entries, source = cfg, invalid = decl.invalid }
        end,
        build_dir = function() return o.build_dir end,
    }
    local pp = { _config_unit = unit, variant_name = function() return cfg.name end,
        configuration = function() return cfg end }
    return unit, pp
end

local function fake_profile(pps)
    local by = {}
    for _, pp in ipairs(pps) do by[pp._config_unit._project.key] = pp end
    return { key = "Dev:kit", projects = function() return pps end, project = function(_, k) return by[k] end }
end

describe("lw test plan (§16.16)", function()
    after_each(function()
        for _, d in ipairs(created) do vim.fn.delete(d, "rf") end
        created = {}
    end)

    local ov = require("loomworks.task_plan")
    local gtest = require("loomworks.gtest")
    local orig_plan, orig_probe
    local probed

    before_each(function()
        probed = {}
        orig_plan, orig_probe = ov.plan_profile_test, gtest.probe_sync
        gtest.probe_sync = function(exe) probed[#probed + 1] = exe; return nil end
        ov.plan_profile_test = function(profile, opts)
            local steps = {}
            for _, pp in ipairs(profile:projects()) do
                local u = pp._config_unit
                if not (opts.skip_units or {})[u] and u.batch_runner_test_units()[1] then
                    local label = u._project.key .. ":Debug"
                    steps[#steps + 1] = { unit = u, name = label, runner = "ctest", cmd = { "ctest", label },
                        junit_dest = opts.junit_dest_for and opts.junit_dest_for(label, u) or nil,
                        -- A self-rebuilding runner without a no-rebuild option (§8.9.2).
                        refused = (opts.no_rebuild and u._cannot_skip_rebuild) and "cannot skip" or nil,
                        no_rebuild = opts.no_rebuild }
                end
            end
            return steps, #profile:projects()
        end
    end)
    after_each(function() ov.plan_profile_test, gtest.probe_sync = orig_plan, orig_probe end)

    --- A fake LaunchTarget for a resolved candidate: a build target runs
    --- /bin/<name>; a launch runs its config's program with its own args, and
    --- records its deploy.
    local function fake_lt(c, log, deploy_fail)
        local cfg = c.kind == "launch" and c.project:find_launch(c.name) or nil
        return {
            _launch = cfg,
            is_valid = function() return true end,
            deploy_sync = function()
                log[#log + 1] = "deploy " .. c.name
                if deploy_fail and deploy_fail[c.name] then return false, "boom" end
                return true
            end,
            resolve_launch_spec = function()
                if cfg then
                    return { cmd = cfg.command or ("/bin/" .. cfg.target), args = vim.deepcopy(cfg.args or {}),
                        cwd = cfg.working_dir or "/", env = cfg.env }
                end
                return { cmd = "/bin/" .. c.name, args = {}, cwd = "/" }
            end,
        }
    end

    local function run_plan(profile, opts, codes, ws, deploy_fail, more)
        local ran, built, log = {}, nil, {}
        local deps = more or {}
        for k, v in pairs({
            build = function(_, _, keep) built = keep end,
            run_spec = function(step)
                local line = table.concat(step.cmd, " ")
                ran[#ran + 1] = line
                log[#log + 1] = "run " .. line
                if step.cwd and step.cwd ~= "/" then log[#log + 1] = "cwd " .. step.cwd end
                for k, v in pairs(step.env or {}) do log[#log + 1] = "env " .. k .. "=" .. v end
                return (codes or {})[step.cmd[2] or step.cmd[1]] or 0
            end,
            launch_target = function(_, _, c) return fake_lt(c, log, deploy_fail) end,
        }) do deps[k] = v end
        opts.extra = opts.extra or {}
        opts.dev = opts.dev or cli._new_device_opts()
        local r = capture(function() return cli._test_plan(ws or { root = "/" }, profile, opts, deps) end)
        r.ran, r.built, r.log = ran, built, log
        return r
    end

    local function two_units()
        local a, ppa = fake_unit("A", { batch = true, saved = { "X", { "Y", "--y" } },
            targets = { X = fake_target("X"), Y = fake_target("Y") } })
        local b, ppb = fake_unit("B", { saved = { "Z" }, targets = { Z = fake_target("Z") } })
        return fake_profile({ ppa, ppb }), a, b
    end

    it("runs per unit: batch step first, then saved executables in list order", function()
        local profile, a = two_units()
        local r = run_plan(profile, {})
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "ctest A:Debug", "/bin/X", "/bin/Y --y", "/bin/Z" }, r.ran)
        assert.truthy(r.built[a])                           -- built despite a batch runner
        local hdr = {}
        for l in r.stdout:gmatch("==> %[test%] ([^\n]+)") do hdr[#hdr + 1] = l end
        assert.same({ "A: ctest", "A: X", "A: Y", "B: Z" }, hdr)
        assert.truthy(r.stdout:find("TESTS OK: Dev:kit (4 steps)", 1, true))
        -- Not a framework executable: judged on its exit status, said so.
        assert.truthy(r.stdout:find("A: X%s+passed  %(exit status only — no per%-case results%)"), r.stdout)
    end)

    it("-v prints each runner / program command and its directory under the step header", function()
        local profile = two_units()
        local quiet = run_plan(profile, {})
        assert.is_nil(quiet.stdout:find("    $ ", 1, true), quiet.stdout)
        local r = run_plan(profile, { verbose = true }, nil, { root = "/ws" })
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stdout:find("==> [test] A: ctest\n    $ ctest A:Debug\n    (in /ws)\n", 1, true), r.stdout)
        assert.truthy(r.stdout:find("==> [test] A: Y\n    $ /bin/Y --y\n    (in /)\n", 1, true), r.stdout)
    end)

    it("every step runs after a failure; the summary names it; exit 1", function()
        local profile = two_units()
        local r = run_plan(profile, {}, { ["A:Debug"] = 8 })
        assert.equals(1, r.exit_code)
        assert.equals(4, #r.ran)
        assert.truthy(r.stdout:find("A: ctest%s+FAILED %(exit status 8%)"))
        assert.truthy(r.stderr:find("1 of 4 test steps failed", 1, true))
    end)

    it("highlights outcome lines by role; the summary heading stays plain (spec §16.7)", function()
        local cc = require("loomworks.cli_color")
        cc.mode = "always"
        local ok_run = run_plan((two_units()), {})
        local fail_run = run_plan((two_units()), {}, { ["A:Debug"] = 8 })
        cc.mode = "auto"
        local E = "\27["
        assert.truthy(ok_run.stdout:find("\nsummary — profile 'Dev:kit':\n", 1, true), ok_run.stdout)
        assert.truthy(ok_run.stdout:find("\27%[32m  A: X%s+passed"), ok_run.stdout)
        assert.truthy(ok_run.stdout:find(E .. "32mTESTS OK: Dev:kit (4 steps)" .. E .. "0m", 1, true))
        assert.truthy(fail_run.stdout:find("\27%[31m  A: ctest%s+FAILED %(exit status 8%)"), fail_run.stdout)
        assert.truthy(fail_run.stderr:find(E .. "31mlw: 1 of 4 test steps failed", 1, true), fail_run.stderr)
    end)

    it("--saved runs only executables, --discovered only batch steps", function()
        local profile = two_units()
        assert.same({ "/bin/X", "/bin/Y --y", "/bin/Z" }, run_plan(profile, { sel = "saved" }).ran)
        assert.same({ "ctest A:Debug" }, run_plan(profile, { sel = "discovered" }).ran)
    end)
end)
