-- `lw pin ignore|follow` switching the workspace daemon (daemon §19.9 "Pin
-- mode switch", headless §16.24): an idle daemon of the previous build is
-- stopped, a busy one is sent `retire`, one of the new identity is left
-- alone, one that does not answer is reported; nothing is launched. The
-- daemon side is faked (loomworks.pin_mode.switch takes its seams); the file
-- side (`.lw/local`) runs on a real temporary directory.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local pm = require("loomworks.pin_mode")
local pin = require("boot.pin")
local uv = vim.uv or vim.loop

local function fake(kind, reply)
    local calls = { stop = 0, requests = {} }
    local opts = {
        state = function(root) return { kind = kind, root = root, lock = { pid = 4242 } } end,
        query = function() return reply, reply == nil and "timed out" or nil, nil end,
        request = function(_, k) calls.requests[#calls.requests + 1] = k; return {} end,
        stop = function(_, host) calls.stop = calls.stop + 1; host.out("stopped"); return 0 end,
    }
    return opts, calls
end

describe("pin mode switch (daemon §19.9)", function()
    it("stops an idle daemon of the previous build", function()
        local opts, calls = fake("live", { kind = "status", lw_version = "0.1.43", busy = false, clients = 1 })
        local line = pm.switch("/ws", "0.2.0+dev.abc", "0.2.0+dev", opts)
        assert.equals(1, calls.stop)
        assert.same({}, calls.requests)
        assert.equals("lw: stopped the workspace daemon (lw 0.1.43); the next command starts lw 0.2.0+dev", line)
    end)

    it("sends retire to a busy daemon and never stops it", function()
        local opts, calls = fake("live", { kind = "status", lw_version = "0.1.43", busy = true, clients = 1 })
        local line = pm.switch("/ws", "0.2.0+dev.abc", "0.2.0+dev", opts)
        assert.equals(0, calls.stop)
        assert.same({ "retire" }, calls.requests)
        assert.equals("lw: the workspace daemon (lw 0.1.43) is busy - it restarts as lw 0.2.0+dev when idle", line)
    end)

    it("leaves a daemon of the new identity, and no daemon, alone", function()
        local opts, calls = fake("live", { kind = "status", lw_version = "0.1.43", busy = false, clients = 1 })
        assert.is_nil(pm.switch("/ws", "0.1.43", "0.1.43", opts))
        assert.equals(0, calls.stop)
        assert.same({}, calls.requests)
        local o2, c2 = fake("none")
        assert.is_nil(pm.switch("/ws", "0.1.43", "0.1.43", o2))
        assert.equals(0, c2.stop)
    end)

    it("reports a daemon that does not answer, naming lw daemon stop", function()
        local opts, calls = fake("live", nil)
        local line = pm.switch("/ws", "0.1.43", "0.1.43", opts)
        assert.matches("does not answer", line, 1, true)
        assert.matches("lw daemon stop", line, 1, true)
        assert.equals(0, calls.stop)
        local o2 = fake("hung")
        assert.matches("pid 4242", pm.switch("/ws", "0.1.43", "0.1.43", o2), 1, true)
    end)

    it("a stop that fails is one line, not an error", function()
        local opts = fake("live", { kind = "status", lw_version = "0.1.43", busy = false, clients = 1 })
        opts.stop = function(_, host) host.die("the workspace daemon (pid 4242) is not responding", 1) end
        local line = pm.switch("/ws", "0.2.0", "0.2.0", opts)
        assert.matches("could not stop the workspace daemon (lw 0.1.43): the workspace daemon (pid 4242) is not",
            line, 1, true)
    end)

    it("the effective build: the pinned release when following, this lw when ignoring", function()
        local own = require("loomworks.daemon.version").identity()
        assert.equals(own, (pm.effective("ignore", "0.1.43")))
        assert.equals("0.1.43", (pm.effective("follow", "0.1.43")))
        assert.equals(own, (pm.effective("follow", nil)))
    end)
end)

describe("lw pin (headless §16.24)", function()
    local root
    local outl, errl
    local io_ = {
        out = function(l) outl[#outl + 1] = l end,
        err = function(l) errl[#errl + 1] = l end,
    }
    local function run(args, ctx)
        outl, errl = {}, {}
        local code = pm.run(args, ctx or { start = root, pin_root = root, invoked = "global" }, io_)
        return code, table.concat(outl, "\n"), table.concat(errl, "\n")
    end
    before_each(function()
        local d = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwpinXXXXXX")
        root = ((uv.fs_realpath(d) or d):gsub("\\", "/"))
        local f = assert(io.open(root .. "/lw.pin", "wb"))
        f:write("version = 0.1.43\n"); f:close()
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    it("ignore writes .lw/local with its self-ignore file; follow deletes it", function()
        local code, out = run({ "pin", "ignore" })
        assert.equals(0, code)
        assert.matches("pin ignored here - this checkout now runs", out, 1, true)
        assert.matches("(pinned 0.1.43); lw pin follow undoes it", out, 1, true)
        local f = assert(io.open(root .. "/.lw/local", "rb"))
        local text = f:read("*a"); f:close()
        assert.equals(pin.LOCAL_IGNORE_TEXT, text)
        assert.equals("ignore", (pin.read_local(root)))
        assert.truthy(uv.fs_stat(root .. "/.lw/.gitignore"))
        code, out = run({ "pin" })
        assert.equals(0, code)
        assert.matches("mode      ignore", out, 1, true)
        code, out = run({ "pin", "ignore" })
        assert.equals(0, code)
        assert.matches("already ignored", out, 1, true)
        code, out = run({ "pin", "follow" })
        assert.equals(0, code)
        assert.matches("following the pin again", out, 1, true)
        assert.is_nil(uv.fs_lstat(root .. "/.lw/local"))
        code, out = run({ "pin", "follow" })
        assert.equals(0, code)
        assert.matches("already following the pin (lw 0.1.43)", out, 1, true)
        code, out = run({ "pin" })
        assert.matches("mode      follow", out, 1, true)
    end)

    it("ignore without a pin refuses and writes nothing", function()
        os.remove(root .. "/lw.pin")
        local code, _, err = run({ "pin", "ignore" }, { start = root, invoked = "global" })
        assert.equals(1, code)
        assert.equals("lw: no lw.pin here - nothing to ignore", err)
        assert.is_nil(uv.fs_lstat(root .. "/.lw"))
    end)

    it("follow refuses a .lw/local that is not a regular file", function()
        vim.fn.mkdir(root .. "/.lw/local", "p")
        local code, _, err = run({ "pin", "follow" })
        assert.equals(1, code)
        assert.matches("is not a regular file - not removed", err, 1, true)
        assert.truthy(uv.fs_stat(root .. "/.lw/local"))
    end)

    it("usage errors exit 2", function()
        assert.equals(2, (run({ "pin", "bogus" })))
        assert.equals(2, (run({ "pin", "ignore", "x" })))
        assert.equals(2, (run({ "pin", "--frobnicate" })))
        assert.equals(0, (run({ "pin", "--no-input" })))
    end)

    it("follow onto an older pinned lw warns once, on standard error", function()
        run({ "pin", "ignore" })
        local _, v = pm.running()
        local code, _, err = run({ "pin", "follow" })
        assert.equals(0, code)
        if pin.older("0.1.43", v) then
            assert.equals("lw: moving this checkout to the older lw 0.1.43 (from " .. v .. "): it may drop settings"
                .. " it does not know when it saves .nvim/loomworks.user.json, and may refuse state a newer lw"
                .. " wrote (lw reset --state discards the build cache)", err)
        else
            assert.equals("", err)
        end
    end)
end)
