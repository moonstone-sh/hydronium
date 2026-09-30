--[[
  Shared state for the Meteorite routes `hydronium_dom.server.meteorite.mount`
  registers. Each sibling module is a Meteorite `lua_file` handler: Meteorite
  `loadfile`s it by path per request VM, so none of them can close over
  anything `mount` saw at graph time. Everything they need is re-derived here
  from project-root conventions instead.

  Source authority: hydronium_dom.dev.source_registry.load_project (Ballad
  inventory, then the legacy Vite discovery file, then hydronium.sources.lua).
--]]

local M = {}

local source_registry = require("hydronium_dom.dev.source_registry")
M.PROJECT_SOURCES = source_registry.PROJECT_SOURCES
M.DISCOVERED_SOURCES = source_registry.DISCOVERED_SOURCES
M.BALLAD_INVENTORY = source_registry.BALLAD_INVENTORY

local function exists(path)
  local file = io.open(path, "r")
  if not file then return false end
  file:close()
  return true
end
M.exists = exists

--- @return table registry hydronium_dom.dev.source_registry instance
function M.registry()
  return source_registry.load_project()
end

--- Every file whose change the browser must hear about: declared modules,
--- the topology declaration itself, and the optional top-level `watch` list
--- (stylesheets and other non-module files) from `hydronium.sources.lua`.
--- @param registry table
--- @return string[]
function M.watch_files(registry)
  local extra = {}
  if exists(M.PROJECT_SOURCES) then extra[#extra + 1] = M.PROJECT_SOURCES end
  for _, entry in ipairs(registry.watch) do extra[#extra + 1] = entry.path end
  return registry:watch_files(extra)
end

--- Public module manifest. `hmr = false` tells the page not to open the HMR
--- stream: release builds serve modules but no /__hydronium/watch.
--- @param hmr boolean
function M.browser_manifest(hmr)
  local manifest = M.registry():browser_manifest()
  manifest.hmr = hmr
  -- Release builds boot from the Ballad bundle when one was built
  -- (hydronium_ballad.client_bundle): the page passes these as chunkUrls.
  if not hmr then manifest.chunks = M.client_chunks() end
  return manifest
end

--- Directory and URL prefix of the production browser bundle.
M.CLIENT_DIR = ".hydronium/client"
M.CLIENT_URL = "/__hydronium/client"

--- Chunk URLs from the bundle's site manifest, or nil when none was built.
--- @return string[]|nil
function M.client_chunks()
  local chunk = loadfile(M.CLIENT_DIR .. "/hydronium-manifest.lua")
  if not chunk then return nil end
  local ok, site = pcall(chunk)
  if not ok or type(site) ~= "table" or type(site.chunks) ~= "table" or #site.chunks == 0 then return nil end
  local urls = {}
  for index, entry in ipairs(site.chunks) do urls[index] = M.CLIENT_URL .. entry.url end
  return urls
end

return M
