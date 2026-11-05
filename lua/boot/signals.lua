-- Process-wide signal dispositions every lw process sets first (main.lua).
--
-- SIGPIPE: a write to a socket or pipe whose peer has closed raises it, and
-- its default action ends the process. The workspace daemon writes to clients
-- that may go away at any moment, the relay to an editor's pipe, the CLI to a
-- pipeline's reader: each must see that write fail with EPIPE and treat it as
-- a disconnect, never die mid-write (losing its log line, its cleanup and,
-- for the daemon, the steps it runs). libuv sets SO_NOSIGPIPE on macOS
-- sockets, and Windows has no SIGPIPE, so in practice this is Linux.
--
-- A no-op handler, not SIG_IGN: exec resets a caught signal to its default,
-- and libuv resets every disposition in the children it spawns, so user tasks
-- and build steps still get the default SIGPIPE behaviour.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end

local M = {}

local sigpipe_handle

--- Catch SIGPIPE with a no-op handler (unref'd: it never keeps the loop
--- alive). Idempotent; a no-op where the signal does not exist (Windows).
--- Returns true when the handler is installed.
--- @param opts? { new_signal?: fun(): table }
--- @return boolean
function M.catch_sigpipe(opts)
  if sigpipe_handle then return true end
  if package.config:sub(1, 1) == "\\" then return false end
  local new_signal = (opts and opts.new_signal) or uv.new_signal
  local ok = pcall(function()
    local h = new_signal()
    if not h then error("no signal handle") end
    local started, err = h:start("sigpipe", function() end)
    if not started then
      pcall(function() h:close() end)
      error(tostring(err))
    end
    h:unref()
    sigpipe_handle = h
  end)
  return ok and sigpipe_handle ~= nil
end

return M
