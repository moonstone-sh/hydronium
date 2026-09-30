--[[
  Framework module manifest for the unbundled (development) browser VM.

  mount.js fetches `{ module_id = relative_path }` and preloads each file from
  `/hydronium-src/<relative_path>`. This computes that map from the real,
  literal `require("...")` graph (hydronium.core.require_scan) instead of a
  pasted JSON file that drifts whenever core gains a module, resolved through
  package.path so it describes exactly the framework copy the server has
  installed.

  The walk starts from the modules the client runtime JS requires itself plus
  every literal require in the project's client/shared modules. Only
  framework namespaces are emitted; project modules are served separately by
  /__hydronium/dev/module/:id. Ids that do not resolve are skipped, as a
  guarded optional require in the runtime must not fail the manifest.
--]]

local M = {}

--- Namespaces served by /hydronium-src and eligible for the manifest.
M.NAMESPACES = {
  hydronium = true,
  hydronium_dom = true,
  hydronium_router = true,
  hydronium_query = true,
  hydronium_virtual = true,
  hydronium_table = true,
}

--- Lua modules the browser runtime JS (mount.js, hmr.js, router history)
--- requires directly.
M.RUNTIME_ENTRIES = {
  "hydronium.core.element",
  "hydronium.core.family_loader",
  "hydronium.core.hmr_host",
  "hydronium.core.module_graph",
  "hydronium.core.reconciler",
  "hydronium.runtime.hosts",
  "hydronium_dom",
  "hydronium_dom.host.dom",
  "hydronium_router.history.browser",
  "hydronium_router.history.hash",
}

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Resolve a framework module id to its file and its path relative to the
--- namespace's parent directory (what /hydronium-src serves).
local function resolve(id)
  local namespace = id:match("^([%w_]+)")
  if not M.NAMESPACES[namespace] then return nil end
  local path = package.searchpath(id, package.path)
  if not path then return nil end
  local relative = id:gsub("%.", "/")
  for _, candidate in ipairs({ relative .. ".lua", relative .. "/init.lua" }) do
    if path:sub(-#candidate) == candidate then return path, candidate end
  end
  return nil
end

--- @param seeds? string[] extra module ids
--- @param project_sources? string[] Lua source texts whose requires seed the walk
--- @return table<string,string> manifest module id -> relative path
function M.build(seeds, project_sources)
  local start = {}
  for _, id in ipairs(M.RUNTIME_ENTRIES) do start[#start + 1] = id end
  for _, id in ipairs(seeds or {}) do start[#start + 1] = id end
  local relatives = {}
  local order = require("hydronium.core.require_scan").closure(start, function(id)
    local path, relative = resolve(id)
    local source = path and read(path)
    if source then relatives[id] = relative end
    return source
  end, project_sources)
  local manifest = {}
  for _, id in ipairs(order) do manifest[id] = relatives[id] end
  return manifest
end

return M
