--- A host with no published lw build (an OS/arch pair absent from
--- boot.pin.HOST_ASSETS) gets one clear message naming its platform and the
--- supported ones, from lw itself (self-update is covered by the standalone
--- suite, which has OpenSSL) and from the
--- lw.sh / lw.cmd launcher templates, which are run through sh / cmd.exe with
--- a faked host.

local pin = require("boot.pin")
local launcher = require("boot.launcher")

local SUPPORTED = "supported: linux-arm64, linux-x86_64, macos-arm64, macos-x86_64, windows-x86_64"

local function msg(platform)
    return "no lw build for " .. platform .. "; " .. SUPPORTED
end

--- The lines of `text` from the first one containing `first` up to (not
--- including) the first later one containing `stop`, joined with `sep`.
local function block(text, first, stop, sep)
    local lines, inside = {}, false
    for line in (launcher.normalize(text) .. "\n"):gmatch("([^\n]*)\n") do
        if not inside and line:find(first, 1, true) then inside = true
        elseif inside and line:find(stop, 1, true) then break end
        if inside then lines[#lines + 1] = line end
    end
    return table.concat(lines, sep)
end

describe("an unsupported host", function()
    it("gets the platform and the supported list from boot.pin", function()
        local cases = {
            { "Windows", "ARM64", "windows-arm64" },
            { "Linux", "riscv64", "linux-riscv64" },
            { "FreeBSD", "amd64", "freebsd-x86_64" },
        }
        for _, c in ipairs(cases) do
            local asset, err = pin.host_asset(c[1], c[2])
            assert.is_nil(asset, c[3])
            assert.equals(msg(c[3]), err)
        end
        assert.equals("lw-linux-x86_64", (pin.host_asset("Linux", "x86_64")))
        assert.equals("lw-macos-arm64", (pin.host_asset("Darwin", "arm64")))
        assert.equals("lw-windows-x86_64.exe", (pin.host_asset("Windows_NT", "AMD64")))
        assert.equals("lw-linux-arm64", (pin.host_asset("Linux", "aarch64")))
        assert.equals("lw-macos-x86_64", (pin.host_asset("Darwin", "x86_64")))
    end)

    it("gets it from lw.sh", function()
        if vim.fn.executable("sh") ~= 1 then
            pending("sh not available")
            return
        end
        local sel = block(launcher.LW_SH, "os=$(uname -s", "# --- read version", "\n")
        assert.truthy(sel:find('case "$os-$arch" in', 1, true), "selection block found")
        local cases = {
            { "Linux", "riscv64", "linux-riscv64" },
            { "FreeBSD", "amd64", "freebsd-x86_64" },
        }
        for _, c in ipairs(cases) do
            local script = 'uname() { case "$1" in -s) echo ' .. c[1] .. ' ;; -m) echo ' .. c[2] ..
                ' ;; esac; }\n' .. sel .. '\nprintf %s "$asset"\n'
            local r = vim.system({ "sh", "-c", script }, { text = true }):wait()
            assert.equals(1, r.code, c[3])
            assert.equals("lw: " .. msg(c[3]), vim.trim(r.stderr))
        end
        -- Every supported platform selects the asset boot.pin selects.
        for _, c in ipairs({
            { "Linux", "x86_64" }, { "Linux", "aarch64" }, { "Linux", "arm64" },
            { "Darwin", "arm64" }, { "Darwin", "x86_64" }, { "MINGW64_NT-10.0", "x86_64" },
        }) do
            local ok = vim.system({ "sh", "-c", 'uname() { case "$1" in -s) echo ' .. c[1] .. ' ;; -m) echo ' ..
                c[2] .. ' ;; esac; }\n' .. sel .. '\nprintf %s "$asset"\n' }, { text = true }):wait()
            assert.equals(0, ok.code, ok.stderr)
            assert.equals((pin.host_asset(c[1], c[2])), ok.stdout, c[1] .. "/" .. c[2])
        end
    end)

    it("gets it from lw.cmd", function()
        if vim.fn.has("win32") ~= 1 then
            pending("cmd.exe is Windows-only")
            return
        end
        local sel = block(launcher.LW_CMD, 'set "asset=lw-windows', 'set "version="', "\r\n")
        assert.truthy(sel:find("ARM64", 1, true), "selection block found")
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local bat = dir .. "/select.cmd"
        local f = assert(io.open(bat, "wb"))
        f:write("@echo off\r\nsetlocal EnableExtensions EnableDelayedExpansion\r\n" ..
            sel .. "\r\necho %asset%\r\n")
        f:close()
        local r = vim.system({ "cmd.exe", "/d", "/c", (bat:gsub("/", "\\")) },
            { text = true, env = { PROCESSOR_ARCHITECTURE = "ARM64" } }):wait()
        vim.fn.delete(dir, "rf")
        assert.equals(1, r.code)
        assert.equals("lw: " .. msg("windows-arm64"), vim.trim(r.stderr))
    end)
end)
