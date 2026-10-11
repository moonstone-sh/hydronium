--[[
  hydronium_ballad -- Ballad build plugins for Hydronium projects.

  See docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md (package boundary,
  milestones), docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md (the luax/style/assets
  plugins), and docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md (the client
  plugin) in the hydronium repo for the full design.
--]]

local M = {}

M.plugins = {
  lab = require("hydronium_ballad.plugins.lab"),
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
--- directory sink owns its `out` exclusively.
M.INVENTORY_DIR = ".hydronium/ballad"

local function load_config(config_path, caller)
  local chunk, err = loadfile(config_path)
  if not chunk then error("hydronium_ballad." .. caller .. ": cannot load " .. config_path .. ": " .. tostring(err), 3) end
  return chunk()
end

-- Include explicit direct-child patterns for older Ballad releases too.
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

-- Every extension a root declares a transform for (`md`/`mdx` included),
-- not a fixed lua/luax list: a root without `transforms` gets the
-- topology's own default.
local function source_extensions(config)
  local seen, exts = {}, {}
  for _, root in ipairs(config.roots or {}) do
    for ext in pairs(root.transforms or { lua = "lua", luax = "luax" }) do
      if not seen[ext] then seen[ext] = true; exts[#exts + 1] = ext end
    end
  end
  table.sort(exts)
  return exts
end

local function project_sources(p, config)
  local roots = require("hydronium.core.source_topology").scan_roots(config)
  return p.source.files(tree_patterns(roots, source_extensions(config)), { root = "." })
end

--- Discovery as a Ballad node: every source file (each extension a root
--- declares a transform for: `.lua`, `.luax`, `.md`, `.mdx`, ...) under the roots
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
  return p.sink.directory(inventory, { out = opts.out or M.INVENTORY_DIR, incremental = true })
end

--- Where `client_bundle` writes. Dedicated, for the same reason as INVENTORY_DIR.
M.CLIENT_DIR = ".hydronium/client"

--- Framework namespaces a browser bundle may draw from.
M.FRAMEWORK_NAMESPACES = { "hydronium", "hydronium_auth", "hydronium_dom", "hydronium_router", "hydronium_query", "hydronium_virtual", "hydronium_table" }

--- Framework modules the `hydronium` barrel requires eagerly that never run
--- in a production browser page: the test host, LOVE hot reload, and source
--- discovery (server and dev tooling) -- ~25 KB of Lua source. `client_bundle`
--- ships them as stubs that raise a named error if called. `hmr`,
--- `hmr_host`, `module_graph` and `family_loader` stay real: mount.js and the
--- reconciler reach them directly.
M.BROWSER_STUBS = {
  "hydronium.test",
  "hydronium.core.love_hmr",
  "hydronium.core.source_topology",
  "hydronium.core.source_inventory",
}

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
--- When `hydronium.sources.lua` lists `islands = { "components.Counter", ... }`
--- (the modules pages render through `d.lua.island`), the bundle is split
--- instead: `runtime-<hash>.lua` (framework core plus modules two islands
--- share) and `entry-<island>-<hash>.lua` per island, each recorded in the
--- manifest with its `entry`. Only modules an island reaches are bundled, so
--- server-only content never ships.
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

  -- Islands: one reachability walk per `d.lua.island` module, split into a
  -- shared runtime chunk (framework core and anything two islands reach)
  -- plus one chunk per island. A page loads the runtime and the chunks of
  -- the islands it rendered (hydronium_dom.server.client_boot); a page with
  -- no Lua islands loads nothing.
  if type(config.islands) == "table" and #config.islands > 0 then
    local sets, names = {}, {}
    for index, id in ipairs(config.islands) do
      if type(id) ~= "string" then error("hydronium_ballad.client_bundle: islands[" .. index .. "] must be a module id", 2) end
      sets[index] = client.minify(client.resolve(project, { entries = { id }, depends_on = framework, stub = M.BROWSER_STUBS }), { level = "safe" })
      names[index] = id
    end
    local rest = {}
    for index = 2, #sets do rest[#rest + 1] = sets[index] end
    local bundled = client.bundle(sets[1], {
      split = "entry", entry_names = names, chunk_prefix = "", depends_on = #rest > 0 and rest or nil,
    })
    return p.sink.directory(site.manifest(bundled), { out = opts.out or M.CLIENT_DIR })
  end

  local resolved = client.resolve(project, { project_entries = true, depends_on = framework, stub = M.BROWSER_STUBS })
  local bundled = client.bundle(client.minify(resolved, { level = "safe" }), { entry = config.entry, chunk_prefix = "" })
  return p.sink.directory(site.manifest(bundled), { out = opts.out or M.CLIENT_DIR, incremental = true })
end

return M
