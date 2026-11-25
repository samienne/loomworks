-- The device log's commands as a launch target builds them
-- (LaunchTarget:device_log_command / device_log_clear_command): the one
-- builder the editor's in-process log view (session_tracker) and the
-- workspace daemon's `Launch/1.device_log` (API.md §9.5, step 5n B3) share.
-- The log options (spec core §11.2 `device_log_options`, §11.3 "Log
-- options"; loomworks #196): merged project → launch configuration →
-- per-invocation overrides, passed to the module's hook, its resolved fields
-- validated; a module without the hook.

local LaunchTarget = require("loomworks.launch_target")

--- A target of a project whose module is `impl`, its unit's tool data `td`;
--- `extra`: the project's `device_log` and the launch configuration's.
local function target(impl, td, extra)
    extra = extra or {}
    return setmetatable({
        _project = { key = "app", _module = { impl = impl }, device_log = extra.project },
        _config_unit = { _tool_data = td or { sdk = "x" } },
        _launch = extra.launch and { device_log = extra.launch } or nil,
    }, LaunchTarget)
end

--- A module whose `device_log` records its calls in `calls`.
local function module(calls)
    return {
        device_log = function(td, serial, opts)
            calls[#calls + 1] = { td = td, serial = serial, opts = opts }
            return { cmd = "hdc", args = { "-t", serial, "hilog" }, env = { A = "1" } }
        end,
    }
end

describe("LaunchTarget device log commands", function()
    it("device_log_command passes the pid only when the module asks for strict-pid filtering", function()
        local calls = {}
        local impl = module(calls)
        local cmd, o = target(impl):device_log_command("SER1", 4242)
        assert.same({ name = "app: device log on SER1", cmd = "hdc", args = { "-t", "SER1", "hilog" },
            env = { A = "1" } }, cmd)
        assert.same({ level = "I", strict_pid = false, prefilter = "strict" }, o)
        assert.same({ options = {} }, calls[1].opts)
        assert.same({ sdk = "x" }, calls[1].td)
        impl.device_log_options = function() return { level = "W", strict_pid = true } end
        cmd, o = target(impl):device_log_command("SER1", 4242)
        assert.same({ level = "W", strict_pid = true, prefilter = "strict" }, o)
        assert.same({ pid = 4242, options = { level = "W", strict_pid = true } }, calls[2].opts)
    end)

    it("merges the log options project → launch configuration → overrides and hands them to the hook", function()
        local calls, seen = {}, {}
        local impl = module(calls)
        impl.device_log_options = function(td, options)
            seen[#seen + 1] = { td = td, options = vim.deepcopy(options) }
            return { level = options.level, prefilter = options.prefilter, type = options.type, mine = true }
        end
        local t = target(impl, nil, {
            project = { level = "W", prefilter = "app-related", type = "app" },
            launch = { level = "E", type = "core" },
        })
        local cmd, o = t:device_log_command("SER1", 7, { type = "kmsg" })
        assert.truthy(cmd)
        assert.same({ sdk = "x" }, seen[1].td)
        assert.same({ level = "E", prefilter = "app-related", type = "kmsg" }, seen[1].options)
        assert.same({ level = "E", strict_pid = false, prefilter = "app-related" }, o)
        -- device_log gets the module's own resolved table, and no pid.
        assert.same({ options = { level = "E", prefilter = "app-related", type = "kmsg", mine = true } },
            calls[1].opts)
        -- The project's table alone; the files' tables are never mutated.
        local p = target(impl, nil, { project = { level = "D" } })
        local _, o2 = p:device_log_command("SER1", 7)
        assert.same({ level = "D" }, seen[2].options)
        assert.equals("D", o2.level)
        assert.same({ level = "D" }, p._project.device_log)
    end)

    it("a module refusal, a hook error or an invalid resolved field refuses the stream", function()
        local calls = {}
        local impl = module(calls)
        impl.device_log_options = function(_, options)
            if options.tag then return nil, "device_log: option 'tag' does not apply to a device target" end
            return {}
        end
        local cmd, o, err = target(impl, nil, { project = { tag = "X" } }):device_log_command("SER1", 7)
        assert.is_nil(cmd)
        assert.is_nil(o)
        assert.equals("device_log: option 'tag' does not apply to a device target", err)
        impl.device_log_options = function() error("boom") end
        cmd, _, err = target(impl):device_log_command("SER1", 7)
        assert.is_nil(cmd)
        assert.truthy(err:find("boom", 1, true), err)
        for _, bad in ipairs({ { level = "X" }, { prefilter = "pid" }, { strict_pid = "yes" } }) do
            impl.device_log_options = function() return bad end
            cmd, _, err = target(impl):device_log_command("SER1", 7)
            assert.is_nil(cmd)
            assert.truthy(err:find(next(bad), 1, true), err)
        end
        impl.device_log_options = function() return "nope" end
        cmd, _, err = target(impl):device_log_command("SER1", 7)
        assert.is_nil(cmd)
        assert.truthy(err)
        assert.equals(0, #calls)
    end)

    it("a module without the hook: configured options are a note, per-invocation ones refuse", function()
        local calls = {}
        local impl = module(calls)
        local cmd, o, err = target(impl, nil, { project = { level = "W" }, launch = { tag = "T" } })
            :device_log_command("SER1", 7)
        assert.truthy(cmd, err)
        assert.equals("I", o.level)
        assert.equals("strict", o.prefilter)
        assert.truthy(o.note:find("level, tag", 1, true), o.note)
        assert.same({ options = {} }, calls[1].opts)
        cmd, o, err = target(impl, nil, { project = { level = "W" } }):device_log_command("SER1", 7, { show = "x" })
        assert.is_nil(cmd)
        assert.is_nil(o)
        assert.truthy(err:find("'show'", 1, true), err)
        -- No options at all: no note.
        local _, o3 = target(impl):device_log_command("SER1", 7)
        assert.is_nil(o3.note)
    end)

    it("device_log_command is nil without a module command", function()
        assert.is_nil(target({}):device_log_command("SER1", 1))
        assert.is_nil(target({ device_log = function() return nil end }):device_log_command("SER1", 1))
        assert.is_nil(setmetatable({}, LaunchTarget):device_log_command("SER1", 1))
    end)

    it("device_log_clear_command is the module's optional clear, nil without one", function()
        local impl = { device_log_clear = function(_, serial) return { cmd = "hdc", args = { serial, "-r" } } end }
        assert.same({ name = "app: clear device log on SER1", cmd = "hdc", args = { "SER1", "-r" } },
            target(impl):device_log_clear_command("SER1"))
        assert.is_nil(target({}):device_log_clear_command("SER1"))
        assert.is_nil(target({ device_log_clear = function() return {} end }):device_log_clear_command("SER1"))
    end)
end)
