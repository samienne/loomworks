-- CTestUnit: the `-C` config passed to ctest must be the cmake BUILD TYPE
-- (module variant, e.g. "Debug"), not the loomworks configuration name
-- (`variant:Debug`). A multi-config generator (Visual Studio) builds into a
-- config dir named by the build type; passing the config name made ctest
-- report tests as "Not Run". Single-config generators (Ninja) ignore -C.

local CTestUnit = require("loomworks.test_units.ctest")

describe("CTestUnit results file (spec §19.15 Tests)", function()
    it("a structured run writes to opts.output_path when given (a per-run path)", function()
        local tu = CTestUnit.new({
            build_dir = function() return "/nonexistent-build" end,
            variant = function() return "Debug" end,
            configuration = function() return nil end,
            configuration_env = function() return {} end,
            run_env = function() return nil end,
        })
        tu._entries = {
            { id = "target:t", name = "t", runnable = true, framework = "gtest", executable = "/b/t" },
            { id = "test:A.B", name = "A.B", parent = "target:t", runnable = true, framework = "gtest",
                executable = "/b/t" },
        }
        tu._exec_specs = { ["/b/t"] = { cmd = { "/b/t" }, env = {} } }
        local c = tu:test_command("test:A.B", { output_path = "/w/.lw/tmp/lw-test-ab12.xml" })
        assert.equals("/w/.lw/tmp/lw-test-ab12.xml", c.output_path)
        assert.equals("--gtest_output=xml:/w/.lw/tmp/lw-test-ab12.xml", c.cmd[#c.cmd])
        assert.equals("A.B", c.env.GTEST_FILTER)
        local all = tu:test_command_all({ output_path = "/w/.lw/tmp/lw-test-cd34.xml" })
        assert.equals("/w/.lw/tmp/lw-test-cd34.xml", all.output_path)
    end)
end)

local function stub_unit(opts)
    return {
        build_dir = function() return opts.build_dir end,
        variant = function() return opts.config_name end,
        configuration = function() return opts.configuration end,
        _cached_module_config = opts.cached_module_config,
        run_env = function() return opts.run_env end,
    }
end

describe("CTestUnit ctest -C configuration", function()
    it("uses the module build type (variant), not the config name", function()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b",
            config_name = "variant:Debug",
            configuration = { module_config = { variant = "Debug" } },
        }))
        assert.equals("Debug", tu._configuration)
    end)

    it("falls back to the cached module_config variant", function()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b",
            config_name = "variant:Release",
            configuration = nil,
            cached_module_config = { variant = "Release" },
        }))
        assert.equals("Release", tu._configuration)
    end)

    it("falls back to the config name when there is no module variant", function()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b",
            config_name = "Debug",
            configuration = { module_config = {} },
        }))
        assert.equals("Debug", tu._configuration)
    end)

    it("reports run_command_all_rebuilds() false (ctest does not build)", function()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b", config_name = "Debug",
            configuration = { module_config = { variant = "Debug" } },
        }))
        assert.is_false(tu:run_command_all_rebuilds())
    end)
end)

-- ctest launches the test executables itself and, unlike `meson test`, does NOT
-- put the build tree's sibling DLL dirs on PATH. So run_command_all must carry
-- the unit's run environment (§8.7) or a DLL-dependent test fails in the loader
-- with 0xc0000135 on Windows. Caught by the multi-lib CLI e2e (scripts/ci).
describe("CTestUnit run environment (§8.7)", function()
    it("carries the config unit's run_env into the run command", function()
        local sentinel = { PATH = "/build/lib;/orig" }
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b", config_name = "Debug",
            configuration = { module_config = { variant = "Debug" } },
            run_env = sentinel,
        }))
        -- Bypass on-disk ctest-dir discovery for a pure unit test.
        tu._find_ctest_dir = function() return "/b/ctestdir" end
        tu._base_cmd = function() return { "ctest", "--test-dir", "/b/ctestdir" } end
        local spec = tu:run_command_all()
        assert.equals(sentinel, spec.env)
    end)
end)

describe("CTestUnit run_command_all args + JUnit (spec §16.16)", function()
    local function tu_for()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b", config_name = "Debug",
            configuration = { module_config = { variant = "Debug" } },
        }))
        tu._find_ctest_dir = function() return "/b/ctestdir" end
        tu._base_cmd = function() return { "ctest", "--test-dir", "/b/ctestdir" } end
        return tu
    end

    it("maps --junit to ctest --output-junit; junit_out equals the request", function()
        local spec = tu_for():run_command_all({ junit = "/out/report.xml" })
        assert.same(
            { "ctest", "--test-dir", "/b/ctestdir", "--output-on-failure",
              "--output-junit", "/out/report.xml" },
            spec.cmd)
        assert.equals("/out/report.xml", spec.junit_out)
    end)

    it("forwards extra_args after the built-in flags", function()
        local spec = tu_for():run_command_all({ extra_args = { "-j", "4" } })
        assert.same(
            { "ctest", "--test-dir", "/b/ctestdir", "--output-on-failure", "-j", "4" },
            spec.cmd)
        assert.is_nil(spec.junit_out)
    end)

    -- #189: a count file for the empty-run rule (spec §16.16; cmake.md §8.1),
    -- only with a ctest that has --output-junit (3.21+).
    it("asks for a count file at opts.results with ctest >= 3.21; reports it as results_out", function()
        local orig = CTestUnit._output_junit_supported
        CTestUnit._output_junit_supported = function() return true end
        local spec = tu_for():run_command_all({ results = "/ws/.lw/tmp/lw-test-1.xml", extra_args = { "-R", "x" } })
        CTestUnit._output_junit_supported = orig
        assert.same(
            { "ctest", "--test-dir", "/b/ctestdir", "--output-on-failure",
              "--output-junit", "/ws/.lw/tmp/lw-test-1.xml", "-R", "x" },
            spec.cmd)
        assert.equals("/ws/.lw/tmp/lw-test-1.xml", spec.results_out)
        assert.is_nil(spec.junit_out)
    end)

    it("an older or unknown ctest gets no count file (count unknown)", function()
        local orig = CTestUnit._output_junit_supported
        CTestUnit._output_junit_supported = function() return false end
        local spec = tu_for():run_command_all({ results = "/ws/.lw/tmp/lw-test-1.xml" })
        CTestUnit._output_junit_supported = orig
        assert.same({ "ctest", "--test-dir", "/b/ctestdir", "--output-on-failure" }, spec.cmd)
        assert.is_nil(spec.results_out)
    end)

    it("probes the ctest the step runs (its env PATH), once per resolved executable", function()
        local exe = require("loomworks.exe")
        local orig_resolve, orig_system = exe.resolve, vim.fn.system
        local probed = {}
        exe.resolve = function(name, env)
            assert.equals("ctest", name)
            return env and env.PATH and (env.PATH .. "/ctest") or nil
        end
        vim.fn.system = function(argv)
            probed[#probed + 1] = argv[1]
            return argv[1]:find("new", 1, true) and "ctest version 3.31.2\n" or "ctest version 3.20.0\n"
        end
        local ok, err = pcall(function()
            assert.is_true(CTestUnit._output_junit_supported({ PATH = "/new" }))
            assert.is_true(CTestUnit._output_junit_supported({ PATH = "/new" }))
            assert.is_false(CTestUnit._output_junit_supported({ PATH = "/old" }))
            -- Not resolvable: older (count unknown), nothing probed.
            assert.is_false(CTestUnit._output_junit_supported(nil))
        end)
        exe.resolve, vim.fn.system = orig_resolve, orig_system
        assert(ok, err)
        assert.same({ "/new/ctest", "/old/ctest" }, probed)
    end)

    it("a requested JUnit file is the one counted", function()
        local spec = tu_for():run_command_all({ junit = "/out/r.xml", results = "/ws/.lw/tmp/x.xml" })
        assert.same({ "ctest", "--test-dir", "/b/ctestdir", "--output-on-failure", "--output-junit", "/out/r.xml" },
            spec.cmd)
        assert.equals("/out/r.xml", spec.results_out)
    end)

    it("combines --junit and forwarded args (junit first)", function()
        local spec = tu_for():run_command_all({ junit = "/o/r.xml", extra_args = { "-j", "2" } })
        assert.same(
            { "ctest", "--test-dir", "/b/ctestdir", "--output-on-failure",
              "--output-junit", "/o/r.xml", "-j", "2" },
            spec.cmd)
    end)
end)
