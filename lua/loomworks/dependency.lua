--- loomworks/dependency.lua — Dependency resolution utilities.

local M = {}

--- Topologically sort ProfileProject objects by their project dependencies.
--- Projects with no dependencies come first. Uses Kahn's algorithm.
--- @param pps loomworks.ProfileProject[]
--- @return loomworks.ProfileProject[] sorted
--- @return string|nil error message (circular dependency)
function M.toposort(pps)
    -- Build lookup: project object → ProfileProject
    local pp_by_project = {}
    local has_any_deps = false
    for _, pp in ipairs(pps) do
        if pp._project then
            pp_by_project[pp._project] = pp
            if pp._project.depends_on then
                has_any_deps = true
            end
        end
    end

    -- Fast path: no dependencies → just sort alphabetically
    if not has_any_deps then
        table.sort(pps, function(a, b) return (a._project and a._project.key or "") < (b._project and b._project.key or "") end)
        return pps, nil
    end

    -- Build adjacency and in-degree from Project.depends_on references
    local in_degree = {}
    local dependents = {} -- project → list of projects that depend on it
    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project then goto continue end
        in_degree[project] = 0
        dependents[project] = dependents[project] or {}
        ::continue::
    end

    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project or not project.depends_on then goto continue end
        for _, dep in ipairs(project.depends_on) do
            -- Only count dependencies that are in this profile's projects
            if pp_by_project[dep] then
                in_degree[project] = (in_degree[project] or 0) + 1
                dependents[dep] = dependents[dep] or {}
                dependents[dep][#dependents[dep] + 1] = project
            end
        end
        ::continue::
    end

    -- Kahn's algorithm
    local queue = {}
    for project, degree in pairs(in_degree) do
        if degree == 0 then
            queue[#queue + 1] = project
        end
    end
    -- Stable sort: alphabetical within same dependency level
    table.sort(queue, function(a, b) return a.key < b.key end)

    local sorted = {}
    while #queue > 0 do
        local project = table.remove(queue, 1)
        local pp = pp_by_project[project]
        if pp then
            sorted[#sorted + 1] = pp
        end
        for _, dependent in ipairs(dependents[project] or {}) do
            in_degree[dependent] = in_degree[dependent] - 1
            if in_degree[dependent] == 0 then
                queue[#queue + 1] = dependent
            end
        end
        -- Re-sort for stability
        table.sort(queue, function(a, b) return a.key < b.key end)
    end

    -- Append items without a project reference (shouldn't happen in practice)
    for _, pp in ipairs(pps) do
        if not pp._project then
            sorted[#sorted + 1] = pp
        end
    end

    -- Check for cycles (only among items that have projects)
    local with_project = 0
    for _, pp in ipairs(pps) do
        if pp._project then with_project = with_project + 1 end
    end
    if #sorted - (#pps - with_project) < with_project then
        -- Fall back to alphabetical on cycle
        table.sort(pps, function(a, b) return (a._project and a._project.key or "") < (b._project and b._project.key or "") end)
        return pps, "circular dependency detected"
    end

    return sorted, nil
end

--- The transitive dependencies of `roots` over the `Project.depends_on` graph
--- (the graph `toposort` orders), the roots excluded: each project reachable
--- through one or more `depends_on` edges, in first-reached order. Cycles are
--- guarded (each project is visited once; a root reached again is not
--- re-added). Profile-agnostic by intent: it walks through projects outside
--- any profile, so an in-profile project reached only via one is still found.
--- @param roots loomworks.Project[]
--- @return loomworks.Project[]
function M.closure(roots)
    local seen, out, stack = {}, {}, {}
    for _, r in ipairs(roots) do seen[r] = true end
    for i = #roots, 1, -1 do stack[#stack + 1] = roots[i] end
    while #stack > 0 do
        local p = table.remove(stack)
        local deps = p.depends_on or {}
        for i = #deps, 1, -1 do
            local d = deps[i]
            if not seen[d] then
                seen[d] = true
                out[#out + 1] = d
                stack[#stack + 1] = d
            end
        end
    end
    return out
end

return M
