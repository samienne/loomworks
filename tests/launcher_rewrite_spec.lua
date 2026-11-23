--- Tests for lw.cmd being rewritten while it runs (spec headless §16.22
--- *Rewritten while it runs*, §16.24 *Install*): `.\lw.cmd bootstrap install`
--- rewrites the lw.cmd that cmd.exe is executing; cmd reads the next line at
--- its old byte offset once lw exits. The current template runs lw and exits
--- on one line, and begins with a landing zone where every earlier generation
--- resumes (the note on replacing unknown content: tests/standalone/main.lua).

local launcher = require("boot.launcher")
local uv = vim.uv or vim.loop

local RUN_LINE = '"%PINBIN%"%fwd% & call :status & call exit /b %%ERRORLEVEL%%'
-- The two lines every generation up to 0.2.0-beta.16 ended its run with.
local OLD_RUN = '"%PINBIN%"%fwd% & call :status\nexit /b %ERRORLEVEL%'
local BETA16 = "866d6e068578db05d05e85e31bc9418249bc1a85304314d4b9cf362c56ac75db"

local function lines(s)
  local t = {}
  for l in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end
  return t
end

describe("lw.cmd rewritten while it runs", function()
  it("runs lw and exits on one line, with nothing after it but the subroutines", function()
    local ls = lines(launcher.normalize(launcher.LW_CMD))
    local at
    for i, l in ipairs(ls) do
      if l:find('"%PINBIN%"', 1, true) then
        assert.is_nil(at, "one pinned run")
        at = i
      end
    end
    assert.equals(RUN_LINE, ls[at])
    -- what follows is reached only by `call :status` / `call :sha` (a label
    -- lookup, valid in any later generation), never by falling through
    assert.equals("", ls[at + 1])
    assert.equals(":status", ls[at + 2])
    assert.equals("exit /b", ls[at + 3])
    -- the LOOMWORKS_LW run is a parenthesised block, parsed whole
    local text = launcher.normalize(launcher.LW_CMD)
    assert.truthy(text:find('(\n  "%LOOMWORKS_LW%" %* & call :status\n  exit /b !ERRORLEVEL!\n)', 1, true))
  end)

  it("catalogues every earlier lw.cmd generation with its resume offset", function()
    local cur = vim.fn.sha256(launcher.normalize(launcher.LW_CMD))
    assert.is_nil(launcher.GENERATIONS.cmd[cur])
    assert.equals(10, launcher.GENERATIONS.cmd[BETA16].gen)
    for hash, g in pairs(launcher.GENERATIONS.cmd) do
      assert.is_number(g.resume, hash)
      for _, d in ipairs(g.defects) do
        assert.is_nil(d.text:find("rewrites it during its own run", 1, true), hash)
      end
    end
  end)

  -- The landing zone (launcher.lua, CMD_LANDING): where an older lw.cmd that
  -- lw replaced while it ran resumes reading the new file.
  local MARGIN = 1024
  local function landing(crlf)
    local first = crlf:find("\r\n:::", 1, true) + 2 -- 1-based start of the first colon line
    local exit_at = crlf:find("\r\n@exit /b %ERRORLEVEL%\r\n:lw_start\r\n", 1, true) + 2
    return first - 1, exit_at - 1 -- 0-based: [start, stop) is all colon lines
  end

  it("begins with a landing zone covering every catalogued resume offset", function()
    local crlf = launcher.render("cmd")
    assert.equals("@goto lw_start\r\n", crlf:sub(1, 16))
    local start, stop = landing(crlf)
    local zone = crlf:sub(start + 1, stop)
    assert.equals(launcher.CMD_LANDING_LINES * 64, #zone)
    assert.truthy(zone:match("^[:\r\n]+$"))
    for l in zone:gmatch("(.-)\r\n") do assert.truthy(l:match("^:+$"), l) end
    for hash, g in pairs(launcher.GENERATIONS.cmd) do
      assert.is_true(g.resume >= start and g.resume + MARGIN <= stop,
        ("%s resumes at %d, zone [%d, %d)"):format(hash, g.resume, start, stop))
    end
    -- the run line, :status (spec 16.22) and :lw_start each appear once
    local _, n = crlf:gsub("\r\n:lw_start\r\n", "")
    assert.equals(1, n)
    _, n = crlf:gsub("\r\n:status\r\n", "")
    assert.equals(1, n)
  end)

  -- tests/fixtures/launchers/cmd/genNN.cmd: the lw.cmd each generation wrote
  -- (from its release tag), LF-normalized.
  local FIX = "tests/fixtures/launchers/cmd/"
  local function fixtures()
    local t = {}
    for name in vim.fs.dir(FIX) do
      if name:match("^gen%d+%.cmd$") then t[#t + 1] = name end
    end
    table.sort(t)
    return t
  end
  local function read(path)
    local fh = assert(io.open(path, "rb")); local s = fh:read("*a"); fh:close(); return s
  end
  local function write(path, s)
    local fh = assert(io.open(path, "wb")); fh:write(s); fh:close()
  end
  -- 0-based offset just past the last line that runs the pinned lw.
  local function resume_of(crlf)
    local at
    for s, l, e in crlf:gmatch("()([^\r\n]*)\r\n()") do
      if l:find('^"%%PINBIN%%"') then at = e - 1 end
    end
    return at
  end

  it("has a fixture for every catalogued generation, at its resume offset", function()
    local seen = {}
    for _, name in ipairs(fixtures()) do
      local text = launcher.normalize(read(FIX .. name))
      local g = launcher.GENERATIONS.cmd[vim.fn.sha256(text)]
      assert.truthy(g, name)
      assert.equals(tonumber(name:match("%d+")), g.gen, name)
      assert.equals(g.resume, resume_of((text:gsub("\n", "\r\n"))), name)
      seen[g.gen] = true
    end
    for hash, g in pairs(launcher.GENERATIONS.cmd) do assert.truthy(seen[g.gen], hash) end
  end)

  -- Each generation's own lw.cmd run by a real cmd.exe, with a pinned "lw"
  -- (a copy of cmd.exe, verified against lw.pin as a real one is) that writes
  -- the current template over the running file and exits 7: nothing is
  -- downloaded, and what cmd reads after lw is exactly what a real
  -- `.\lw.cmd bootstrap install` / `upgrade` leaves it.
  local windows = uv.os_uname().sysname:find("Windows") ~= nil
  local real = windows and it or pending
  real("every generation, rewritten by lw while it runs, exits with lw's status and prints nothing", function()
    local sysroot = os.getenv("SystemRoot") or "C:/Windows"
    local cmdexe = sysroot .. "/System32/cmd.exe"
    local fake = read(cmdexe)
    local sha = vim.fn.sha256(fake)
    local new = launcher.render("cmd")
    local cases = fixtures()
    cases[#cases + 1] = "current"
    for _, name in ipairs(cases) do
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/.nvim/cache", "p")
      local old = name == "current" and new or (launcher.normalize(read(FIX .. name)):gsub("\n", "\r\n"))
      write(dir .. "/lw.cmd", old)
      write(dir .. "/next.cmd", new)
      write(dir .. "/rewrite.cmd", "@copy /y next.cmd lw.cmd >nul\r\n@exit 7\r\n")
      -- a 0.1 pin: every generation caches it in .nvim\cache
      write(dir .. "/lw.pin", "version=0.1.51\nsha256_lw-windows-x86_64.exe=" .. sha .. "\n")
      write(dir .. "/.nvim/cache/lw-0.1.51-lw-windows-x86_64.exe", fake)
      -- as a user runs it (.\lw.cmd), with only the system directories on PATH
      local r = vim.system({ cmdexe, "/d", "/c", ".\\lw.cmd", "/d", "/c", ".\\rewrite.cmd" }, {
        text = true, cwd = dir, timeout = 60000,
        env = { LOOMWORKS_LW = "", LOOMWORKS_RELEASE_URL = "",
          PATH = sysroot .. "\\System32;" .. sysroot },
      }):wait()
      local out = (r.stdout or "") .. (r.stderr or "")
      assert.equals(7, r.code, name .. ": " .. out)
      assert.equals("", out, name)
      assert.equals(new, read(dir .. "/lw.cmd"), name)
      vim.fn.delete(dir, "rf")
    end
  end)

  -- A real cmd.exe run: the template's own tail, with a pinned "lw" that
  -- replaces the running file with a longer one and exits 7.
  local windows = uv.os_uname().sysname:find("Windows") ~= nil
  local real = windows and it or pending
  real("a real cmd.exe survives the rewrite and keeps lw's exit status", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local text = launcher.normalize(launcher.LW_CMD)
    local tail = text:sub((text:find('"%PINBIN%"', 1, true)))
    local function batch(run_tail, pad)
      local t = { "@echo off", "setlocal EnableExtensions EnableDelayedExpansion" }
      for i = 1, pad do t[#t + 1] = "rem padding " .. i .. " " .. string.rep("x", 60) end
      t[#t + 1] = 'set "PINBIN=%SystemRoot%\\System32\\cmd.exe"'
      t[#t + 1] = "setlocal DisableDelayedExpansion"
      -- (the carets keep `>` and `&` for the child: %fwd% expands before parsing)
      t[#t + 1] = 'set "fwd= /d /c copy /y "%~dp0next.cmd" "%~f0" ^>nul ^& exit 7"'
      return (table.concat(t, "\n") .. "\n" .. run_tail):gsub("\n", "\r\n")
    end
    local function run(run_tail)
      local fh = assert(io.open(dir .. "/lw.cmd", "wb")); fh:write(batch(run_tail, 2)); fh:close()
      fh = assert(io.open(dir .. "/next.cmd", "wb")); fh:write(batch(tail, 40)); fh:close()
      local r = vim.system({ "cmd.exe", "/d", "/c", dir .. "\\lw.cmd" }, { text = true, cwd = dir }):wait()
      return r.code, (r.stdout or "") .. (r.stderr or "")
    end
    local code, out = run(tail)
    assert.equals(7, code, out)
    assert.equals("", out)
    -- the harness reproduces the bug with the old two-line run
    -- (its exit status then depends on what cmd reads at the old offset)
    local _, old_out = run((tail:gsub(vim.pesc(RUN_LINE), (OLD_RUN:gsub("%%", "%%%%")))))
    assert.truthy(old_out:find("is not recognized", 1, true), old_out)
    vim.fn.delete(dir, "rf")
  end)
end)
