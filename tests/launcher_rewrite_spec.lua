--- Tests for lw.cmd being rewritten while it runs (spec headless §16.22
--- *Rewritten while it runs*, §16.24 *Install*): `.\lw.cmd bootstrap install`
--- rewrites the lw.cmd that cmd.exe is executing; cmd reads the next line at
--- its old byte offset once lw exits. The current template runs lw and exits
--- on one line (the note on replacing an older one: tests/standalone/main.lua).

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

  it("catalogues the 0.2.0-beta.7..beta.16 lw.cmd as a generation not safe to rewrite", function()
    local cur = vim.fn.sha256(launcher.normalize(launcher.LW_CMD))
    assert.is_nil(launcher.GENERATIONS.cmd[cur])
    local g = launcher.GENERATIONS.cmd[BETA16]
    assert.truthy(g)
    assert.equals(10, g.gen)
    assert.is_true(g.gen < launcher.CMD_REWRITE_SAFE_GEN)
    for hash, gg in pairs(launcher.GENERATIONS.cmd) do
      assert.is_true(gg.gen < launcher.CMD_REWRITE_SAFE_GEN, hash)
      local found = false
      for _, d in ipairs(gg.defects) do
        if d.text:find("rewrites it during its own run", 1, true) then
          found = true
          assert.equals("minor", d.severity)
        end
      end
      assert.is_true(found, hash)
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
