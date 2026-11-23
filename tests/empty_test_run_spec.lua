-- A headless test run that executed no test (spec §16.16 "Runs that execute
-- no test", #189): never `TESTS OK`. Narrowed (forwarded arguments) it is
-- `NO TESTS RAN` with exit 1; unfiltered the same line as a warning, exit 0.
-- A batch step's count comes from the results file its runner reports
-- (`results_out`); without one the count is unknown and the step's exit
-- status stays authoritative.

local test_plan = require("loomworks.test_plan")
local uv = vim.uv or vim.loop

local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

local function junit(n_cases, skipped)
    local rows = {}
    for i = 1, n_cases do
        rows[#rows + 1] = '<testcase name="T' .. i .. '" classname="T' .. i .. '" time="0" status="'
            .. (skipped and "notrun" or "run") .. '"/>'
    end
    return '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="(empty)" tests="' .. n_cases .. '">\n'
        .. table.concat(rows, "\n") .. "\n</testsuite>\n"
end

describe("a test run that executed no test (§16.16, #189)", function()
    local dir
    before_each(function()
        dir = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(dir, "p")
    end)
    after_each(function() require("loomworks.io").rm_rf(dir) end)

    --- Run a one-batch-step plan whose runner writes `xml` (nil: nothing) to its
    --- reported results file and exits `code`.
    local function run(o)
        local results = dir .. "/count.xml"
        local b = { name = "app:Debug", runner = "ctest", cmd = { "ctest" },
            results_out = o.no_results_out and nil or results, results_tmp = o.tmp and results or nil }
        local st = { kind = "batch", unit = {}, project = { key = "app" }, label = "app:Debug" }
        local prepared = { steps = { st }, batch_steps = { [st.unit] = { b } }, junit_for = function() end }
        local out, err = {}, {}
        local host = {
            out = function(s, role) out[#out + 1] = { s, role } end,
            err = function(s, role) err[#err + 1] = { s, role } end,
            spawn = function(_, cb)
                if o.xml then write(results, o.xml) end
                return cb(o.code or 0)
            end,
        }
        local rc, msg
        test_plan.run({ root = dir }, { key = "dev" }, prepared, { extra = o.extra }, host,
            function(c, m) rc, msg = c, m end)
        local text = {}
        for _, l in ipairs(out) do text[#text + 1] = l[1] end
        return { code = rc, err = msg, stdout = table.concat(text, "\n"), lines = out,
            results = results }
    end

    local function role_of(r, needle)
        for _, l in ipairs(r.lines) do if l[1]:find(needle, 1, true) then return l[2] end end
    end

    it("narrowed (forwarded args) with zero cases in the results file: NO TESTS RAN, exit 1", function()
        local r = run({ xml = junit(0), extra = { "-R", "Alias" } })
        assert.equals(1, r.code, r.stdout)
        assert.equals("no tests ran (the forwarded arguments matched no tests)", r.err)
        assert.truthy(r.stdout:find("NO TESTS RAN: dev (1 step)", 1, true), r.stdout)
        assert.falsy(r.stdout:find("TESTS OK", 1, true), r.stdout)
        assert.truthy(r.stdout:find("app: ctest%s+no tests ran"), r.stdout)
        assert.equals("fail", role_of(r, "NO TESTS RAN"))
    end)

    it("skipped cases are not executed: narrowed, every case skipped, exit 1", function()
        local r = run({ xml = junit(2, true), extra = { "-R", "x" } })
        assert.equals(1, r.code, r.stdout)
        assert.truthy(r.stdout:find("NO TESTS RAN: dev (1 step)", 1, true), r.stdout)
    end)

    it("unfiltered with zero cases: the NO TESTS RAN warning instead of TESTS OK, exit 0", function()
        local r = run({ xml = junit(0) })
        assert.equals(0, r.code, r.stdout)
        assert.is_nil(r.err)
        assert.truthy(r.stdout:find("NO TESTS RAN: dev (1 step)", 1, true), r.stdout)
        assert.falsy(r.stdout:find("TESTS OK", 1, true), r.stdout)
        assert.equals("warn", role_of(r, "NO TESTS RAN"))
    end)

    it("a case executed: TESTS OK as before", function()
        local r = run({ xml = junit(1), extra = { "-R", "T1" } })
        assert.equals(0, r.code, r.stdout)
        assert.truthy(r.stdout:find("TESTS OK: dev (1 step)", 1, true), r.stdout)
    end)

    it("no results file reported, or none written: the count is unknown, TESTS OK on exit 0", function()
        local r = run({ no_results_out = true, extra = { "-R", "x" } })
        assert.equals(0, r.code, r.stdout)
        assert.truthy(r.stdout:find("TESTS OK: dev (1 step)", 1, true), r.stdout)
        r = run({ extra = { "-R", "x" } })
        assert.equals(0, r.code, r.stdout)
        assert.truthy(r.stdout:find("TESTS OK: dev (1 step)", 1, true), r.stdout)
    end)

    it("a failed step stays a failure (not NO TESTS RAN)", function()
        local r = run({ xml = junit(0), code = 8, extra = { "-R", "x" } })
        assert.equals(1, r.code)
        assert.equals("1 of 1 test step failed", r.err)
        assert.falsy(r.stdout:find("NO TESTS RAN", 1, true), r.stdout)
    end)

    it("a temporary count file is removed once read", function()
        local r = run({ xml = junit(0), tmp = true })
        assert.equals(0, r.code)
        assert.is_nil(uv.fs_stat(r.results))
    end)
end)
