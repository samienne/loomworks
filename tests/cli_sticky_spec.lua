-- Live status line (loomworks.cli_sticky, spec §16.7): the line formatter and its
-- truncation, the tool-output classifier, the renderer's stream handling, and
-- run_spec's off path (byte-for-byte today's: inherited, env untouched).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local sticky = require("loomworks.cli_sticky")

local function plain(st, w, opts)
    local _, p = sticky.format(st, w, opts)
    return p
end

describe("cli_sticky.format", function()
    local st = { kind = "build", profile = "dev", name = "app", index = 2, count = 3,
        current = 143, total = 512, elapsed_ms = 41000, total_ms = 65000 }

    it("lays out every field when it fits", function()
        assert.equals(" BUILD  dev › app  step 2/3  [143/512]  0:41  (total 1:05) ",
            plain(st, 200))
    end)

    it("never exceeds width - 1 columns", function()
        for w = 2, 120 do
            assert.is_true(sticky._cols(plain(st, w)) <= w - 1, "width " .. w)
        end
    end)

    it("drops fields in order: total, step, elapsed, progress", function()
        local p = plain(st, 60)
        assert.matches("%(total 1:05%)", p)
        p = plain(st, 50)
        assert.not_matches("total", p)
        assert.matches("step 2/3", p)
        p = plain(st, 40)
        assert.not_matches("step", p)
        assert.equals(" BUILD  dev › app  [143/512]  0:41 ", p)
        p = plain(st, 33)
        assert.equals(" BUILD  dev › app  [143/512] ", p)
        p = plain(st, 20)
        assert.equals(" BUILD  dev › app ", p)
    end)

    it("shows no tool text even when given one", function()
        local with_msg = vim.tbl_extend("force", st, { message = "Building CXX object foo.o" })
        assert.equals(plain(st, 200), plain(with_msg, 200))
    end)

    it("shows make's percentage as progress", function()
        assert.equals(" BUILD  app  [ 45%]  0:01 ",
            plain({ kind = "build", name = "app", pct = 45, elapsed_ms = 1000 }, 100))
    end)

    it("ellipsizes the name when only it is left", function()
        local p = plain({ kind = "build", profile = "a-very-long-profile", name = "unit", elapsed_ms = 0 }, 20)
        assert.matches("…", p)
        assert.is_true(sticky._cols(p) <= 19)
    end)

    it("writes the final line with outcome and duration, no live fields", function()
        assert.equals(" ✓ BUILD  dev › app  [512/512]  1:05 ",
            plain({ kind = "build", profile = "dev", name = "app", index = 2, count = 3,
                current = 512, total = 512, elapsed_ms = 65000, total_ms = 99000 },
                100, { final = true }))
        assert.matches("^ ✗ CONFIGURE ", plain({ kind = "configure", name = "app", elapsed_ms = 0 }, 100,
            { final = false }))
    end)

    it("writes the phase-start line: kind, where, step i/n, no live fields or padding", function()
        assert.equals(" ▶ BUILD  dev › app  step 2/3 ", plain(st, 200, { start = true }))
        assert.equals(" ▶ CLEAN  dev › app ",
            plain({ kind = "clean", profile = "dev", name = "app", elapsed_ms = 0 }, 200, { start = true }))
        local styled = sticky.format(st, 200, { start = true, color = true })
        assert.matches("^\27%[0;1;7;36m ▶ BUILD \27%[0;7m", styled)
        styled = sticky.format(st, 200, { start = true, color = false })
        assert.matches("^\27%[0;1;7m ▶ BUILD \27%[0;7m", styled)
        assert.not_matches("36m", styled)
    end)

    it("uses reverse video, with colour only when asked", function()
        local styled = sticky.format(st, 100, { color = false })
        assert.matches("\27%[0;1;7m", styled)
        assert.not_matches("36m", styled)
        styled = sticky.format(st, 100, { color = true })
        assert.matches("\27%[0;1;7;36m", styled)
    end)

    it("strips control characters from names", function()
        assert.not_matches("\27", plain({ kind = "build", name = "x\27[31my", elapsed_ms = 0 }, 100))
    end)
end)

describe("cli_sticky.classify", function()
    it("reads ninja progress (passed through), with or without colour codes and CR", function()
        local c = sticky.classify("[3/10] Building CXX object src/CMakeFiles/a.dir/foo.cpp.o\r")
        assert.same({ tool = "ninja", current = 3, total = 10,
            message = "Building CXX object foo.cpp.o", pass = true }, c)
        assert.equals("ninja", sticky.classify("\27[1m[1/2] Linking x").tool)
    end)

    it("reads make percentages and cmake messages (passed through)", function()
        local c = sticky.classify("[ 45%] Building CXX object foo.o")
        assert.equals("make", c.tool)
        assert.equals(45, c.pct)
        assert.equals("Building CXX object foo.o", c.message)
        assert.same({ tool = "cmake", message = "Configuring done" }, sticky.classify("-- Configuring done"))
    end)

    it("leaves everything else alone", function()
        assert.is_nil(sticky.classify("foo.cpp:3:1: warning: unused [-Wunused]"))
        assert.is_nil(sticky.classify("FAILED: foo.o"))
        assert.is_nil(sticky.classify("  [3/10] indented"))
    end)
end)

describe("cli_sticky session", function()
    local written, t
    before_each(function()
        written, t = {}, 0
        sticky._write = function(s) written[#written + 1] = s end
        sticky._now = function() return t end
        sticky._width = function() return 60 end
    end)
    after_each(function()
        sticky._write, sticky._now, sticky._width = nil, nil, nil
        sticky.teardown()
    end)

    local function stream()
        -- What the terminal keeps: every write, sticky redraws removed.
        local s = table.concat(written)
        s = s:gsub("\27%[0;[%d;]*m[^\n\r]-\27%[0m\r", "")
        return s
    end

    it("passes every line through, ninja's included, and tracks its progress", function()
        local s = sticky.start({ kind = "build", name = "app", profile = "dev" })
        s:feed("[1/2] Building a.o\n")
        assert.equals(1, s.st.current)
        s:feed("\27[1mwarn\27[0m: x\n[2/2] Lin")
        s:feed("king app\n")
        assert.equals(2, s.st.current)
        assert.is_nil(s.st.message)
        t = 2000
        s:finish(true)
        local out = stream()
        -- Each line in full, in order, as ninja prints them on a pipe.
        assert.matches("^\27%[%?25l%[1/2%] Building a.o\n\27%[1mwarn\27%[0m: x\n%[2/2%] Linking app\n",
            (out:gsub("\r\27%[2K", "")))
        assert.matches("✓ BUILD  dev › app  %[2/2%]  0:02", (out:gsub("\27%[[%d;]*m", "")))
        assert.matches("\27%[%?25h$", out)
    end)

    it("writes a stale partial line out and keeps it intact", function()
        local s = sticky.start({ kind = "configure", name = "app" })
        s:feed("Enter value: ")
        t = 500
        s:tick()
        s:feed("ok\n")
        s:finish(false)
        assert.matches("Enter value: ok\n", stream())
        assert.matches("✗ CONFIGURE", stream())
    end)

    it("teardown clears the line and shows the cursor", function()
        sticky.start({ kind = "build", name = "app" })
        written = {}
        sticky.teardown()
        assert.equals("\r\27[2K\27[0m\27[?25h", table.concat(written))
        assert.is_nil(sticky._active)
    end)
end)

describe("cli_sticky gating", function()
    local env
    before_each(function()
        env = {}
        sticky._getenv = function(k) return env[k] end
        sticky._isatty = function() return true end
        sticky._enable_vt = function() return true end
    end)
    after_each(function()
        sticky._getenv, sticky._isatty, sticky._enable_vt = nil, nil, nil
        sticky.opt_out = false
    end)

    it("is on for a terminal and off by every opt-out", function()
        assert.is_true(sticky.enabled())
        env.TERM = "dumb"; assert.is_false(sticky.enabled()); env.TERM = nil
        env.LW_STICKY = "0"; assert.is_false(sticky.enabled()); env.LW_STICKY = nil
        sticky.opt_out = true; assert.is_false(sticky.enabled()); sticky.opt_out = false
        sticky._isatty = function(fd) return fd ~= 1 end
        assert.is_false(sticky.enabled())
    end)
end)

describe("run_spec with the sticky line off", function()
    local real_system, real_shim, captured
    before_each(function()
        real_system, real_shim = vim.system, vim._loomworks_shim
        vim._loomworks_shim = true
        vim.system = function(cmd, opts)
            captured = { cmd = cmd, opts = opts }
            return { wait = function() return { code = 0, stdout = "", stderr = "" } end }
        end
        sticky._isatty = function() return false end
    end)
    after_each(function()
        vim.system, vim._loomworks_shim = real_system, real_shim
        sticky._isatty = nil
        cli._sticky_step = nil
    end)

    it("inherits the terminal and leaves the environment as it was", function()
        cli._sticky_step = { kind = "build", name = "app" }
        cli._run_spec({ cmd = { vim.v.progpath }, env = { FOO = "1" } }, "/root")
        assert.equals("inherit", captured.opts.stdio)
        assert.is_nil(captured.opts.stdout)
        assert.is_nil(captured.opts.env.CLICOLOR_FORCE)
        assert.is_nil(captured.opts.env.FORCE_COLOR)
        assert.equals("1", captured.opts.env.FOO)
        assert.is_nil(cli._sticky_step)
    end)

    it("pipes and adds the colour env when on", function()
        sticky._isatty = function() return true end
        sticky._enable_vt = function() return true end
        sticky._write = function() end
        cli._sticky_step = { kind = "build", name = "app" }
        cli._run_spec({ cmd = { vim.v.progpath } }, "/root")
        sticky._write, sticky._enable_vt = nil, nil
        assert.is_nil(captured.opts.stdio)
        assert.equals("function", type(captured.opts.stdout))
        assert.equals("1", captured.opts.env.CLICOLOR_FORCE)
    end)
end)

describe("phase-start header", function()
    local real_shim, written
    before_each(function()
        real_shim = vim._loomworks_shim
        vim._loomworks_shim = true
        written = {}
        sticky._write = function(x) written[#written + 1] = x end
        sticky._width = function() return 120 end
        sticky._getenv = function(n) if n == "NO_COLOR" then return "1" end end
    end)
    after_each(function()
        vim._loomworks_shim = real_shim
        sticky._write, sticky._width, sticky._getenv, sticky._isatty, sticky._enable_vt = nil, nil, nil, nil, nil
    end)

    it("is not taken over when the sticky line is off (the header prints as today)", function()
        sticky._isatty = function() return false end
        assert.is_nil(cli._sticky_header(false))
    end)

    it("is not taken over for a stderr-routed (quiet) step", function()
        sticky._isatty = function() return true end
        sticky._enable_vt = function() return true end
        assert.is_nil(cli._sticky_header(true))
    end)

    it("is written as the sticky phase-start line when on (NO_COLOR: reverse only)", function()
        sticky._isatty = function() return true end
        sticky._enable_vt = function() return true end
        local w = cli._sticky_header(false)
        assert.equals(sticky.write_start, w)
        w({ kind = "build", name = "app", profile = "dev", index = 2, count = 3 })
        assert.equals("\r\27[2K\27[0;1;7m ▶ BUILD \27[0;7m dev › app  step 2/3 \27[0m\n",
            table.concat(written))
    end)
end)

describe("run phase bars (lw run)", function()
    local real_shim, written, real_write, outbuf
    before_each(function()
        real_shim = vim._loomworks_shim
        vim._loomworks_shim = true
        written = {}
        sticky._write = function(x) written[#written + 1] = x end
        sticky._width = function() return 40 end
        sticky._getenv = function(n) if n == "NO_COLOR" then return "1" end end
        local t = 0
        sticky._now = function() t = t + 12000; return t end
        outbuf = {}
        real_write = io.write
        io.write = function(...) for _, s in ipairs({ ... }) do outbuf[#outbuf + 1] = s end return io.stdout end
    end)
    after_each(function()
        io.write = real_write
        vim._loomworks_shim = real_shim
        sticky._write, sticky._width, sticky._getenv, sticky._isatty, sticky._enable_vt, sticky._now =
            nil, nil, nil, nil, nil, nil
    end)

    local spec = { name = "app", cmd = "/b/app", args = { "-x" }, cwd = "/w" }

    it("marks only the program's start when on; it still inherits the terminal", function()
        sticky._isatty = function() return true end
        sticky._enable_vt = function() return true end
        local got
        local code = cli._run_resolved(spec, {}, "/root", { run_spec = function(s, root)
            got = s
            assert.is_nil(cli._sticky_step)  -- no sticky line while it runs
            return 3
        end }, "dev")
        assert.equals(3, code)
        assert.same({ "/b/app", "-x" }, got.cmd)
        -- The start bar only: nothing after the program exits.
        assert.same({ "\r\27[2K\27[0;1;7m ▶ RUN \27[0;7m dev › app \27[0m\n" }, written)
        assert.equals("    $ /b/app -x\n    (in /w)\n", table.concat(outbuf))
    end)

    it("prints today's running line and nothing else when off", function()
        sticky._isatty = function() return false end
        local code = cli._run_resolved(spec, {}, "/root", { run_spec = function() return 0 end }, "dev")
        assert.equals(0, code)
        assert.same({}, written)
        assert.equals("running app [cwd: /w]: /b/app -x\n", table.concat(outbuf))
    end)
end)
