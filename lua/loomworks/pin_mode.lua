--- loomworks/pin_mode.lua — `lw pin [ignore|follow]` (headless §16.24 "Pin
--- mode: `lw pin`", §16.23 "Ignored pin").
---
--- Reports and switches whether this checkout follows its pin: `.lw/local`
--- (`pin = ignore`, formats §11) at the pin root makes every command run as
--- the invoked lw; its absence means follow. A management operation: it never
--- redirects, loads no workspace and launches no daemon. A switch that changes
--- the effective build of workspace operations retires a workspace daemon of
--- the previous build (daemon §19.9 "Pin mode switch"): an idle one is
--- stopped, a busy one is sent `retire`, over the frozen control subset.

local M = {}

local function uv() return vim.uv or vim.loop end

--- The bound of each request to the workspace daemon.
M.STEP_MS = 2000

--- The running lw: its executable and the version it reports.
--- @return string|nil exe, string|nil version
function M.running()
    local okx, exe = pcall(uv().exepath)
    local okv, v = pcall(function()
        return require("loomworks.save_guard").version() or require("loomworks.daemon.version").identity()
    end)
    return okx and exe and (exe:gsub("\\", "/")) or nil, okv and v or nil
end

--- The release this lw is (nil for a development build).
local function own_release()
    local code = rawget(_G, "__loomworks_code")
    return type(code) == "table" and type(code.version) == "string" and code.version or nil
end

--- The identity of the build that runs workspace operations: the pinned
--- release when following (unless it is this lw's own release), this lw when
--- ignoring. Returns the identity the daemon reports (`lw_version`) and the
--- text to show.
--- @param mode "ignore"|"follow"
--- @param pinned string|nil the pinned version
--- @return string identity, string display
function M.effective(mode, pinned)
    local own = require("loomworks.daemon.version").identity()
    local _, shown = M.running()
    if mode == "ignore" or not pinned or pinned == own_release() then
        return own, shown or own
    end
    return pinned, pinned
end

--- The switch (daemon §19.9 "Pin mode switch"): a workspace daemon of
--- another identity than `identity` is stopped when idle and sent `retire`
--- when busy; nothing else is touched and nothing is launched. Returns the
--- one line to print, or nil when nothing was done.
--- @param root string the workspace root
--- @param identity string the new effective identity
--- @param shown string how to name it
--- @param opts? { state?: fun(root: string): table, query?: fun(st: table): table|nil, string|nil, table|nil, request?: fun(st: table, kind: string): any, stop?: fun(root: string, host: table, o: table): integer }
--- @return string|nil
function M.switch(root, identity, shown, opts)
    opts = opts or {}
    local command = require("loomworks.daemon.command")
    local state = opts.state or require("loomworks.daemon.inspect").state
    local query = opts.query or function(st) return command.query(st, M.STEP_MS) end
    local request = opts.request or function(st, kind) return command.request(st, kind, M.STEP_MS) end
    local stop = opts.stop or command.stop
    local st = state(root)
    local lk = st.lock or {}
    if st.kind == "starting" or st.kind == "hung" then
        return string.format("lw: the workspace daemon (pid %s) does not answer - left as it is; "
            .. "stop it with `lw daemon stop`", tostring(lk.pid))
    end
    if st.kind ~= "live" then return nil end
    local reply, err, info = query(st)
    if type(reply) ~= "table" then
        return string.format("lw: the workspace daemon (pid %s) does not answer (%s) - left as it is; "
            .. "stop it with `lw daemon stop`", tostring(lk.pid), tostring(err))
    end
    local dv = reply.lw_version or (type(info) == "table" and info.lw_version) or nil
    if dv == identity then return nil end
    local name = "the workspace daemon (lw " .. tostring(dv or "?") .. ")"
    if require("loomworks.daemon.protocol").status_busy(reply) then
        request(st, "retire")
        return "lw: " .. name .. " is busy - it restarts as lw " .. tostring(shown) .. " when idle"
    end
    local failed
    local host = {
        out = function() end,
        die = function(msg) failed = tostring(msg); error(failed, 0) end,
    }
    local ok, perr = pcall(stop, root, host, {})
    if not ok then
        return "lw: could not stop " .. name .. ": " .. tostring(failed or perr) .. " - stop it with `lw daemon stop`"
    end
    return "lw: stopped " .. name .. "; the next command starts lw " .. tostring(shown)
end

--- Write `<pin root>/.lw/local` atomically (a temporary file in `.lw/` renamed
--- over it), creating `.lw/` and its self-ignore file.
--- @param pin_root string
--- @return boolean|nil ok, string|nil err
function M.write_local(pin_root)
    local dir, derr = require("loomworks.state_dir").ensure(pin_root)
    if not dir then return nil, derr end
    local path = pin_root .. "/" .. require("boot.pin").LOCAL_FILE
    local tmp = string.format("%s.%d.tmp", path, uv().os_getpid())
    local fd, oerr = uv().fs_open(tmp, "w", tonumber("644", 8))
    if not fd then return nil, "cannot write " .. tmp .. ": " .. tostring(oerr) end
    local wok = uv().fs_write(fd, require("boot.pin").LOCAL_IGNORE_TEXT, 0)
    uv().fs_close(fd)
    if not wok then pcall(uv().fs_unlink, tmp); return nil, "cannot write " .. tmp end
    local rok, rerr = uv().fs_rename(tmp, path)
    if not rok then pcall(uv().fs_unlink, tmp); return nil, "cannot write " .. path .. ": " .. tostring(rerr) end
    return true
end

--- `lw pin [ignore|follow]`.
--- @param args string[] the command's arguments (host flags peeled)
--- @param ctx { start: string, pin_root?: string, invoked?: string }
--- @param io_ { out: fun(line: string), err: fun(line: string) }
--- @return integer exit code
function M.run(args, ctx, io_)
    local pin = require("boot.pin")
    local check = require("boot.launcher_check")
    local invoked = ctx.invoked
    local function C(rest) return check.cmd(invoked, rest) end
    local o, perr = pin.parse_pin_args(args, { invoked = invoked })
    if not o then
        io_.err("lw: " .. perr)
        io_.err("    See `" .. C("help pin") .. "`.")
        return 2
    end
    local root = ctx.pin_root
    local p = root and pin.read(root)
    local exe, shown = M.running()
    local local_path = root and (root .. "/" .. pin.LOCAL_FILE)
    local mode = root and pin.read_local(root) or nil

    if o.sub == nil then
        if not root then
            io_.out("lw: no lw.pin here (searched up from " .. tostring(ctx.start) .. ") - this lw runs itself")
            return 0
        end
        io_.out("pin root  " .. root)
        io_.out("pinned    " .. (p and ("lw " .. p.version) or "lw.pin cannot be read"))
        if mode == "ignore" then
            io_.out("mode      ignore - this checkout runs " .. tostring(exe) .. " " .. tostring(shown)
                .. " (" .. C("pin follow") .. " follows the pin again)")
        else
            io_.out("mode      follow - workspace operations run the pinned lw ("
                .. C("pin ignore") .. " runs this lw here instead)")
        end
        return 0
    end

    if not root then
        if o.sub == "ignore" then
            io_.err("lw: no lw.pin here - nothing to ignore")
            return 1
        end
        io_.out("lw: no lw.pin here - nothing to follow")
        return 0
    end
    local pinned = p and p.version or nil
    local ws_root = root
    pcall(function() ws_root = require("loomworks.root_finder").find(ctx.start) or root end)
    local before = M.effective(mode == "ignore" and "ignore" or "follow", pinned)

    if o.sub == "ignore" then
        if not p then
            io_.err("lw: " .. root .. "/lw.pin cannot be read - nothing to ignore")
            return 1
        end
        local st = uv().fs_lstat(local_path)
        if st and st.type ~= "file" then
            io_.err("lw: " .. local_path .. " is not a regular file - not replaced; remove it by hand")
            return 1
        end
        if mode == "ignore" then
            io_.out("lw: pin already ignored here - this checkout runs " .. tostring(exe) .. " "
                .. tostring(shown) .. " (pinned " .. pinned .. "); " .. C("pin follow") .. " undoes it")
            return 0
        end
        local ok, werr = M.write_local(root)
        if not ok then
            io_.err("lw: " .. tostring(werr))
            return 1
        end
        io_.out("lw: pin ignored here - this checkout now runs " .. tostring(exe) .. " " .. tostring(shown)
            .. " (pinned " .. pinned .. "); " .. C("pin follow") .. " undoes it")
        local after, after_shown = M.effective("ignore", pinned)
        if after ~= before then
            local line = M.switch(ws_root, after, after_shown)
            if line then io_.out(line) end
        end
        return 0
    end

    -- follow
    local st = uv().fs_lstat(local_path)
    if not st then
        io_.out("lw: already following the pin (lw " .. tostring(pinned) .. ")")
        return 0
    end
    if st.type ~= "file" then
        io_.err("lw: " .. local_path .. " is not a regular file - not removed; remove it by hand")
        return 1
    end
    local ok, uerr = uv().fs_unlink(local_path)
    if not ok then
        io_.err("lw: cannot remove " .. local_path .. ": " .. tostring(uerr))
        return 1
    end
    local after, after_shown = M.effective("follow", pinned)
    io_.out("lw: following the pin again - workspace operations here run lw " .. tostring(after_shown)
        .. "; " .. C("pin ignore") .. " runs this lw instead")
    -- A move to an older lw: warned, never asked (§16.23 "Moving to an older lw").
    if mode == "ignore" and pinned and pin.older(pinned, shown) then
        io_.err(pin.older_lw_line(pinned, shown, pin.working_copy_rel(pinned), invoked))
    end
    if after ~= before then
        local line = M.switch(ws_root, after, after_shown)
        if line then io_.out(line) end
    end
    return 0
end

return M
