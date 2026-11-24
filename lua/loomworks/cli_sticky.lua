--- loomworks/cli_sticky.lua — the live status line (spec §16.7) for `lw`
--- step commands: configure, build and clean steps of build, clean, test and
--- run, plus the start line of run's program.
---
--- While a step's tool runs, the terminal's last output row shows a status
--- line in reverse video (` BUILD  dev › app  step 2/3  [143/512]  0:41`).
--- The tool's output is piped through this module instead of being inherited:
--- before stream output is written the status row is cleared, the output is
--- written, the status line is redrawn — one write each time, so nothing
--- interleaves. When the step ends, the line's final form (✓/✗, duration) is
--- written into the stream and scrolls away with the output.
---
--- Known tool output feeds the line's progress (`classify`): ninja's `[n/m]`
--- (also under cmake --build and meson) and make's `[ 45%]`. Every line,
--- these included, passes through to the stream untouched (escape codes
--- included); ninja's lines arrive one per line, as ninja prints them on a
--- non-terminal. The line shows no tool text, only phase, step, progress and
--- elapsed times.
---
--- Off (and then nothing here runs: the child inherits the terminal exactly
--- as before) unless stdout and stderr are both terminals (on Windows with
--- VT processing enabled), TERM is not `dumb`, `--no-sticky` was not given
--- and LW_STICKY is not `0`. NO_COLOR / `--color=never`: reverse video only.

local uv = vim.uv or vim.loop

local M = {}

--- Set by the global option `--no-sticky`.
M.opt_out = false

-- Test seams.
M._isatty = nil   -- fun(fd): boolean
M._getenv = nil   -- fun(name): string|nil
M._enable_vt = nil -- fun(fd): boolean
M._write = nil    -- fun(s)
M._now = nil      -- fun(): number (ms)
M._width = nil    -- fun(): integer

local function getenv(name)
  if M._getenv then return M._getenv(name) end
  return os.getenv(name)
end

local function isatty(fd)
  if M._isatty then return M._isatty(fd) end
  local ok, h = pcall(uv.guess_handle, fd)
  return ok and h == "tty"
end

local function now_ms()
  if M._now then return M._now() end
  return uv.hrtime() / 1e6
end

--- Whether the sticky line may be drawn in this process.
--- @return boolean
function M.enabled()
  if M.opt_out then return false end
  if getenv("LW_STICKY") == "0" then return false end
  if getenv("TERM") == "dumb" then return false end
  if not (isatty(1) and isatty(2)) then return false end
  if package.config:sub(1, 1) == "\\" then
    local vt = M._enable_vt or require("loomworks.cli_color").enable_vt
    if not (vt(1) and vt(2)) then return false end
  end
  return true
end

--- Whether the line may use colour (else reverse video only).
function M.colored()
  local cc = require("loomworks.cli_color")
  if cc.mode == "always" then return true end
  if cc.mode == "never" then return false end
  local nc = getenv("NO_COLOR")
  return nc == nil or nc == ""
end

-- ---------------------------------------------------------------------------
-- Classifier (pure)
-- ---------------------------------------------------------------------------

local function strip_sgr(s)
  return (s:gsub("\27%[[%d;?]*[%a]", ""))
end

--- Classify one line of tool output (no trailing newline; a trailing CR and
--- escape codes are ignored for matching).
---   ninja: `{ tool = "ninja", current, total, message, pass = true }`
---   make:  `{ tool = "make", pct, message }`
---   cmake: `{ tool = "cmake", message }`
---   other: nil
--- @param line string
--- @return table|nil
function M.classify(line)
  local s = strip_sgr(line):gsub("\r+$", "")
  local cur, tot, msg = s:match("^%[(%d+)/(%d+)%]%s*(.*)$")
  if cur then
    -- Same basename compaction the daemon's progress parser applies.
    local p = require("loomworks.progress.ninja")(s)
    return { tool = "ninja", current = tonumber(cur), total = tonumber(tot),
      message = p and p.message or msg, pass = true }
  end
  local pct, rest = s:match("^%[%s*(%d+)%%%]%s*(.*)$")
  if pct then return { tool = "make", pct = tonumber(pct), message = rest } end
  local cm = s:match("^%-%- (.*)$")
  if cm then return { tool = "cmake", message = cm } end
  return nil
end

-- ---------------------------------------------------------------------------
-- Formatter (pure)
-- ---------------------------------------------------------------------------

--- Display width in columns (one per UTF-8 code point; no wide-glyph table).
local function cols(s)
  return #(s:gsub("[\128-\191]", ""))
end
M._cols = cols

--- `s` cut to `w` columns, with `…` when it is cut.
local function ellipsize(s, w)
  if cols(s) <= w then return s end
  if w <= 0 then return "" end
  if w == 1 then return "…" end
  local out, n = {}, 0
  for ch in s:gmatch("[%z\1-\127\192-\247][\128-\191]*") do
    if n >= w - 1 then break end
    out[#out + 1] = ch
    n = n + 1
  end
  return table.concat(out) .. "…"
end
M._ellipsize = ellipsize

--- `m:ss`, or `h:mm:ss` from an hour.
--- @param ms number
--- @return string
function M.duration(ms)
  local s = math.max(0, math.floor((ms or 0) / 1000))
  local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s % 60) end
  return string.format("%d:%02d", m, s % 60)
end

local function clean(s)
  return (strip_sgr(tostring(s or "")):gsub("[%z\1-\31\127]", ""))
end

local KIND_SGR = { configure = "33", build = "36", clean = "34", test = "35" }

--- The status line for `st` within `width` columns.
--- `st`: { kind, profile?, name?, index?, count?, current?, total?, pct?,
---   elapsed_ms, total_ms? }. `opts.final`: nil while live, true (ok) or
--- false (failed) for the line written into the stream. `opts.start`: the
--- phase-start line that replaces the step's `==> [kind] name` header while
--- the sticky line is on (` ▶ BUILD  dev › app  step 2/3 `: badge, where,
--- `step i/n`; in the kind's colour, not padded), so start and end lines
--- bracket the step's output.
--- Fields, left to right: badge, `profile › name`, `step i/n`, progress,
--- elapsed, `(total …)`. When too wide: `(total)`, `step i/n`, elapsed and
--- progress are dropped in that order; then the name is ellipsized. At most `width - 1` columns, so the row never wraps.
--- Returns the styled line and its plain text.
--- @return string styled, string plain
function M.format(st, width, opts)
  opts = opts or {}
  local final = opts.final
  local start = opts.start
  local color = opts.color
  local max = math.max(1, (width or 80) - 1)
  local kind = tostring(st.kind or "step")
  local badge = kind:upper()
  if start then badge = "▶ " .. badge
  elseif final == true then badge = "✓ " .. badge elseif final == false then badge = "✗ " .. badge end
  badge = " " .. badge .. " "

  local where = clean(st.name or "?")
  if st.profile then where = clean(st.profile) .. " › " .. where end
  local progress
  if start then progress = nil
  elseif st.current and st.total then progress = string.format("[%d/%d]", st.current, st.total)
  elseif st.pct then progress = string.format("[%3d%%]", st.pct) end
  -- drop: drop order (lower drops first; 99 = never, ellipsized instead).
  local fields = {
    { key = "where", text = where, drop = 99 },
    { key = "step", text = (not final and st.index and st.count and st.count > 1)
      and string.format("step %d/%d", st.index, st.count) or nil, drop = 3 },
    { key = "progress", text = progress, drop = 6 },
    { key = "elapsed", text = not start and M.duration(st.elapsed_ms) or nil, drop = 5 },
    { key = "total", text = (not final and not start and st.total_ms and st.index and st.index > 1)
      and "(total " .. M.duration(st.total_ms) .. ")" or nil, drop = 2 },
  }
  local live = {}
  for _, f in ipairs(fields) do if f.text then live[#live + 1] = f end end
  local function rest_text()
    local parts = {}
    for _, f in ipairs(live) do parts[#parts + 1] = f.text end
    return " " .. table.concat(parts, "  ") .. " "
  end
  local function over() return cols(badge) + cols(rest_text()) - max end
  while over() > 0 do
    local victim, vi
    for i, f in ipairs(live) do
      if f.drop < 99 and (not victim or f.drop < victim.drop) then victim, vi = f, i end
    end
    if victim then
      table.remove(live, vi)
    else
      -- Only the name is left: ellipsize it, then the badge.
      local w = live[1]
      local room = max - cols(badge) - 2
      if w and room >= 2 then
        w.text = ellipsize(w.text, room)
      else
        live = {}
        badge = ellipsize(badge, max)
      end
      break
    end
  end
  local rest = #live > 0 and rest_text() or ""
  local plain = badge .. rest
  if final == nil and not start then
    -- Live: pad to the full row so it reads as a bar.
    rest = rest .. string.rep(" ", math.max(0, max - cols(plain)))
  end
  local hue = final == true and "32" or final == false and "31" or KIND_SGR[kind] or "36"
  local styled
  if color then
    styled = "\27[0;1;7;" .. hue .. "m" .. badge .. "\27[0;7m" .. rest .. "\27[0m"
  else
    styled = "\27[0;1;7m" .. badge .. "\27[0;7m" .. rest .. "\27[0m"
  end
  return styled, plain
end

-- ---------------------------------------------------------------------------
-- Renderer
-- ---------------------------------------------------------------------------

local CLEAR = "\r\27[2K"
local HIDE, SHOW = "\27[?25l", "\27[?25h"
M.REDRAW_MS = 100   -- at most 10 redraws/s for progress alone
M.PARTIAL_MS = 100  -- a partial line older than this is written out

local function default_write(s)
  pcall(function() io.stdout:flush(); io.stderr:flush() end)
  local pos = 1
  while pos <= #s do
    local ok, n = pcall(uv.fs_write, 1, s:sub(pos))
    if not ok or type(n) ~= "number" or n <= 0 then
      io.stdout:write(s:sub(pos)); io.stdout:flush()
      return
    end
    pos = pos + n
  end
end

local function write(s)
  if s == "" then return end
  if M._write then return M._write(s) end
  default_write(s)
end

local tty_handle
local function width()
  if M._width then return M._width() end
  local w
  pcall(function()
    tty_handle = tty_handle or uv.new_tty(1, false)
    w = tty_handle:get_winsize()
  end)
  if type(w) == "number" and w > 0 then return math.floor(w) end
  return tonumber(os.getenv("COLUMNS")) or 100
end

--- Write the phase-start line (`format`'s `opts.start`) in place of a step's
--- `==> [kind] name` header, on a fresh row of stdout.
--- @param info { kind: string, name?: string, profile?: string, index?: integer, count?: integer }
function M.write_start(info)
  local line = M.format({ kind = info.kind, name = info.name, profile = info.profile,
    index = info.index, count = info.count }, width(), { color = M.colored(), start = true })
  write(CLEAR .. line .. "\n")
end

--- The session currently on screen (one at a time), for `teardown`.
M._active = nil

local Session = {}
Session.__index = Session

--- Start a sticky line for one step.
--- @param info { kind: string, name?: string, profile?: string, index?: integer,
---   count?: integer, run_start_ms?: number }
function M.start(info)
  if M._active then M._active:abort() end
  local t = now_ms()
  local self = setmetatable({
    st = { kind = info.kind, name = info.name, profile = info.profile,
      index = info.index, count = info.count, elapsed_ms = 0 },
    t0 = t, run_t0 = info.run_start_ms or t,
    color = M.colored(),
    partial = "",       -- bytes of an incomplete line not yet written
    partial_t = nil,    -- when it began
    midline = false,    -- a partial line was written: the cursor is mid-line
    dirty = true, last_draw = -math.huge, last_sec = -1,
  }, Session)
  M._active = self
  write(HIDE)
  self:_draw()
  if not M._write then
    self.timer = uv.new_timer()
    self.timer:start(M.REDRAW_MS, M.REDRAW_MS, function() pcall(self.tick, self) end)
  end
  return self
end

function Session:_line()
  local t = now_ms()
  self.st.elapsed_ms = t - self.t0
  self.st.total_ms = t - self.run_t0
  return (M.format(self.st, width(), { color = self.color }))
end

function Session:_draw(prefix)
  local s = (prefix or "")
  if self.midline then
    write(s)
    return
  end
  write(CLEAR .. s .. self:_line() .. "\r")
  self.dirty = false
  self.last_draw = now_ms()
  self.last_sec = math.floor(self.st.elapsed_ms / 1000)
end

--- Periodic tick: write out a stale partial line, redraw for a new second or
--- throttled progress.
function Session:tick()
  local t = now_ms()
  if self.partial ~= "" and self.partial_t and t - self.partial_t >= M.PARTIAL_MS then
    local p = self.partial
    self.partial, self.partial_t = "", nil
    local pre = self.midline and "" or CLEAR
    write(pre .. p)
    self.midline = true
    return
  end
  if self.midline then return end
  local sec = math.floor((t - self.t0) / 1000)
  if sec ~= self.last_sec or (self.dirty and t - self.last_draw >= M.REDRAW_MS) then
    self:_draw()
  end
end

--- Feed a chunk of the tool's output.
--- @param data string
function Session:feed(data)
  if not data or data == "" then return end
  local buf = self.partial .. data
  local outbuf = {}
  local pos = 1
  while true do
    local nl = buf:find("\n", pos, true)
    if not nl then break end
    local raw = buf:sub(pos, nl)
    pos = nl + 1
    if self.midline then
      -- The line's start is already on screen: finish it as is.
      outbuf[#outbuf + 1] = raw
      self.midline = false
      -- Redraw below it.
      write(table.concat(outbuf)); outbuf = {}
    else
      outbuf[#outbuf + 1] = raw
      local c = M.classify(raw:sub(1, -2))
      if c and c.tool == "ninja" then
        self.st.current, self.st.total, self.st.pct = c.current, c.total, nil
        self.dirty = true
      elseif c and c.tool == "make" then
        self.st.pct, self.st.current, self.st.total = c.pct, nil, nil
        self.dirty = true
      end
    end
  end
  self.partial = buf:sub(pos)
  if self.partial ~= "" then
    self.partial_t = self.partial_t or now_ms()
    if self.midline then
      -- Continuing a line already on screen: pass it on now.
      outbuf[#outbuf + 1] = self.partial
      self.partial, self.partial_t = "", nil
    end
  else
    self.partial_t = nil
  end
  local out = table.concat(outbuf)
  if out ~= "" then
    if self.midline then write(out) else self:_draw(out) end
  elseif self.dirty and now_ms() - self.last_draw >= M.REDRAW_MS then
    self:_draw()
  end
end

function Session:_stop_timer()
  if self.timer then
    pcall(function() self.timer:stop(); self.timer:close() end)
    self.timer = nil
  end
end

--- End the step: write out what is pending, then the final line into the
--- stream (it scrolls up with the output).
--- @param ok boolean
function Session:finish(ok)
  self:_stop_timer()
  local tail = self.partial
  self.partial = ""
  local pre = self.midline and "" or CLEAR
  local nl = (tail ~= "" or self.midline) and "\n" or ""
  self.midline = false
  self.st.elapsed_ms = now_ms() - self.t0
  local line = M.format(self.st, width(), { color = self.color, final = ok and true or false })
  write(pre .. tail .. nl .. CLEAR .. line .. "\n" .. SHOW)
  if M._active == self then M._active = nil end
end

--- Take the line off the screen so the caller can write its own lines (at
--- column 0 of a fresh row); `redraw` puts it back.
function Session:hide()
  local tail = self.partial
  self.partial, self.partial_t = "", nil
  local nl = (tail ~= "" or self.midline) and "\n" or ""
  write((self.midline and "" or CLEAR) .. tail .. nl)
  self.midline = false
end

function Session:redraw() self:_draw() end

--- Remove the line without a final line (exit, interrupt, error).
function Session:abort()
  self:_stop_timer()
  local tail = self.partial
  self.partial = ""
  write((self.midline and "" or CLEAR) .. tail .. (tail ~= "" and "\n" or "") .. "\27[0m" .. SHOW)
  self.midline = false
  if M._active == self then M._active = nil end
end

--- Restore the terminal if a line is on screen (an exit hook).
function M.teardown()
  if M._active then pcall(M._active.abort, M._active) end
  if tty_handle then pcall(function() tty_handle:close() end); tty_handle = nil end
end

return M
