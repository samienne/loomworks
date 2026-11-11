--- loomworks/run_prep.lua — the preparation of `lw run`, shared by the
--- in-process host (cli.lua `cmd_run`) and the workspace daemon
--- (daemon/runner.lua, `prepare_run`): launch-target
--- enumeration and selection, the validity gate, the foreign-artifact probe,
--- the launch-spec resolution and the launch's environment contribution; and
--- the debug-spec resolution the editor's debug paths consume.
---
--- Host-neutral: nothing here prints or exits. Every refusal is returned as
--- the text `lw` prints (after its `lw: ` prefix), so both runners report a
--- run identically. Only executing the resolved spec is the host's.

local M = {}

local function build_run() return require("loomworks.build_run") end

--- @class loomworks.RunCandidate
--- @field kind "launch"|"target"|"device" ("device" only in M.target_listing)
--- @field project loomworks.Project
--- @field name string the display name the operand is matched against (kind "device": the device target's id)
--- @field target_id? string the module target id (kind "target")
--- @field launch? loomworks.LaunchConfiguration the launch configuration (kind "launch")
--- @field device_target? string the device target's id (kind "device")
--- @field label? string the device target's display name (kind "device")
--- @field default? boolean the profile's default target (M.target_listing only)

--- Enumerate the launchable targets of a profile: command / target-backed
--- launch configurations and executable build targets across the profile's
--- projects, launch configurations first, each group sorted. Parses targets
--- on demand (build first), unless `opts.parse == false`: then only the
--- targets the units already know.
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @param opts? { parse?: boolean }
--- @return loomworks.RunCandidate[]
function M.launchable_targets(ws, profile, opts)
    local list = {}
    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        local project = unit and unit._project
        if project then
            for _, launch in ipairs(project:launch_configs()) do
                if launch:is_runnable() then
                    list[#list + 1] = { kind = "launch", project = project, name = launch.name, launch = launch }
                end
            end
            if not (opts and opts.parse == false) then build_run().ensure_unit_targets(ws, unit) end
            if type(unit.targets) == "table" then
                local ids = {}
                for id in pairs(unit.targets) do ids[#ids + 1] = id end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    local t = unit.targets[id]
                    if t and t.is_executable and t:is_executable() then
                        local dname = (t.display_name and t:display_name()) or id
                        list[#list + 1] = { kind = "target", project = project, name = dname, target_id = id }
                    end
                end
            end
        end
    end
    return list
end

--- The device targets a profile's project offers (its module's
--- `device_targets` for the configuration the profile maps it to), as
--- candidates of kind "device" (`name` the device target's id).
--- @param ws loomworks.Workspace
--- @param pp loomworks.ProfileProject
--- @return loomworks.RunCandidate[]
local function device_candidates(ws, pp)
    local unit = pp._config_unit
    local project = pp._project
    local mod = project and project._module and project._module.impl
    local config_name = pp._configuration and pp._configuration.name
    if not (mod and mod.has_devices and mod.device_targets and config_name) then return {} end
    local ok, tgts = pcall(mod.device_targets, {
        name = project.key,
        path = project.path or project.key,
        workspace_root = ws.root or "",
        tool_data = unit and unit._tool_data or {},
        configurations = project._configurations,
    }, config_name)
    local out = {}
    for _, dt in ipairs(ok and type(tgts) == "table" and tgts or {}) do
        out[#out + 1] = { kind = "device", project = project, name = dt.id, label = dt.label or dt.id,
            device_target = dt.id }
    end
    return out
end

--- Does candidate `c` match a profile's stored default-target descriptor?
--- By (project, target id) for a build target, (project, name) for a launch
--- configuration, (project, device target id) for a device target.
--- @param desc table|nil the profile's `_default_target_descriptor`
--- @param c loomworks.RunCandidate
--- @return boolean
function M.is_stored_default(desc, c)
    if not desc or desc.project ~= c.project.key then return false end
    if desc.target then return c.kind == "target" and c.target_id == desc.target end
    if desc.launch then return c.kind == "launch" and c.name == desc.launch end
    if desc.device_target then return c.kind == "device" and c.device_target == desc.device_target end
    return false
end

--- @class loomworks.TargetListing
--- @field targets loomworks.RunCandidate[] per project in the profile's order: its launch
---   configurations, its executable build targets, its device targets; each with `default`
--- @field incomplete string[] keys of the projects whose build targets are unknown (not configured)
--- @field override boolean the profile stores a default-target choice

--- A profile's launchable targets as the target listing shows them: every
--- launch configuration, executable build target
--- and device target, the profile's default target marked — the stored
--- choice only, never guessed — and the projects whose build targets are
--- unknown because they are not configured. Parses targets a unit does not know yet, never
--- builds; with `opts.parse == false` (a long-lived daemon, which parses off
--- its model queue first: M.stale_target_units) only the known targets.
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @param opts? { parse?: boolean }
--- @return loomworks.TargetListing
function M.target_listing(ws, profile, opts)
    local runnable = M.launchable_targets(ws, profile, opts)
    local targets, incomplete = {}, {}
    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        local project = unit and unit._project or pp._project
        if project then
            for _, c in ipairs(runnable) do
                if c.project == project then targets[#targets + 1] = c end
            end
            for _, c in ipairs(device_candidates(ws, pp)) do targets[#targets + 1] = c end
            local mod = project._module and project._module.impl
            if unit and mod and mod.parse_targets then
                local st = unit:local_state()
                if st ~= "configured" and st ~= "built" then incomplete[#incomplete + 1] = project.key end
            end
        end
    end
    table.sort(incomplete)
    local desc = profile._default_target_descriptor
    for _, c in ipairs(targets) do
        c.default = desc ~= nil and M.is_stored_default(desc, c)
    end
    return { targets = targets, incomplete = incomplete, override = desc ~= nil }
end

--- The configuration units of a profile whose build targets are due a parse
--- (ConfigUnit:targets_stale: unknown, or set before the unit's last
--- configure or build), each once.
--- @param profile loomworks.Profile
--- @return loomworks.ConfigUnit[]
function M.stale_target_units(profile)
    local out, seen = {}, {}
    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        if unit and not seen[unit] and unit:targets_stale() then
            seen[unit] = true
            out[#out + 1] = unit
        end
    end
    return out
end

--- A candidate for messages: `project:name (kind)`.
--- @param c loomworks.RunCandidate
--- @return string
function M.fmt_cand(c)
    return c.project.key .. ":" .. c.name .. " (" .. c.kind .. ")"
end

--- The LaunchTarget of a candidate.
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @param c loomworks.RunCandidate
--- @return loomworks.LaunchTarget
function M.candidate_launch_target(ws, profile, c)
    local descriptor = { project = c.project.key }
    if c.kind == "target" then descriptor.target = c.target_id else descriptor.launch = c.name end
    return require("loomworks.launch_target").new(ws, profile, descriptor)
end

--- Match a run operand `name` against a profile's launchable targets,
--- honoring an explicit `--project` scope, a `project:name` prefix (only when
--- the prefix is a project of this profile — target ids may contain ':'), and
--- a `--target` / `--launch` kind filter. Returns the matching candidates (0 =
--- none, 1 = unique, >1 = ambiguous) and the full candidate list (`all`,
--- default `launchable_targets`, injectable for tests).
--- @return loomworks.RunCandidate[] matches, loomworks.RunCandidate[] all
function M.match_targets(ws, profile, name, proj_scope, kind, all)
    local scope, bare = proj_scope, name
    if not scope then
        local qproj, rest = build_run().split_target_ref(profile, name)
        if qproj then scope, bare = qproj.key, rest end
    end
    all = all or M.launchable_targets(ws, profile)
    local matches = {}
    for _, c in ipairs(all) do
        -- (`scope` a Project — an interface call's id resolved to it — is
        -- matched by identity; a string is the key the user typed.)
        local in_scope = not scope or (type(scope) == "table" and c.project == scope)
            or (type(scope) ~= "table" and c.project.key == scope)
        if c.name == bare and in_scope
            and (not kind or c.kind == kind) then matches[#matches + 1] = c end
    end
    return matches, all
end

--- Resolve the launch target of a run against the configured tree (a run
--- resolves before it builds, headless §16.17 "Order"): the named
--- target (`name`), else the profile's
--- stored default target (M.no_default_refusal). Returns the LaunchTarget, or
--- nil + the refusal (no such target, ambiguous, no default set).
--- `opts.refresh` re-reads every unit's targets first (a long-lived daemon
--- whose units outlived a build).
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @param name string|nil
--- @param proj_scope string|loomworks.Project|nil `--project` (a key), or the
---   Project an interface call's id resolved to
--- @param kind "target"|"launch"|nil `--target` / `--launch`
--- @param opts? { refresh?: boolean }
--- @return loomworks.LaunchTarget|nil lt, string|nil err
--- @return "missing"|nil why `"missing"`: a named target matched nothing (the
---   case a host retries once after reconfiguring `reconfigure_units`)
function M.select(ws, profile, name, proj_scope, kind, opts)
    if opts and opts.refresh then
        for _, pp in ipairs(profile:projects()) do
            build_run().ensure_unit_targets(ws, pp._config_unit, { refresh = true })
        end
    end
    if name then
        local matches, all = M.match_targets(ws, profile, name, proj_scope, kind)
        if #matches == 0 then
            local labels = {}
            for _, c in ipairs(all) do labels[#labels + 1] = M.fmt_cand(c) end
            return nil, "no launch target '" .. name .. "' in profile '" .. profile.key .. "'.\n" ..
                "  available: " .. (next(labels) and table.concat(labels, ", ") or "(none)") .. "\n" ..
                "  a target on a different profile: lw run <profile> <target>", "missing"
        elseif #matches > 1 then
            local labels = {}
            for _, c in ipairs(matches) do labels[#labels + 1] = M.fmt_cand(c) end
            return nil, "'" .. name .. "' is ambiguous: " .. table.concat(labels, ", ") ..
                "\n  qualify with `--target`/`--launch`, `--project <key>`, or `<project>:<name>`."
        end
        return M.candidate_launch_target(ws, profile, matches[1])
    end
    -- No name → the profile's stored default target; none is never guessed
    -- (not even a sole launchable target, headless §16.17).
    local refusal = M.no_default_refusal(profile)
    if refusal then return nil, refusal end
    for _, pp in ipairs(profile:projects()) do build_run().ensure_unit_targets(ws, pp._config_unit) end
    return profile:default_target()
end

--- The refusal of a run naming no target on a profile with no default
--- target set, else nil. The stored default is known without configuring
--- (Profile:default_target reads the descriptor only), so both hosts check
--- it before a run's configure phase (headless §16.17 "Order"): nothing is
--- configured or built. The message names both fixes.
--- @param profile loomworks.Profile
--- @return string|nil
function M.no_default_refusal(profile)
    if profile:default_target() then return nil end
    local key = profile.key
    return "no default target set for profile '" .. key .. "'.\n" ..
        "  name one:     lw run " .. key .. " <target>\n" ..
        "  or set one:   lw target set " .. key .. " <target>\n" ..
        "  list them:    lw target list " .. key
end

--- The configuration units a run reconfigures once when its NAMED target is
--- not in the configured tree (headless §16.17 "Order"): a target added to
--- the build files since the last configure is known only once they are
--- regenerated. The unit of the project the name is scoped to (`--project`,
--- an interface call's Project, or `<project>:<name>`), else every unit of
--- the profile — less the units in `skip` (those the run's configure phase
--- just configured: already fresh). Module-neutral: the host re-runs the
--- module's normal configure step on them, never a full (wiping)
--- reconfigure (`build_run.plan{ units, configure_only }`, no `reconfigure`).
--- @param profile loomworks.Profile
--- @param name string the named target (as typed)
--- @param proj_scope string|loomworks.Project|nil
--- @param skip? table<loomworks.ConfigUnit, true>
--- @return loomworks.ConfigUnit[]
function M.reconfigure_units(profile, name, proj_scope, skip)
    local scope = proj_scope
    if not scope then
        local qproj = build_run().split_target_ref(profile, name)
        if qproj then scope = qproj.key end
    end
    local units = {}
    for _, pp in ipairs(profile:projects()) do
        local p = pp._project
        local in_scope = not scope or (type(scope) == "table" and p == scope)
            or (type(scope) ~= "table" and p and p.key == scope)
        local u = pp._config_unit
        if in_scope and u and not (skip and skip[u]) then units[#units + 1] = u end
    end
    return units
end

--- The configuration units the configure steps of `steps` configure (a
--- run's configure phase), as a set for `reconfigure_units`' `skip`.
--- @param steps? table[] planned steps ({ kind, unit, ... })
--- @return table<loomworks.ConfigUnit, true>
function M.configured_units(steps)
    local set = {}
    for _, step in ipairs(steps or {}) do
        if step.kind == "configure" and step.unit then set[step.unit] = true end
    end
    return set
end

--- What a run builds for its resolved launch target `lt` (headless §16.17
--- "Order"), as `build_run.plan`'s `build_targets_for`: the target's own
--- project for that one build target, and each project it depends on
--- (`build_dependencies`, then their `depends_on` transitively —
--- `dependency.closure`) that is in `profile`, whole. nil — the whole
--- profile — for a launch that names no build target (a command launch
--- configuration) or whose target does not resolve.
--- @param profile loomworks.Profile
--- @param lt loomworks.LaunchTarget
--- @return table<loomworks.Project, string[]>|nil
function M.build_picks(profile, lt)
    if lt._launch and not lt._launch.target then return nil end
    local target = lt._launch and lt._config_target or lt._target
    local project = lt._project
    if not (target and target.id and project) then return nil end
    local picks = { [project] = { target.id } }
    local direct = {}
    for _, dep in ipairs(lt.build_dependencies and lt:build_dependencies() or {}) do
        if dep.project then direct[#direct + 1] = dep.project end
    end
    -- The direct dependencies and everything they depend on in turn
    -- (App -> Lib -> Core builds Core too); cycles are guarded.
    local all = vim.list_extend(vim.list_extend({}, direct),
        require("loomworks.dependency").closure(direct))
    for _, p in ipairs(all) do
        if not picks[p] and profile:project(p.key) then picks[p] = {} end
    end
    return picks
end

--- The validity gate of a launch target (stale descriptor, invalid profile or
--- configuration): nil when runnable, else the refusal.
--- @param lt loomworks.LaunchTarget
--- @return string|nil
function M.validity_error(lt)
    local ok, reasons = lt:is_valid()
    if ok then return nil end
    return "launch target is not runnable: " ..
        table.concat(type(reasons) == "table" and reasons or { "invalid" }, "; ")
end

--- The foreign-artifact classification of a launch target's build-target
--- artifact, or nil: a module target or a target-backed launch
--- configuration whose artifact is foreign. Command launches are never probed.
--- @param lt loomworks.LaunchTarget
--- @return loomworks.ForeignArtifact|nil
function M.foreign_of(lt)
    local target = lt._launch and lt._config_target or lt._target
    if lt._launch and not lt._launch.target then return nil end
    if not (target and target.artifact) then return nil end
    local unit = target._config_unit or lt._config_unit
    local bd = unit and unit.build_dir and unit:build_dir()
    if not bd then return nil end
    local artifact = require("loomworks.paths").artifact_path(bd, target.artifact)
    local f = require("loomworks.remote.foreign").classify(unit, artifact)
    if f then f.target = target end
    return f
end

--- The execution platform of the first unit of `profile` that builds with a
--- foreign (cross) kit (known before anything is built), or nil.
--- @param profile loomworks.Profile
--- @return string|nil
function M.kit_platform(profile)
    for _, pp in ipairs(profile:projects()) do
        local token = require("loomworks.remote.foreign").unit_platform(pp._config_unit)
        if token then return token end
    end
    return nil
end

--- Resolve the launch spec of a (deployed) launch target: the command, its
--- arguments (a command configuration's declared ones, then `extra_args`),
--- cwd and environment, expanded in the current process environment. nil +
--- the refusal (`cannot resolve launch: …`) when it does not resolve.
--- @param lt loomworks.LaunchTarget
--- @param opts { extra_args?: string[], cwd_override?: string }
--- @return { name: string, cmd: string, args: string[], cwd: string|nil, env: table|nil }|nil spec
--- @return string|nil err
function M.resolve_spec(lt, opts)
    local spec, serr = lt:resolve_launch_spec({
        extra_args = opts.extra_args, working_dir = opts.cwd_override })
    -- An unresolved build-target artifact reports its reason and exits
    -- non-zero — reported, never guessed.
    if not spec then return nil, "cannot resolve launch: " .. tostring(serr) end
    return spec
end

--- @class loomworks.DebugSpecAdapter
--- @field language string
--- @field adapter string|nil the resolved DAP adapter type (nil: no mapping)

--- @class loomworks.DebugSpec
--- @field name string session name
--- @field program string|nil the executable: the run's resolved `cmd` (M.debug_spec)
--- @field args string[]|nil
--- @field cwd string|nil
--- @field env table<string, string>|nil the launch's own contribution over the host's (or, from
---   `prepare_debug`, the client's) environment, as the run's (M.env_overrides)
--- @field language string the first debug language: a launch configuration's first `debug`
---   entry, else the module's primary language
--- @field adapters loomworks.DebugSpecAdapter[] ordered; the first launches, the rest attach to its pid

--- The `adapters` of a launch configuration: its `debug` languages in order,
--- else the module's primary language `lang`. `resolve(language)`: the
--- mapping to resolve each from (default: the workspace's, debug_config).
local function config_adapters(ws, cfg, lang, resolve)
    local debug_config = require("loomworks.debug_config")
    resolve = resolve or function(language) return debug_config.resolve_adapter(ws, language) end
    local adapters = {}
    if type(cfg.debug) == "table" then
        for _, entry in ipairs(cfg.debug) do
            local language = type(entry) == "string" and entry or entry.language
            adapters[#adapters + 1] = {
                language = language, adapter = resolve(language) }
        end
    end
    if #adapters == 0 then
        adapters[1] = { language = lang, adapter = resolve(lang) }
    end
    return adapters
end

--- The primary language of a launch target's module (else "c++", as the
--- editor's debug paths default).
--- @param lt loomworks.LaunchTarget
--- @return string
local function module_language(lt)
    local project = lt._project
    if not project and lt._target and lt._target._config_unit then project = lt._target._config_unit._project end
    return project and project._module and project._module:primary_language() or "c++"
end

--- The debug spec `Launch/1.prepare_debug` ends with
--- (`loomworks.Common/1` `DebugSpec`): the run's resolved launch of the same
--- target and arguments — `launch` as `prepare_run` returns it (`env` already
--- reduced to the launch's own contribution) — with `program` the run's
--- `cmd`, then the launch's debug languages: `language` a launch
--- configuration's first `debug` entry, otherwise the primary language of the
--- target's module; `adapters` one `{ language, adapter }` per debug language
--- in order (a configuration's `debug` array, else `language` alone), each
--- resolved from the workspace's mapping with its default (debug_config).
--- @param ws loomworks.Workspace
--- @param lt loomworks.LaunchTarget
--- @param launch { name?: string, cmd: string, args: string[], cwd: string, env: table<string,string> }
--- @return loomworks.DebugSpec
function M.debug_spec(ws, lt, launch)
    local lang = module_language(lt)
    local adapters
    if lt._launch then
        adapters = config_adapters(ws, lt._launch, lang)
    else
        adapters = { { language = lang, adapter = require("loomworks.debug_config").resolve_adapter(ws, lang) } }
    end
    return {
        name = launch.name, program = launch.cmd, args = launch.args or {}, cwd = launch.cwd,
        -- (An empty env is still a JSON object, Common/1 `env: object`.)
        env = (launch.env and next(launch.env)) and launch.env or vim.empty_dict(),
        language = adapters[1].language, adapters = adapters,
    }
end

--- Why a launch target cannot be debugged on this host (there is no device
--- debug), or nil: a device target, or a
--- build-target artifact found foreign — by its kit's platform token, or (not
--- `by_kit_only`) by probing the artifact. The refusal is the in-process one
--- of debugging a foreign target (remote.foreign.refusal). `by_kit_only`:
--- before the build, when only the kit can tell (an artifact not yet rebuilt
--- is not probed).
--- @param lt loomworks.LaunchTarget
--- @param by_kit_only? boolean
--- @return string|nil
function M.debug_refusal(lt, by_kit_only)
    if lt:requires_device() then
        return "'" .. lt:display_name() .. "' is a device target; this host cannot debug it. "
            .. "Debugging on a device is not supported."
    end
    local f = M.foreign_of(lt)
    if f and (not by_kit_only or f.reason == "token") then
        return require("loomworks.remote.foreign").refusal(f)
    end
    return nil
end

--- Resolve the debug spec of a launch target. One spec for run and debug: the
--- program, arguments, working directory and environment are the run's of the
--- same target (LaunchTarget:resolve_launch_spec — a module target's
--- working-directory precedence and run environment, a launch
--- configuration's args / env / working_dir, the env denylist), `env`
--- reduced to the launch's own contribution (M.env_overrides), shaped by
--- M.debug_spec exactly as `Launch/1.prepare_debug` returns it.
--- Adapter-agnostic: availability and the adapter-specific transform are the
--- debugging client's. Host-neutral: no output of its own, but a
--- launch configuration's env goes through `env_policy.filter`, which
--- schedules a warning through the host's notifier (`loomworks.notify`;
--- once per variable) when it refuses a denylisted variable.
---
--- nil when there is nothing to debug (neither a launch configuration nor an
--- executable target with an artifact); with a reason and its severity when
--- the target cannot be debugged: "error" for a launch configuration or a
--- foreign artifact, "warn" for a module target that does not
--- resolve otherwise (no build directory, ...).
--- @param lt loomworks.LaunchTarget
--- @return loomworks.DebugSpec|nil spec
--- @return string|nil err
--- @return "warn"|"error"|nil severity
function M.resolve_debug(lt)
    local ws = lt._workspace
    if not lt._launch then
        local target = lt._target
        if not (target and target:is_executable() and target.artifact) then return nil end
    end
    local spec, err = lt:resolve_launch_spec()
    if not spec then
        local severity = "error"
        if not lt._launch and not M.foreign_of(lt) then severity = "warn" end
        return nil, "cannot debug: " .. tostring(err), severity
    end
    return M.debug_spec(ws, lt, {
        name = spec.name, cmd = spec.cmd, args = spec.args or {}, cwd = spec.cwd or ws.root,
        env = M.env_overrides(spec.env),
    })
end

--- The launch-contributed environment OVERRIDES: entries of the resolved run
--- environment whose value differs from the current process environment. A
--- command launch config's env is already just its declared vars; a
--- build-target / target-backed launch resolves a FULL env (inherited + a
--- PATH prepend), so diffing against the inherited env reduces it to exactly
--- the launch's contribution — never the whole inherited environment. In the
--- daemon the process environment is the requesting client's
--- (loomworks.daemon.envscope), so this is the contribution over the client's
--- environment.
--- @param env table<string,string>|nil
--- @return table<string,string>
function M.env_overrides(env)
    if not env then return {} end
    local inherited = {}
    local ok, cur = pcall(function() return vim.fn.environ() end)
    if ok and type(cur) == "table" then inherited = cur end
    local ov = {}
    for k, v in pairs(env) do
        if inherited[k] ~= v then ov[k] = v end
    end
    return ov
end

return M
