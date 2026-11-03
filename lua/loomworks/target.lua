--- loomworks/target.lua — Target class.
--- Represents a discovered build target from a module (cmake target, etc.).

--- @class loomworks.Target
--- @field id string opaque target identifier (module-specific)
--- @field type string "executable"|"static_library"|"shared_library"|"module_library"|"object_library"|"interface_library"
--- @field dependencies? string[] project-owned targets this links against
--- @field artifact? string output file path (normally relative to build dir;
---   may be absolute when cmake's file-API reports an output outside it —
---   join via loomworks.paths.artifact_path, never a bare `build_dir .. artifact`)
--- @field sources? string[] absolute source file paths (for test source mapping)
--- @field _config_unit loomworks.ConfigUnit back-reference to owning unit
local Target = {}
Target.__index = Target

--- Create a new Target from raw parse data.
--- @param config_unit loomworks.ConfigUnit owning unit
--- @param id string opaque target identifier
--- @param raw { type: string, dependencies?: string[], artifact?: string, sources?: string[] }
--- @return loomworks.Target
function Target.new(config_unit, id, raw)
    local self = setmetatable({}, Target)
    self._config_unit = config_unit
    self.id = id
    self.type = raw.type
    self.dependencies = raw.dependencies
    self.artifact = raw.artifact
    self.sources = raw.sources
    return self
end

function Target:__tostring()
    return "Target(" .. self.id .. ")"
end

--- Check if this target is an executable.
--- @return boolean
function Target:is_executable()
    return self.type == "executable"
end

--- Check if this target is a library (any library type).
--- @return boolean
function Target:is_library()
    return self.type == "static_library"
        or self.type == "shared_library"
        or self.type == "module_library"
        or self.type == "object_library"
        or self.type == "interface_library"
end

--- Get a display name for this target.
--- @return string
function Target:display_name()
    return self.id
end

--- Resolve the run spec (artifact path, working directory, and run
--- environment) for this executable target. Pure — expands nothing, spawns no
--- task. A foreign artifact is refused here with the message
--- naming its platform — the headless runner routes those to a device before
--- ever asking for a local spec. Shared seam for `Target:launch` (editor) and the headless runner:
--- both resolve the same spec, then execute it via their own runner.
--- @param opts? { working_dir?: string } working_dir is a pre-resolved
---   absolute cwd override; absent → the owning project's directory.
--- @return { cmd: string, cwd: string, name: string, env: table|nil }|nil spec
--- @return string|nil err
function Target:resolve_run_spec(opts)
    opts = opts or {}
    if not self:is_executable() then
        return nil, "target '" .. tostring(self.id) .. "' is not an executable"
    end
    if not self.artifact then
        return nil, "target '" .. tostring(self.id) .. "' has no built artifact"
    end
    local unit = self._config_unit
    if not unit then
        return nil, "target '" .. tostring(self.id) .. "' has no config unit"
    end
    local build_dir = unit:build_dir()
    if not build_dir then
        return nil, "no build directory for target '" .. tostring(self.id) .. "'"
    end
    local project = unit._project
    local project_name = project and project.key or unit._init_project_key or "?"
    -- Working directory: explicit override, else the project directory
    -- (consistent with command-type launches), falling back to the build dir
    -- only if the project dir can't be resolved.
    local cwd = opts.working_dir
    if not cwd or cwd == "" then
        cwd = (project and project.abs_path and project:abs_path()) or build_dir
    end
    local artifact_path = require("loomworks.paths").artifact_path(build_dir, self.artifact)
    -- A foreign artifact never runs on the host:
    -- every local launch of a build target resolves through here.
    local host_ok, foreign_err = require("loomworks.remote.foreign").check_local(unit, artifact_path)
    if not host_ok then return nil, foreign_err end
    return {
        cmd = artifact_path,
        cwd = cwd,
        name = project_name .. ": run " .. self.id,
        env = unit:run_env(),
    }
end

return Target
