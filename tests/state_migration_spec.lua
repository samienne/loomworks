--- Tests for the `.nvim/` -> `.lw/` state move (spec headless §16.44,
--- formats §10): the self-ignore file, the copy-only, crash-safe migration
--- of the working copy and its marker, the refusal while an older lw holds a
--- legacy lock, and the health report when an older lw edits `.nvim/`
--- afterwards.

local uv = vim.uv or vim.loop
local state_dir = require("loomworks.state_dir")
local sm = require("loomworks.state_migration")
local lock_record = require("loomworks.lock_record")

local function read(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

local function write(p, s)
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    local f = assert(io.open(p, "wb")); f:write(s); f:close()
end

local function exists(p) return uv.fs_lstat(p) ~= nil end

local function ls(dir)
    local out = {}
    local h = uv.fs_scandir(dir)
    while h do
        local n = uv.fs_scandir_next(h)
        if not n then break end
        out[#out + 1] = n
    end
    table.sort(out)
    return out
end

--- A snapshot of every file under `dir` (relative path -> bytes).
local function snapshot(dir)
    local out = {}
    local function walk(d, rel)
        for _, n in ipairs(ls(d)) do
            local p, r = d .. "/" .. n, rel == "" and n or (rel .. "/" .. n)
            local st = uv.fs_lstat(p)
            if st.type == "directory" then walk(p, r) else out[r] = read(p) end
        end
    end
    walk(dir, "")
    return out
end

local LEGACY_BYTES = '{"_meta":{"version":2},"profiles":{"x":1},"_sig":"abc"}\n'

local tmp_root
local function new_root()
    tmp_root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(tmp_root, "p")
    return tmp_root
end

local function legacy_root()
    local r = new_root()
    write(r .. "/.nvim/loomworks.user.json", LEGACY_BYTES)
    write(r .. "/.nvim/loomworks.cache.json", "{}")
    write(r .. "/.nvim/build/app/Debug/CMakeCache.txt", "x")
    write(r .. "/.nvim/cache/lw-0.1.43-lw-linux-x86_64", "bin")
    return r
end

local function cleanup()
    if tmp_root then vim.fn.delete(tmp_root, "rf") end
    tmp_root = nil
end

describe("state_dir", function()
    after_each(cleanup)

    it("names the state directory .lw with unprefixed names", function()
        assert.equals("/r/.lw", state_dir.dir("/r"))
        assert.equals("/r/.lw/user.json", require("loomworks.user").filepath("/r"))
        assert.equals("/r/.lw/cache.json", require("loomworks.cache").filepath("/r"))
        assert.equals("/r/.lw/health.json", require("loomworks.health_cache").path("/r"))
        assert.equals("/r/.lw/op.lock", require("loomworks.op_lock").path("/r"))
    end)

    it("ensure creates .lw with a self-ignore file holding *", function()
        local r = new_root()
        assert.truthy(state_dir.ensure(r))
        local gi = read(r .. "/.lw/.gitignore")
        assert.truthy(gi)
        assert.truthy(gi:find("\n%*\n$"))
    end)

    it("never rewrites an existing .lw/.gitignore", function()
        local r = new_root()
        write(r .. "/.lw/.gitignore", "mine\n")
        assert.is_false(state_dir.ensure_ignore(r))
        assert.equals("mine\n", read(r .. "/.lw/.gitignore"))
    end)

    it("writes the self-ignore file when it finds .lw without one", function()
        local r = new_root()
        vim.fn.mkdir(r .. "/.lw", "p")
        assert.is_true(state_dir.ensure_ignore(r))
        assert.equals(state_dir.GITIGNORE, read(r .. "/.lw/.gitignore"))
    end)

    it("does not create the root", function()
        local r = new_root() .. "/missing"
        assert.is_nil(state_dir.ensure(r))
        assert.is_false(exists(r))
    end)
end)

describe("state migration", function()
    after_each(cleanup)

    it("a fresh repository: nothing to migrate, nothing created", function()
        local r = new_root()
        assert.is_false(sm.pending(r))
        assert.is_nil(sm.run(r))
        assert.is_false(exists(r .. "/.lw"))
    end)

    it("copies an existing .nvim working copy byte for byte, leaving .nvim as it was", function()
        local r = legacy_root()
        local before = snapshot(r .. "/.nvim")
        assert.is_true(sm.pending(r))
        local status, line = sm.run(r)
        assert.equals("migrated", status)
        assert.truthy(line:find(".lw/", 1, true))
        assert.equals(LEGACY_BYTES, read(r .. "/.lw/user.json"))
        assert.same(before, snapshot(r .. "/.nvim"))
        -- Only the working copy moves: no build cache, no build trees.
        assert.is_false(exists(r .. "/.lw/cache.json"))
        assert.is_false(exists(r .. "/.lw/build"))
        -- The marker records the copied bytes.
        local kind, m = sm.read_marker(r)
        assert.equals("file", kind)
        assert.equals(vim.fn.sha256(LEGACY_BYTES), m.source_sha256)
        assert.equals(".nvim/loomworks.user.json", m.from)
        assert.truthy(m.written_by and m.migrated_at)
        -- Self-ignore, no temporary copy left, no lock left.
        assert.equals(state_dir.GITIGNORE, read(r .. "/.lw/.gitignore"))
        for _, n in ipairs(ls(r .. "/.lw")) do
            assert.is_nil(n:match("%.migrate%-"), n)
            assert.is_nil(n:match("%.lock$"), n)
        end
        assert.is_false(exists(r .. "/.nvim/loomworks.op.lock"))
    end)

    it("rerun is idempotent", function()
        local r = legacy_root()
        assert.equals("migrated", (sm.run(r)))
        local after = snapshot(r)
        assert.is_false(sm.pending(r))
        assert.is_nil(sm.run(r))
        assert.same(after, snapshot(r))
    end)

    it("refuses while an older lw holds the legacy operation lock, naming it", function()
        local r = legacy_root()
        local rec = lock_record.new("build")
        rec.lock_nonce = "someone-else"
        write(r .. "/.nvim/loomworks.op.lock", vim.json.encode(rec))
        local status, msg = sm.run(r)
        assert.equals("refused", status)
        assert.truthy(msg:find("pid " .. tostring(rec.pid), 1, true), msg)
        assert.truthy(msg:find("stop it or let it finish, then retry", 1, true), msg)
        assert.is_false(exists(r .. "/.lw/user.json"))
        assert.is_false(exists(r .. "/.lw/migrated.json"))
        -- The older lw's lock is left as it was.
        assert.equals(vim.json.encode(rec), read(r .. "/.nvim/loomworks.op.lock"))
    end)

    it("refuses while an older lw's daemon holds a slot runtime lock", function()
        local r = legacy_root()
        local rec = lock_record.new("daemon")
        rec.kind = "daemon"
        write(r .. "/.nvim/loomworks.daemon-0123456789abcdef.lock", vim.json.encode(rec))
        local status, msg = sm.run(r)
        assert.equals("refused", status)
        assert.truthy(msg:find("daemon", 1, true), msg)
        assert.is_false(exists(r .. "/.lw/user.json"))
    end)

    it("a dead holder's legacy lock does not block, and is left in place", function()
        local r = legacy_root()
        local rec = lock_record.new("build")
        rec.pid, rec.start_time, rec.lock_nonce = 999999, "0", "dead"
        local body = vim.json.encode(rec)
        write(r .. "/.nvim/loomworks.op.lock", body)
        assert.equals("migrated", (sm.run(r)))
        assert.equals(body, read(r .. "/.nvim/loomworks.op.lock"))
    end)

    it("refuses an unfinished legacy commit, leaving it to the older lw", function()
        local r = legacy_root()
        write(r .. "/.nvim/loomworks.txn.json", "{}")
        local status, msg = sm.run(r)
        assert.equals("refused", status)
        assert.truthy(msg:find("loomworks.txn.json", 1, true), msg)
        assert.equals("{}", read(r .. "/.nvim/loomworks.txn.json"))
    end)

    it("a crash before the copy: a leftover temporary copy is removed by its exact name", function()
        local r = legacy_root()
        write(r .. "/.lw/user.json.migrate-0a1b2c", "partial")
        write(r .. "/.lw/user.json.migrate-notes", "user file") -- not hex: never touched
        assert.equals("migrated", (sm.run(r)))
        assert.is_false(exists(r .. "/.lw/user.json.migrate-0a1b2c"))
        assert.equals("user file", read(r .. "/.lw/user.json.migrate-notes"))
        assert.equals(LEGACY_BYTES, read(r .. "/.lw/user.json"))
    end)

    it("a crash between copy and marker: the next run writes the marker and finishes", function()
        local r = legacy_root()
        write(r .. "/.lw/user.json", LEGACY_BYTES) -- copied, marker absent
        assert.is_true(sm.pending(r))
        assert.equals("completed", (sm.run(r)))
        local _, m = sm.read_marker(r)
        assert.equals(vim.fn.sha256(LEGACY_BYTES), m.source_sha256)
        assert.is_nil(sm.divergence(r))
    end)

    it("a .lw/user.json without a marker that differs from .nvim: refused, saying what to do", function()
        local r = legacy_root()
        write(r .. "/.lw/user.json", "copied earlier") -- partial copy, or put there by hand
        local status, msg = sm.run(r)
        assert.equals("refused", status)
        assert.truthy(msg:find("differs from .nvim/loomworks.user.json", 1, true), msg)
        assert.truthy(msg:find("move .lw/user.json out of .lw/", 1, true), msg)
        assert.equals("copied earlier", read(r .. "/.lw/user.json"))
        assert.equals(LEGACY_BYTES, read(r .. "/.nvim/loomworks.user.json"))
        assert.is_false(exists(r .. "/.lw/migrated.json"))
        -- Moved out of the way as told: the next run copies anew.
        assert.is_true(uv.fs_rename(r .. "/.lw/user.json", r .. "/user.json.old"))
        assert.equals("migrated", (sm.run(r)))
        assert.equals(LEGACY_BYTES, read(r .. "/.lw/user.json"))
    end)

    it("without hard links the final name is created exclusively and verified", function()
        local r = legacy_root()
        local saved = uv.fs_link
        uv.fs_link = function(from, to, ...)
            if tostring(to):match("/%.lw/user%.json$") then
                return nil, "ENOTSUP: operation not supported", "ENOTSUP"
            end
            return saved(from, to, ...)
        end
        local ok, status = pcall(sm.run, r)
        uv.fs_link = saved
        assert.is_true(ok, tostring(status))
        assert.equals("migrated", status)
        assert.equals(LEGACY_BYTES, read(r .. "/.lw/user.json"))
        local _, m = sm.read_marker(r)
        assert.equals(vim.fn.sha256(LEGACY_BYTES), m.source_sha256)
        for _, n in ipairs(ls(r .. "/.lw")) do assert.is_nil(n:match(sm.TEMP_PATTERN), n) end
    end)

    it("a leftover temporary copy is removed on a later run after the migration too", function()
        local r = legacy_root()
        assert.equals("migrated", (sm.run(r)))
        write(r .. "/.lw/user.json.migrate-0a1b2c", "left by a failed unlink")
        write(r .. "/.lw/user.json.migrate-notes", "user file")
        sm.tidy(r)
        assert.is_false(exists(r .. "/.lw/user.json.migrate-0a1b2c"))
        assert.equals("user file", read(r .. "/.lw/user.json.migrate-notes"))
        assert.equals(LEGACY_BYTES, read(r .. "/.lw/user.json"))
    end)

    it("the legacy operation lock taken over by another process is not removed on release", function()
        local r = legacy_root()
        local other = lock_record.new("build")
        other.lock_nonce = "another-process"
        local body = vim.json.encode(other)
        local saved = uv.fs_link
        uv.fs_link = function(from, to, ...)
            -- (the copy's link: between taking the legacy lock and releasing it)
            if tostring(to):match("/%.lw/user%.json$") then
                local f = assert(io.open(r .. "/.nvim/loomworks.op.lock", "wb")); f:write(body); f:close()
            end
            return saved(from, to, ...)
        end
        local ok, status = pcall(sm.run, r)
        uv.fs_link = saved
        assert.is_true(ok, tostring(status))
        assert.equals("migrated", status)
        assert.equals(body, read(r .. "/.nvim/loomworks.op.lock"))
    end)

    it(".lw that is a file, or a link or junction, is refused and nothing is written through it", function()
        local r = legacy_root()
        write(r .. "/.lw", "a file")
        local status, msg = sm.run(r)
        assert.equals("refused", status)
        assert.truthy(msg:find(".lw", 1, true), msg)
        assert.equals("a file", read(r .. "/.lw"))
        assert.is_false(exists(r .. "/.lw/migrated.json"))
        uv.fs_unlink(r .. "/.lw")

        local target = r .. "/elsewhere"
        vim.fn.mkdir(target, "p")
        local linked = uv.fs_symlink(target, r .. "/.lw", { dir = true, junction = true })
        if not linked then return end -- (no links on this system)
        local ok2, status2, msg2 = pcall(sm.run, r)
        pcall(uv.fs_unlink, r .. "/.lw")
        pcall(uv.fs_rmdir, r .. "/.lw")
        assert.is_true(ok2, tostring(status2))
        assert.equals("refused", status2)
        assert.truthy(msg2:find("not a real directory", 1, true), msg2)
        assert.same({}, ls(target))
    end)

    it("lw init in a workspace not yet migrated copies the old working copy, never drops it", function()
        local r = legacy_root()
        local ok, err = require("loomworks.workspace").init_workspace(r)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("already exists", 1, true), err)
        assert.equals(LEGACY_BYTES, read(r .. "/.lw/user.json"))
        assert.equals("file", (sm.read_marker(r)))
        -- An older lw at work: init refuses with the migration's message.
        local r2 = legacy_root()
        local rec = lock_record.new("build")
        rec.lock_nonce = "someone-else"
        write(r2 .. "/.nvim/loomworks.op.lock", vim.json.encode(rec))
        local ok2, err2 = require("loomworks.workspace").init_workspace(r2)
        vim.fn.delete(r, "rf")
        assert.is_false(ok2)
        assert.truthy(tostring(err2):find("stop it or let it finish, then retry", 1, true), err2)
        assert.is_false(exists(r2 .. "/.lw/user.json"))
    end)

    it("a marker that is not a regular file stops the command, saying what to do", function()
        local r = legacy_root()
        vim.fn.mkdir(r .. "/.lw/migrated.json", "p")
        local status, msg = sm.run(r)
        assert.equals("refused", status)
        assert.truthy(msg:find("remove it, then retry", 1, true), msg)
        assert.is_false(exists(r .. "/.lw/user.json"))
    end)

    it("an older pin editing .nvim afterwards: health reports it, lw keeps .lw", function()
        local r = legacy_root()
        assert.equals("migrated", (sm.run(r)))
        assert.is_nil(sm.divergence(r))
        write(r .. "/.nvim/loomworks.user.json", LEGACY_BYTES .. " ")
        local msg = sm.divergence(r)
        assert.truthy(msg and msg:find(".nvim/loomworks.user.json changed after it was copied", 1, true))
        -- Never migrated again: .lw/user.json stays.
        assert.is_nil(sm.run(r))
        assert.equals(LEGACY_BYTES, read(r .. "/.lw/user.json"))
        local items = require("loomworks.suggestions").legacy_state_provider({ root = r })
        local kinds = {}
        for _, it in ipairs(items) do kinds[it.kind] = it.title end
        assert.truthy(kinds.suggestion and kinds.suggestion:find("changed after it was copied", 1, true))
        -- the legacy build trees: informational
        assert.truthy(kinds.info and kinds.info:find(".nvim/build/", 1, true))
    end)

    it("a source checkout not yet migrated is read from .nvim without migrating it", function()
        local r = legacy_root()
        local user = require("loomworks.user")
        assert.equals(r .. "/.nvim/loomworks.user.json", user.source_filepath(r))
        assert.is_false(exists(r .. "/.lw"))
        sm.run(r)
        assert.equals(r .. "/.lw/user.json", user.source_filepath(r))
    end)

    it("the root finder recognizes a workspace of an earlier release", function()
        local r = legacy_root()
        vim.fn.mkdir(r .. "/sub", "p")
        assert.equals(r, (require("loomworks.root_finder").find(r .. "/sub")))
    end)
end)

describe("state migration through lw (Core:setup)", function()
    _G.LOOMWORKS_CLI_NO_AUTORUN = true
    local cli = require("loomworks.cli")

    local function run(root, ...)
        local out_buf = {}
        local rw, rs, rex = io.write, io.stderr, os.exit
        local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
        _G.arg, vim.env.LW_ROOT = { ... }, root
        io.write = function(s) out_buf[#out_buf + 1] = s end
        io.stderr = { write = function(_, s) out_buf[#out_buf + 1] = s end }
        local code
        os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
        local ok, err = pcall(cli.main)
        io.write, io.stderr, os.exit = rw, rs, rex
        _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
        if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
        return code or 0, table.concat(out_buf)
    end

    --- A workspace as a release before 0.2.0 left it: its working copy in
    --- `.nvim/loomworks.user.json`, nothing in `.lw/`.
    local function legacy_workspace()
        local r = new_root()
        vim.fn.mkdir(r .. "/app", "p")
        write(r .. "/app/tsconfig.json", "{}")
        assert.equals(0, (run(r, "init")))
        assert.equals(0, (run(r, "project", "add", "app")))
        local bytes = read(r .. "/.lw/user.json")
        write(r .. "/.nvim/loomworks.user.json", bytes)
        vim.fn.delete(r .. "/.lw", "rf")
        return r, bytes
    end

    after_each(cleanup)

    it("the first command copies the working copy and reports it once", function()
        local r, bytes = legacy_workspace()
        local code, out = run(r, "project", "list")
        assert.equals(0, code, out)
        assert.truthy(out:find("state is now in .lw/", 1, true), out)
        assert.truthy(out:find("app", 1, true), out)
        assert.equals(bytes, read(r .. "/.lw/user.json"))
        assert.equals(bytes, read(r .. "/.nvim/loomworks.user.json"))
        assert.equals("file", (sm.read_marker(r)))
        local code2, out2 = run(r, "project", "list")
        assert.equals(0, code2, out2)
        assert.is_nil(out2:find("state is now in .lw/", 1, true), out2)
    end)

    it("an older lw at work: the command fails, saying to stop it and retry", function()
        local r = legacy_workspace()
        local rec = lock_record.new("build")
        rec.lock_nonce = "older"
        write(r .. "/.nvim/loomworks.op.lock", vim.json.encode(rec))
        local code, out = run(r, "project", "list")
        assert.are_not.equal(0, code)
        assert.truthy(out:find("stop it or let it finish, then retry", 1, true), out)
        assert.is_false(exists(r .. "/.lw/user.json"))
    end)

    it("a pin older than .lw/ (set by the host): no migration, nothing created, the command refused", function()
        local r, bytes = legacy_workspace()
        local msg = "lw: this repo pins lw 0.1.51, which keeps its state in .nvim/; LEGACY-PIN-TEST"
        _G.__loomworks_legacy_pin = msg
        local ok_run, code, out = pcall(run, r, "project", "list")
        local code2, out2
        local ok_init, iok, ierr = pcall(require("loomworks.workspace").init_workspace, r)
        local empty = new_root()
        local ok_init2, iok2, ierr2 = pcall(require("loomworks.workspace").init_workspace, empty)
        _G.__loomworks_legacy_pin = nil
        assert.is_true(ok_run, code)
        assert.are_not.equal(0, code)
        assert.truthy(out:find("LEGACY-PIN-TEST", 1, true), out)
        assert.is_nil(out:find("state is now in .lw/", 1, true), out)
        assert.is_false(exists(r .. "/.lw"))
        assert.equals(bytes, read(r .. "/.nvim/loomworks.user.json"))
        assert.is_true(ok_init, iok)
        assert.is_false(iok)
        assert.truthy(tostring(ierr):find("LEGACY-PIN-TEST", 1, true), ierr)
        assert.is_false(exists(r .. "/.lw"))
        assert.is_true(ok_init2, iok2)
        assert.is_false(iok2)
        assert.truthy(tostring(ierr2):find("LEGACY-PIN-TEST", 1, true), ierr2)
        assert.is_false(exists(empty .. "/.lw"))
        -- Without the pin the same workspace migrates as usual.
        code2, out2 = run(r, "project", "list")
        assert.equals(0, code2, out2)
        assert.truthy(out2:find("state is now in .lw/", 1, true), out2)
    end)

    it("lw reset --state under a pin before .lw/: only .nvim/loomworks.{cache,health}.json; --builds refused", function()
        local r, bytes = legacy_workspace()
        write(r .. "/.nvim/loomworks.cache.json", '{"_meta":{"version":9,"written_by":"0.1.49+dev"}}')
        write(r .. "/.nvim/loomworks.cache.json.bak", "{}")
        write(r .. "/.nvim/loomworks.health.json", "{}")
        write(r .. "/.nvim/loomworks.user.json.bak", bytes)
        write(r .. "/.nvim/loomworks.daemon.log", "log")
        write(r .. "/.nvim/build/app/Debug/CMakeCache.txt", "x")
        local before = snapshot(r .. "/.nvim")
        _G.__loomworks_legacy_pin = "lw: this repo pins lw 0.1.43, which keeps its state in .nvim/; LEGACY-PIN-TEST"
        _G.__loomworks_legacy_pin_version = "0.1.43"
        local ok1, c1, o1 = pcall(run, r, "reset", "--state", "--builds", "-y")
        local ok2, c2, o2 = pcall(run, r, "nuke", "-y")
        local ok3, c3, o3 = pcall(run, r, "reset", "--state", "-y")
        _G.__loomworks_legacy_pin, _G.__loomworks_legacy_pin_version = nil, nil
        assert.is_true(ok1, c1); assert.is_true(ok2, c2); assert.is_true(ok3, c3)
        assert.are_not.equal(0, c1); assert.truthy(o1:find("LEGACY-PIN-TEST", 1, true), o1)
        assert.are_not.equal(0, c2); assert.truthy(o2:find("LEGACY-PIN-TEST", 1, true), o2)
        assert.equals(0, c3, o3)
        assert.truthy(o3:find("Will delete:\n  .nvim/loomworks.cache.json\n  .nvim/loomworks.cache.json.bak\n"
            .. "  .nvim/loomworks.health.json\n", 1, true), o3)
        assert.truthy(o3:find("  .nvim/loomworks.user.json\n", 1, true), o3)
        local after = snapshot(r .. "/.nvim")
        for name, content in pairs(before) do
            if name == "loomworks.cache.json" or name == "loomworks.cache.json.bak"
                    or name == "loomworks.health.json" then
                assert.is_nil(after[name], name .. " deleted")
            else
                assert.equals(content, after[name], name .. " untouched")
            end
        end
        for name in pairs(after) do assert.is_not_nil(before[name], name .. " created") end
        assert.is_false(exists(r .. "/.lw"), "nothing created in .lw/")
    end)
end)
