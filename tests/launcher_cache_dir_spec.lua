--- Tests for the launcher cache location (spec headless §16.44 *Launchers*):
--- the current launchers cache a 0.2.0+ pin's binary in .lw/cache and an
--- older pin's in .nvim/cache; launchers of earlier generations keep
--- .nvim/cache, which is never pruned.

local launcher = require("boot.launcher")
local repo_meta = require("boot.repo_meta")
local uv = vim.uv or vim.loop

local OLD_SH = "#!/bin/sh\n# an lw.sh of an earlier release\ncache=\"$here/.nvim/cache\"\n"

describe("launcher cache directory", function()
    it("current launchers, 0.2.0+ pin: .lw/cache", function()
        assert.equals(".lw/cache", launcher.cache_dir_for("0.2.0", { sh = launcher.LW_SH, cmd = launcher.LW_CMD }))
        assert.equals(".lw/cache", launcher.cache_dir_for("0.2.0-beta.6", { sh = launcher.LW_SH }))
        assert.equals(".lw/cache", launcher.cache_dir_for("1.0.0", {}))
    end)

    it("a pin below 0.2.0: .nvim/cache, where that release expects it", function()
        assert.equals(".nvim/cache", launcher.cache_dir_for("0.1.43", { sh = launcher.LW_SH, cmd = launcher.LW_CMD }))
        assert.equals(".nvim/cache", launcher.cache_dir_for("0.1.50-beta.1", {}))
    end)

    it("a launcher of an earlier generation: .nvim/cache", function()
        assert.equals(".nvim/cache", launcher.cache_dir_for("0.2.0", { sh = OLD_SH, cmd = launcher.LW_CMD }))
    end)

    it("the templates select the cache by the pinned version", function()
        assert.truthy(launcher.LW_SH:find('0.0.*|0.1.*) cache="$here/.nvim/cache"', 1, true))
        assert.truthy(launcher.LW_SH:find('*) cache="$here/.lw/cache"', 1, true))
        assert.truthy(launcher.LW_CMD:find('set "cache=%here%.lw\\cache"', 1, true))
        assert.truthy(launcher.LW_CMD:find('if "!version:~0,4!"=="0.1." set "cache=%here%.nvim\\cache"', 1, true))
        -- both write the self-ignore file before downloading
        assert.truthy(launcher.LW_SH:find(".lw/.gitignore", 1, true))
        assert.truthy(launcher.LW_CMD:find(".lw\\.gitignore", 1, true))
    end)

    it("the previous templates are a known generation (still working, minor defect)", function()
        local g = launcher.GENERATIONS.sh["17cb11f08a5f3688b49e14e20332215622c363ae89141eced2491cf20e8aa30e"]
        assert.truthy(g)
        for _, d in ipairs(g.defects) do assert.are_not.equal("breaks", d.severity) end
        assert.truthy(launcher.GENERATIONS.cmd["da74e958cb2fcaeef0f78da26ec443ea696736833bc81cd8d40f311c92f1362e"])
    end)

    it("ignore lines are checked against the cache in use", function()
        assert.is_true(launcher.ignore_line_covers("/.lw/", ".lw/cache"))
        assert.is_true(launcher.ignore_line_covers(".nvim/cache/", ".nvim/cache"))
        assert.is_false(launcher.ignore_line_covers(".nvim/", ".lw/cache"))
    end)
end)

describe("launcher cache, repository side", function()
    local root
    before_each(function()
        root = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(root, "p")
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    local function put(p, s)
        vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
        local f = assert(io.open(p, "wb")); f:write(s); f:close()
    end

    it("reads the launchers present", function()
        put(root .. "/lw.sh", launcher.LW_SH)
        assert.equals(".lw/cache", repo_meta.cache_dir(root, "0.2.0"))
        put(root .. "/lw.sh", OLD_SH)
        assert.equals(".nvim/cache", repo_meta.cache_dir(root, "0.2.0"))
    end)

    it("needs no .gitignore line for .lw/cache (it ignores itself)", function()
        put(root .. "/lw.sh", launcher.LW_SH)
        local wrote = false
        local st = repo_meta.ensure_gitignore(root, nil, function() wrote = true; return true end, "0.2.0")
        assert.equals("self", st)
        assert.is_false(wrote)
    end)

    it("never prunes .nvim/cache", function()
        put(root .. "/lw.sh", OLD_SH)
        local old = root .. "/.nvim/cache/lw-0.1.40-lw-linux-x86_64"
        put(old, "x")
        local n = repo_meta.prune_cache(root, "0.2.0")
        assert.equals(0, n)
        assert.truthy(uv.fs_stat(old))
    end)

    it("prunes old binaries in .lw/cache only by their exact names", function()
        put(root .. "/lw.sh", launcher.LW_SH)
        local old = root .. "/.lw/cache/lw-0.2.0-beta.1-lw-linux-x86_64"
        local keep = root .. "/.lw/cache/lw-0.2.0-lw-linux-x86_64"
        local other = root .. "/.lw/cache/notes.txt"
        put(old, "x"); put(keep, "y"); put(other, "z")
        local n = repo_meta.prune_cache(root, "0.2.0")
        assert.equals(1, n)
        assert.is_nil(uv.fs_stat(old))
        assert.truthy(uv.fs_stat(keep))
        assert.truthy(uv.fs_stat(other))
    end)
end)
