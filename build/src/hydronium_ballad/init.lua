--[[
  hydronium_ballad -- Ballad build plugins for Hydronium projects.

  See docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md (package boundary,
  milestones), docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md (the luax/style/assets
  plugins), and docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md (the client
  plugin) in the hydronium repo for the full design.
--]]

local M = {}

M.plugins = {
  luax = require("hydronium_ballad.plugins.luax"),
  client = require("hydronium_ballad.plugins.client"),
  topology = require("hydronium_ballad.plugins.topology"),
  style = require("hydronium_ballad.plugins.style"),
  assets = require("hydronium_ballad.plugins.assets"),
  site = require("hydronium_ballad.plugins.site"),
  -- Ingests a built Vite dist/ and re-emits it as ordinary hy_asset entries
  -- for site.manifest's merge -- see docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md
  -- M3. Belongs in a consuming app's partiture, never the root one (it would
  -- make the framework's own registry export depend on a JS build).
  vite_assets = require("hydronium_ballad.plugins.vite_assets"),
}

--- Where `source_inventory` writes. A dedicated directory: Ballad's
--- directory sink deletes its `out` before writing.
M.INVENTORY_DIR = ".hydronium/ballad"

local function load_config(config_path, caller)
  local chunk, err = loadfile(config_path)
  if not chunk then error("hydronium_ballad." .. caller .. ": cannot load " .. config_path .. ": " .. tostring(err), 3) end
  return chunk()
end

-- Ballad's `**/` needs at least one directory, so direct children get their
-- own pattern.
local function tree_patterns(dirs, exts)
  local patterns = {}
  for _, dir in ipairs(dirs) do
    for _, ext in ipairs(exts) do
      patterns[#patterns + 1] = dir .. "/*." .. ext
      patterns[#patterns + 1] = dir .. "/**/*." .. ext
    end
  end
  return patterns
end

local function project_sources(p, config)
  local roots = require("hydronium.core.source_topology").scan_roots(config)
  return p.source.files(tree_patterns(roots, { "lua", "luax" }), { root = "." })
end

--- Discovery as a Ballad node: every `.lua`/`.luax` file under the roots
--- declared in `hydronium.sources.lua`, classified into the private source
--- inventory (`.hydronium/ballad/source-inventory.{lua,json}`) that dev hosts
--- (`hydronium_dom.server.meteorite.mount`, the Ink template) read.
---
---   return ballad.partiture(function(p) require("hydronium_ballad").source_inventory(p) end)
---
--- @param p table Ballad partiture builder
--- @param opts? { config?: string, out?: string }
--- @return table sink node
function M.source_inventory(p, opts)
  opts = opts or {}
  local config_path = opts.config or "hydronium.sources.lua"
  local config = load_config(config_path, "source_inventory")
  local topology = p:use(M.plugins.topology)
  local sources = project_sources(p, config)
  local inventory = topology.inventory(sources, { config = config_path, name = "source-inventory.json" })
  return p.sink.directory(inventory, { out = opts.out or M.INVENTORY_DIR })
end

--- Where `client_bundle` writes. Dedicated, for the same reason as INVENTORY_DIR.
M.CLIENT_DIR = ".hydronium/client"

--- Framework namespaces a browser bundle may draw from.
M.FRAMEWORK_NAMESPACES = { "hydronium", "hydronium_dom", "hydronium_router", "hydronium_query", "hydronium_virtual", "hydronium_table" }

--- Production browser bundle: every client/shared module declared in
--- `hydronium.sources.lua` (compiled from LUAX, minified "safe"), plus only
--- the framework modules they -- and mount.js's bootstrap -- actually reach,
--- amalgamated into one content-hashed `package_preload_v1` chunk:
---
---   .hydronium/client/runtime-<hash>.lua
---   .hydronium/client/hydronium-manifest.{lua,json}   (lists the chunk)
---
--- `hydronium_dom.server.meteorite.mount` serves it in release builds and
--- the page boots with `chunkUrls` instead of per-module fetches.
---
--- @param p table Ballad partiture builder
--- @param opts? { config?: string, out?: string, framework_root?: string }
--- @return table sink node
function M.client_bundle(p, opts)
  opts = opts or {}
  local config_path = opts.config or "hydronium.sources.lua"
  local config = load_config(config_path, "client_bundle")
  local topology = p:use(M.plugins.topology)
  local luax = p:use(M.plugins.luax)
  local client = p:use(M.plugins.client)
  local site = p:use(M.plugins.site)

  -- The framework copy this project installed: the directory holding the
  -- `hydronium` namespace on this process's package.path.
  local framework_root = opts.framework_root
  if not framework_root then
    local init = package.searchpath("hydronium", package.path)
    if not init then error("hydronium_ballad.client_bundle: cannot locate the hydronium package on package.path", 2) end
    framework_root = init:match("^(.*)/hydronium/init%.lua$")
  end
  local framework = {}
  for _, namespace in ipairs(M.FRAMEWORK_NAMESPACES) do
    local f = io.open(framework_root .. "/" .. namespace .. "/init.lua", "r")
    if f then
      f:close()
      framework[#framework + 1] = p.source.files(tree_patterns({ namespace }, { "lua" }), { root = framework_root })
    end
  end

  local project = luax.compile(topology.classify(project_sources(p, config), { config = config_path }))
  local resolved = client.resolve(project, { project_entries = true, depends_on = framework })
  local bundled = client.bundle(client.minify(resolved, { level = "safe" }), { entry = config.entry, chunk_prefix = "" })
  return p.sink.directory(site.manifest(bundled), { out = opts.out or M.CLIENT_DIR })
end

return M
