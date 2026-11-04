-- Deletion safety of the orphan cleanup and stray-directory deletion
-- (`model_commands.execute_deletion` with an `orphans` or `stray_dir`
-- target, API.md §22; spec §4.6, §5.7, §19.3) and of `_run_deletion`'s
-- crash-safety marks: the orphaned entries' cache state is `unknown` on disk
-- before any tree is removed; a directory that stopped being stray, an orphan
-- re-adopted, a workspace unloaded or a re-check that raises under the locks
-- removes nothing and releases the locks; an orphan dir that is (8.3 short
-- name) or holds a live build dir is kept, also by `reset --all` when that
-- live dir was not removed; one dir under two spellings is marked `unknown`
-- under both and `overlap_exempt` matches it by identity; a skipped shared
-- dir keeps its state when another removal fails; nothing is removed when the
-- `unknown` marks cannot be saved. Ported from loomworks.nvim's spec of the
-- same name (the cases not covered by the other deletion specs).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local bl = require("loomworks.build_lock")
local op_lock = require("loomworks.op_lock")
local commands = require("loomworks.model_commands")
local dp = require("loomworks.deletion_plan")
local L = require("tests.lock_helpers")
local uv = vim.uv or vim.loop
local DONE_MS, RELEASE_MS = L.DONE_MS, L.RELEASE_MS

local function load(root) return assert(cli._load_workspace(root, false)) end

--- Add a cached build directory no profile references (an orphan), at `dir`
--- (default: a directory of its own).
local function add_orphan(ws, root, dir)
    dir = dir or (root .. "/.nvim/build/App/Release")
    vim.fn.mkdir(dir, "p")
    local cache = ws:_serialize_cache()
    cache.build_dirs = cache.build_dirs or {}
    cache.build_dirs["App/Release"] = {
        project_key = "App", config_key = "Release",
        type = "typescript", variant = "default", state = "built",
        build_dir = dir,
    }
    ws:remerge(nil, cache)
    assert.equals(1, #ws:get_orphaned_configs(), "test setup: one orphan")
    return dir
end

describe("deletion safety (execute_deletion)", function()
    local io_mod = require("loomworks.io")
    local real_rm
    local root, built, ws, errs

    before_each(function()
        real_rm = io_mod.rm_rf_async
        root, built = L.make_ws()
        ws = load(root)
        ws._core._deps.on_lock_refused = nil
        errs = {}
        ws._core._deps.notify = function(msg, level)
            if level == vim.log.levels.ERROR then errs[#errs + 1] = msg end
        end
    end)
    after_each(function()
        io_mod.rm_rf_async = real_rm
        L.cleanup()
        op_lock.release_all()
    end)

    local function wait_done(start)
        local done, ok, err = false, nil, nil
        start(function(o, e) done, ok, err = true, o, e end)
        assert.is_true(vim.wait(DONE_MS, function() return done end, 20), "on_done never called")
        return ok, err
    end

    local function locks_released(dir)
        return vim.wait(RELEASE_MS, function()
            return op_lock.read(root) == nil and (not dir or bl.read(dir) == nil)
        end, 20)
    end

    --- Start the confirmed deletion of `target`; `done(ok, message)` gets its
    --- final outcome (the request's when it was not accepted).
    local function delete(target, done)
        local r = commands.execute_deletion(ws, target, {
            yes = true,
            done = function(o) done(o.outcome == "ok", o.message) end,
        })
        if r.outcome ~= "accepted" then done(false, r.message) end
    end

    local function cleanup_now(done) delete({ orphans = true }, done) end

    --- Run `extra()` after every `_tracker:sync()` (what the deletion's
    --- re-check under the locks applies).
    local function on_sync(extra)
        assert.is_not_nil(ws._tracker, "test setup: the workspace has a file tracker")
        local real_sync = ws._tracker.sync
        ws._tracker.sync = function(t)
            real_sync(t)
            extra()
        end
    end

    local function count_rm()
        local removed = {}
        io_mod.rm_rf_async = function(d, cb)
            removed[#removed + 1] = d
            return real_rm(d, cb)
        end
        return removed
    end

    describe("orphan cleanup", function()
        it("marks the orphan's cache entry unknown on disk before removing its tree", function()
            local dir = add_orphan(ws, root)
            local on_disk
            io_mod.rm_rf_async = function(d, cb)
                if not on_disk then on_disk = L.read(root .. "/.nvim/loomworks.cache.json") or "" end
                return real_rm(d, cb)
            end
            local ok = wait_done(cleanup_now)
            assert.is_true(ok)
            assert.is_truthy(on_disk and on_disk:find('"unknown"', 1, true),
                "the orphan was not marked unknown on disk before the removal")
            assert.is_nil(uv.fs_stat(dir))
            assert.equals(0, #ws:get_orphaned_configs())
        end)

        it("keeps a stray directory that stopped being stray before the lock was taken", function()
            local stray = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(stray, "p")
            assert.equals(1, #dp.plan(ws, { orphans = true }).strays, "test setup: one stray dir")
            local removed = count_rm()
            -- Another process configured into it; applying that change (an
            -- external cache write reloads the workspace, so it is applied
            -- in place here) makes it live.
            on_sync(function()
                local unit = ws._profiles[1]:projects()[1]._config_unit
                unit.build_dir_value = stray
                ws:_sync_build_dir_refs()
            end)
            local ok, err = wait_done(cleanup_now)
            assert.is_not_nil(uv.fs_stat(stray), "a directory that is no longer stray was removed")
            assert.same({}, removed, "rm-rf was handed a directory of the changed plan")
            -- The re-check under the locks refuses the changed plan.
            assert.is_false(ok)
            assert.equals(dp.CHANGED, err)
            assert.is_true(locks_released(ws._core._deps.normalize(stray)))
        end)

        it("deletes nothing when applying external changes unloaded the workspace", function()
            local dir = add_orphan(ws, root)
            local stray = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(stray, "p")
            local removed = count_rm()
            on_sync(function() ws._torn_down = true end)
            local ok = wait_done(cleanup_now)
            ws._torn_down = nil
            assert.is_false(ok)
            assert.same({}, removed, "a torn-down workspace removed directories")
            assert.is_not_nil(uv.fs_stat(dir))
            assert.is_not_nil(uv.fs_stat(stray))
            assert.is_true(locks_released(dir))
        end)

        it("keeps an orphan another process re-adopted before the lock was taken", function()
            local dir = add_orphan(ws, root)
            local bd = ws:get_orphaned_configs()[1].build_dir_obj
            local removed = count_rm()
            on_sync(function()
                -- Another process now configures a live unit into the orphan.
                local unit = ws._profiles[1]:projects()[1]._config_unit
                unit._build_dir = bd
                unit.build_dir_value = dir
                ws:_sync_build_dir_refs()
            end)
            local ok, err = wait_done(cleanup_now)
            -- The re-check under the locks refuses the changed plan.
            assert.is_false(ok)
            assert.equals(dp.CHANGED, err)
            assert.same({}, removed, "a re-adopted build directory was removed")
            assert.is_not_nil(uv.fs_stat(dir))
            assert.equals("built", bd.state, "the re-adopted BuildDir's state was cleared")
            local present = false
            for _, b in ipairs(ws._build_dirs) do if b == bd then present = true end end
            assert.is_true(present, "the re-adopted BuildDir was dropped")
        end)

        it("calls on_done(false) and releases the locks when the re-check raises", function()
            local dir = add_orphan(ws, root)
            on_sync(function() error("sync exploded") end)
            local ok = wait_done(cleanup_now)
            assert.is_false(ok)
            assert.is_not_nil(uv.fs_stat(dir))
            assert.is_true(locks_released(dir))
        end)
    end)

    -- The status page's single-row orphan delete (`delete_orphaned_build_dir`)
    -- gets the same protections as the bulk cleanup: an orphan dir that
    -- contains a live build dir (a build-dir template that gained a level,
    -- `.nvim/build/App` -> `.nvim/build/App/Debug`) or that IS a live build
    -- dir under another spelling (8.3 short name) keeps its tree; only the
    -- entry is dropped.
    describe("single-row orphan delete", function()
        local function delete_row()
            local key = ws:get_orphaned_configs()[1].build_dir_key
            local done, ok = false, nil
            ws:delete_orphaned_build_dir(key):next(function(v) done, ok = true, v end)
            assert.is_true(vim.wait(DONE_MS, function() return done end, 20), "delete never finished")
            return ok
        end

        it("never removes an orphan dir that is a live build dir under its 8.3 short name", function()
            if vim.fn.has("win32") == 0 then
                pending("8.3 short names are Windows-only"); return
            end
            local out = vim.fn.system({ "cmd", "/c",
                "for %I in (\"" .. built:gsub("/", "\\") .. "\") do @echo %~sI" })
            local short = vim.trim(out or ""):gsub("\\", "/")
            if vim.v.shell_error ~= 0 or not short:find("~", 1, true) then
                pending("8.3 short names unavailable on this volume"); return
            end
            add_orphan(ws, root, short)
            local removed = count_rm()
            delete_row()
            assert.equals(0, #removed, "rm-rf was handed " .. table.concat(removed, ", "))
            assert.is_not_nil(uv.fs_stat(built), "the live build dir was removed")
        end)
    end)

    -- `lw reset --all`: every live unit's dir is removed in phase 1, so an
    -- orphan dir that holds only those dirs is removed in phase 2 (a reset
    -- leaves no build dirs, spec §16.30) — the plan listed it as removed and
    -- the gone-from-disk check must agree.
    describe("reset --all", function()
        local reset_plan = require("loomworks.reset_plan")
        -- Phase 1's cache write reaches a live host's file reconciliation
        -- before phase 2 (the editor, the daemon): the remerge re-derives
        -- each reset unit's build dir from the cache, so phase 2 sees the
        -- live dirs it just removed.
        before_each(function()
            local real = ws.delete_orphaned_build_dir
            ws.delete_orphaned_build_dir = function(w, ...)
                w:remerge(nil, w:_serialize_cache())
                return real(w, ...)
            end
        end)
        local function reset_all()
            local plan = reset_plan.plan(ws, { all = true })
            local done, got = false, nil
            reset_plan.execute(ws, plan, { verify_ms = 200 },
                function(code, msg) done, got = true, { code = code, msg = msg } end)
            assert.is_true(vim.wait(DONE_MS, function() return done end, 20), "reset never finished")
            return plan, got
        end

        it("removes an orphan dir that contains a live build dir it also resets", function()
            local dir = add_orphan(ws, root, root .. "/.nvim/build/App")
            local plan, got = reset_all()
            assert.is_true(vim.tbl_contains(plan.removal_dirs, dir), "test setup: listed as removed")
            assert.equals(0, got.code, tostring(got.msg))
            assert.is_nil(uv.fs_stat(dir), "the orphan's tree was kept")
            assert.is_nil(uv.fs_stat(built))
            assert.equals(0, #ws:get_orphaned_configs())
        end)

        it("still keeps an orphan dir whose live build dir the reset could not remove", function()
            local dir = add_orphan(ws, root, root .. "/.nvim/build/App")
            io_mod.rm_rf_async = function(d, cb)
                if vim.startswith(d:lower(), built:lower()) then return cb(false, "boom") end
                return real_rm(d, cb)
            end
            local _, got = reset_all()
            assert.equals(1, got.code)
            assert.is_not_nil(uv.fs_stat(dir))
            assert.is_not_nil(uv.fs_stat(built), "the live build dir went with the orphan")
        end)

        -- A live dir phase 1 refused (`_validate_build_dir`: e.g. a junction
        -- leading outside the root) was never removed, so it must keep
        -- protecting the orphan that contains it: the reset leaves both and
        -- does not report success (spec §16.30: a refused dir is not removed).
        it("keeps an orphan dir holding a live build dir the deletion refused", function()
            local dir = add_orphan(ws, root, root .. "/.nvim/build/App")
            local norm = ws._core._deps.normalize
            local refused = norm(built)
            local real_validate = ws._validate_build_dir
            ws._validate_build_dir = function(w, d, ...)
                if norm(d) == refused then return false end
                return real_validate(w, d, ...)
            end
            local plan, got = reset_all()
            assert.is_true(vim.tbl_contains(plan.outside_dirs, built), "test setup: listed as not removed")
            assert.is_not_nil(uv.fs_stat(built), "the refused live build dir was removed")
            assert.is_not_nil(uv.fs_stat(dir), "the orphan holding the refused live dir was removed")
            assert.are_not.equal(0, got.code, "the reset reported success")
        end)
    end)

    describe("stray directory deletion", function()
        it("keeps a directory that stopped being stray before the lock was taken", function()
            local stray = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(stray, "p")
            local n = ws._core._deps.normalize(stray)
            -- The scan reports the spelling under ws.root, which may differ
            -- from the test root's (8.3 short temp path on a Windows runner).
            local found = ws:find_stray_build_dirs()
            assert.equals(1, #found, "test setup: one stray dir")
            assert.equals(ws:_canonicalize_boundary_path(n), ws:_canonicalize_boundary_path(found[1]),
                "test setup: one stray dir")
            on_sync(function()
                local unit = ws._profiles[1]:projects()[1]._config_unit
                unit.build_dir_value = stray
                ws:_sync_build_dir_refs()
            end)
            local removed = count_rm()
            local ok, err = wait_done(function(done) delete({ stray_dir = n }, done) end)
            -- The re-check under the locks plans again and refuses: the
            -- directory is no longer in the stray set.
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("not a stray build directory", 1, true), tostring(err))
            assert.same({}, removed, "rm-rf was handed a directory that is no longer stray")
            assert.is_not_nil(uv.fs_stat(stray), "a directory that is no longer stray was removed")
            assert.is_true(locks_released(n))
        end)

        it("deletes nothing when applying external changes unloaded the workspace", function()
            local stray = ws._core._deps.normalize(root .. "/.nvim/build/App/Stray")
            vim.fn.mkdir(stray, "p")
            local removed = count_rm()
            on_sync(function() ws._torn_down = true end)
            local ok = wait_done(function(done) delete({ stray_dir = stray }, done) end)
            ws._torn_down = nil
            assert.is_false(ok)
            assert.same({}, removed)
            assert.is_not_nil(uv.fs_stat(stray))
            assert.is_true(locks_released(stray))
        end)

        it("calls on_done(false) and releases the locks when the re-check raises", function()
            local stray = ws._core._deps.normalize(root .. "/.nvim/build/App/Stray")
            vim.fn.mkdir(stray, "p")
            on_sync(function() error("sync exploded") end)
            local ok = wait_done(function(done) delete({ stray_dir = stray }, done) end)
            assert.is_false(ok)
            assert.is_not_nil(uv.fs_stat(stray))
            assert.is_true(locks_released(stray))
        end)
    end)
end)

-- `_run_deletion`'s crash-safety marks (spec §4.6, §5.7), ported from master
-- (#298): a configured unit's entry is serialized from its BuildDir, and only
-- the dirs actually handed to rm-rf are marked `unknown`.
describe("deletion unknown marks", function()
    local io_mod = require("loomworks.io")
    local real_rm
    local root, built, ws

    before_each(function()
        real_rm = io_mod.rm_rf_async
        root, built = L.make_ws()
        ws = load(root)
        ws._core._deps.on_lock_refused = nil
        ws._core._deps.notify = function() end
    end)
    after_each(function()
        io_mod.rm_rf_async = real_rm
        L.cleanup()
        op_lock.release_all()
    end)

    -- A shared build dir that `_run_deletion` skips (another live unit still
    -- references it) is never handed to rm-rf, so its BuildDir must not be
    -- marked `unknown`: if another removal in the batch fails, nothing would
    -- restore it and the surviving unit would reload as `unknown` (blocked
    -- from configure/build). The dir that IS removed is still `unknown` on
    -- disk before its rm-rf starts.
    it("leaves a skipped shared dir's state alone when another removal in the batch fails", function()
        L.capture(function() cli.cmd_configuration("add", root, "App", "Other", "variant:default") end)
        ws = load(root)
        ws._core._deps.notify = function() end
        local orphan_dir = add_orphan(ws, root)
        local orphan = ws:get_orphaned_configs()[1]
        local unit_a = ws._profiles[1]:projects()[1]._config_unit
        local shared_bd = unit_a._build_dir
        assert.is_not_nil(shared_bd, "test setup: the live unit has a BuildDir")
        local project = unit_a._project
        local unit_b = ws:ensure_config_unit(project, project:get_configuration("Other"), nil)
        unit_b.build_dir_value = built
        unit_b.state_value = "built"
        unit_b._build_dir = shared_bd
        ws:_sync_build_dir_refs()
        assert.equals(2, #ws:get_build_dir_refs(ws._core._deps.normalize(built)), "test setup: dir is shared")
        ws:_save_cache()

        local removed_state, handed = nil, {}
        local norm_orphan = ws._core._deps.normalize(orphan_dir)
        io_mod.rm_rf_async = function(d, cb)
            handed[#handed + 1] = d
            if ws._core._deps.normalize(d) == norm_orphan then
                local cache = vim.json.decode(L.read(root .. "/.nvim/loomworks.cache.json") or "{}")
                removed_state = "<missing>"
                for _, e in pairs(cache.build_dirs or {}) do
                    if e.project_key == "App" and e.config_key == "Release" then removed_state = e.state end
                end
            end
            cb(false, "boom")
        end
        local done = false
        ws:_run_deletion({
            { project_key = "App", config_key = "Other", build_dir = built, unit = unit_b },
            { project_key = "App", config_key = "Release", build_dir = orphan_dir,
              build_dir_obj = orphan.build_dir_obj },
        }, function() end, function() done = true end)
        assert.is_true(vim.wait(DONE_MS, function() return done end, 20), "deletion never finished")

        assert.equals(1, #handed, "only the unshared dir is handed to rm-rf")
        assert.equals("unknown", removed_state,
            "the removed dir's entry was not unknown on disk before its rm-rf")
        local cache = vim.json.decode(L.read(root .. "/.nvim/loomworks.cache.json") or "{}")
        local shared_state = "<missing>"
        for _, e in pairs(cache.build_dirs or {}) do
            if ws._core._deps.normalize(e.build_dir or "") == ws._core._deps.normalize(built) then
                shared_state = e.state
            end
        end
        assert.equals("built", shared_state,
            "the skipped shared dir was left unknown on disk after a failed batch")
        assert.equals("built", shared_bd.state)
    end)


    -- Crash safety by directory IDENTITY (spec §4.6): one batch deleting two
    -- entries whose build dirs are the same tree under its long and 8.3 short
    -- spellings hands the tree to rm-rf once, but BOTH entries must be
    -- `unknown` on disk before it starts — otherwise the second stays `built`
    -- in the cache while its tree is being removed.
    describe("one dir under two spellings in a batch", function()
        local function setup()
            if vim.fn.has("win32") == 0 then
                pending("8.3 short names are Windows-only"); return
            end
            local out = vim.fn.system({ "cmd", "/c",
                "for %I in (\"" .. built:gsub("/", "\\") .. "\") do @echo %~sI" })
            local short = vim.trim(out or ""):gsub("\\", "/")
            if vim.v.shell_error ~= 0 or not short:find("~", 1, true)
                or ws._core._deps.normalize(short) == ws._core._deps.normalize(built) then
                pending("8.3 short names unavailable on this volume"); return
            end
            L.capture(function() cli.cmd_configuration("add", root, "App", "Other", "variant:default") end)
            ws = assert(cli._load_workspace(root, false))
            ws._core._deps.notify = function() end
            local unit_a = ws._profiles[1]:projects()[1]._config_unit
            local project = unit_a._project
            local unit_b = ws:ensure_config_unit(project, project:get_configuration("Other"), nil)
            unit_b.build_dir_value = short
            unit_b.state_value = "built"
            ws:_sync_build_dir_refs()
            ws:_save_cache()
            return {
                { project_key = "App", config_key = "Debug", build_dir = built, unit = unit_a },
                { project_key = "App", config_key = "Other", build_dir = short, unit = unit_b },
            }
        end

        local function disk_states()
            local cache = vim.json.decode(L.read(root .. "/.nvim/loomworks.cache.json") or "{}")
            local states = {}
            for _, e in pairs(cache.build_dirs or {}) do
                if e.project_key == "App" then states[e.config_key] = e.state end
            end
            return states
        end

        local function run(items)
            local done = false
            ws:_run_deletion(items, function() end, function() done = true end)
            assert.is_true(vim.wait(DONE_MS, function() return done end, 20), "deletion never finished")
        end

        it("marks both entries unknown on disk before the rm-rf", function()
            local items = setup()
            if not items then return end
            local at_rm, handed = nil, 0
            io_mod.rm_rf_async = function(d, cb)
                handed = handed + 1
                at_rm = at_rm or disk_states()
                return real_rm(d, cb)
            end
            run(items)
            assert.equals(1, handed, "the tree is handed to rm-rf once")
            assert.equals("unknown", at_rm.Debug, "App/Debug on disk at rm-rf: " .. tostring(at_rm.Debug))
            assert.equals("unknown", at_rm.Other, "App/Other on disk at rm-rf: " .. tostring(at_rm.Other))
        end)

        it("keeps both entries, neither built, when the removal fails", function()
            local items = setup()
            if not items then return end
            io_mod.rm_rf_async = function(_, cb) cb(false, "boom") end
            run(items)
            local states = disk_states()
            assert.is_not_nil(states.Debug, "App/Debug's entry was dropped")
            assert.is_not_nil(states.Other, "App/Other's entry was dropped")
            assert.are_not.equals("built", states.Debug, "App/Debug still claims built")
            assert.are_not.equals("built", states.Other, "App/Other still claims built")
            assert.is_not_nil(uv.fs_stat(built))
        end)
    end)

    -- `overlap_exempt` (reset --all phase 2: the live dirs phase 1 removed) is
    -- matched by directory IDENTITY (spec §4.6): when two live units name one
    -- dir under its long and 8.3 short spellings and the exempt list holds
    -- the long one, an orphan dir holding it (recorded under the short
    -- spelling) is no longer shielded by the other unit's short spelling.
    it("overlap_exempt covers a live dir recorded under another spelling", function()
        if vim.fn.has("win32") == 0 then
            pending("8.3 short names are Windows-only"); return
        end
        local function short_of(p)
            local out = vim.fn.system({ "cmd", "/c",
                "for %I in (\"" .. p:gsub("/", "\\") .. "\") do @echo %~sI" })
            return vim.v.shell_error == 0 and (vim.trim(out or ""):gsub("\\", "/")) or nil
        end
        local app = root .. "/.nvim/build/App"
        local short, short_app = short_of(built), short_of(app)
        if not short or not short:find("~", 1, true) or not short_app
                or ws._core._deps.normalize(short) == ws._core._deps.normalize(built) then
            pending("8.3 short names unavailable on this volume"); return
        end
        L.capture(function() cli.cmd_configuration("add", root, "App", "Other", "variant:default") end)
        ws = load(root)
        ws._core._deps.notify = function() end
        add_orphan(ws, root, short_app)
        local orphan = ws:get_orphaned_configs()[1]
        local unit_a = ws._profiles[1]:projects()[1]._config_unit
        local project = unit_a._project
        local unit_b = ws:ensure_config_unit(project, project:get_configuration("Other"), nil)
        unit_b.build_dir_value = short
        unit_b.state_value = "built"
        ws:_sync_build_dir_refs()

        local report, done = {}, false
        ws:_run_deletion({
            { project_key = "App", config_key = "Release", build_dir = short_app,
              build_dir_obj = orphan.build_dir_obj, disposition = "clean" },
        }, function() end, function() done = true end, nil,
            { overlap_exempt = { ws._core._deps.normalize(built) }, report = report })
        assert.is_true(vim.wait(DONE_MS, function() return done end, 20), "deletion never finished")
        assert.same({}, report.kept or {}, "kept: " .. vim.inspect(report.kept))
        assert.is_nil(uv.fs_stat(app), "the orphan's tree was kept")
    end)

    -- reset --all end to end (#309 review): a live unit recorded its dir
    -- under its 8.3 short LEAF (`App/LONG-D~1`); an orphan at
    -- `.nvim/build/App` holds it. Phase 1 removes the dir; between the
    -- phases a live host's remerge re-derives the reset unit's dir from its
    -- template under the LONG leaf (`App/long-debug-directory`). The removed
    -- dir's identity must be taken while it still resolves: computed after
    -- the removal, the short leaf no longer canonicalizes to the long one,
    -- the unit still shields the orphan, and the reset keeps it and fails.
    it("reset --all removes an orphan holding a live dir it removed under its short leaf", function()
        if vim.fn.has("win32") == 0 then
            pending("8.3 short names are Windows-only"); return
        end
        local app = root .. "/.nvim/build/App"
        local long = app .. "/long-debug-directory"
        vim.fn.mkdir(long, "p")
        local out = vim.fn.system({ "cmd", "/c",
            "for %I in (\"" .. long:gsub("/", "\\") .. "\") do @echo %~sI" })
        local short = vim.v.shell_error == 0 and (vim.trim(out or ""):gsub("\\", "/")) or nil
        local norm = ws._core._deps.normalize
        if not short or not short:match("~%d+$") or norm(short) == norm(long) then
            pending("8.3 short names unavailable on this volume"); return
        end
        -- Only the leaf differs from the long spelling.
        short = app .. "/" .. short:match("[^/]+$")
        L.capture(function()
            cli.cmd_configuration("add", root, "App", "long-debug-directory", "variant:default")
            cli.cmd_cset("create", root, { "configuration-set", "create", "Long", "App=long-debug-directory" })
            cli.cmd_profile_create(root, { "profile", "create", "Long", "--activate" })
        end)
        ws = load(root)
        ws._core._deps.notify = function() end
        add_orphan(ws, root, app)
        local unit
        for _, u in pairs(ws._config_units) do
            if u:configuration() and u:configuration().name == "long-debug-directory" then unit = u end
        end
        assert.is_not_nil(unit, "test setup: the long-named unit")
        unit.build_dir_value = short
        unit.state_value = "built"
        ws:_sync_build_dir_refs()
        ws:_save_cache()
        -- A live host's file reconciliation between the phases (see the
        -- "reset --all" tests above).
        local real_del = ws.delete_orphaned_build_dir
        local rederived
        ws.delete_orphaned_build_dir = function(w, ...)
            w:remerge(nil, w:_serialize_cache())
            rederived = unit:build_dir()
            return real_del(w, ...)
        end

        local done, result = false, nil
        ws:reset_all():next(function(v) done, result = true, v end)
        assert.is_true(vim.wait(DONE_MS, function() return done end, 20), "reset never finished")
        assert.equals("long-debug-directory", (rederived or ""):match("[^/]+$"),
            "test setup: the remerge re-derives the long leaf: " .. tostring(rederived))
        assert.is_true(result, "reset --all reported a failure")
        assert.is_nil(uv.fs_stat(app), "the orphan's tree was kept")
        assert.equals(0, #ws:get_orphaned_configs())
    end)

    -- Crash rule (Deletion Safety 4): when the `unknown` marks cannot reach
    -- the disk — the runtime lost its lock (`_no_write`), or the workspace
    -- was torn down while the deletion waited for its tasks to stop — no tree
    -- is removed; every item fails with the save error and the entries are
    -- left as they were.
    local function deletion_without_save(break_save)
        local unit = ws._profiles[1]:projects()[1]._config_unit
        assert.is_not_nil(unit and unit._build_dir, "test setup: the live unit has a BuildDir")
        local prior = unit._build_dir.state
        local handed = {}
        io_mod.rm_rf_async = function(d, cb)
            handed[#handed + 1] = d
            return real_rm(d, cb)
        end
        local failed
        ws:on("deletion_failed", function(p) failed = p end)
        break_save(unit)
        local done, result, work_ran = false, nil, false
        ws:_run_deletion({
            { project_key = "App", config_key = "Debug", build_dir = built, unit = unit },
        }, function() work_ran = true end):next(function(v) done, result = true, v end)
        assert.is_true(vim.wait(DONE_MS, function() return done end, 20), "deletion never finished")
        assert.is_false(result, "a deletion whose unknown marks never reached disk reported success")
        assert.equals(0, #handed, "rm-rf was handed " .. table.concat(handed, ", "))
        assert.is_not_nil(uv.fs_stat(built), "the tree was removed")
        assert.equals(prior, unit._build_dir.state, "the entry was left marked unknown")
        assert.is_false(unit:is_deleting(), "the unit was left deleting")
        assert.is_not_nil(failed, "deletion_failed not emitted")
        assert.equals(1, #failed.errors)
        assert.is_false(work_ran, "the cache mutations ran")
    end

    it("removes nothing when the unknown marks cannot be saved (lost lock)", function()
        deletion_without_save(function() ws._no_write = "lost the workspace lock" end)
    end)

    it("removes nothing when the workspace is torn down while tasks stop", function()
        deletion_without_save(function()
            local future = require("loomworks.future")
            ws.stop_tasks_then = function(self)
                self._torn_down = true
                return future.resolved(true)
            end
        end)
    end)
end)
