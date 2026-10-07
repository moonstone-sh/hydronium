--[[
  hydronium_dom.server.client_boot -- the browser resources a page's Lua
  islands need, decided at render time from the page's own client plan.

  Place `<ClientBoot />` after the page content (end of <body>): by then every
  `d.lua.island` has been rendered and recorded in the plan. It emits
  nothing for a page without Lua islands -- that page never starts a Lua
  engine. Otherwise, in a release build with a split Ballad bundle
  (`islands` in hydronium.sources.lua), it emits:

    - <link rel="modulepreload"> for islands.js and its two static imports,
    - when some island hydrates on "load": modulepreloads for the VM boot
      path (mount.js imports it once an island triggers), and low-priority
      <link rel="preload"> for engine.wasm and the chunks those islands need
      (idle/visible islands fetch theirs when they start),
    - <script id="__HYDRONIUM_BOOT__" type="application/json"> with the chunk
      URLs in load order (shared runtime first, then each island's chunk),
      read by /js/bootstrap/islands.js.

  Without a bundle (development) only the island list matters; islands.js
  then loads modules from the live dev manifest.

  A single-chunk bundle (no `islands` list) is loaded whole, as before.
--]]

local server = require("hydronium_dom.server")
local json = require("hydronium_dom.server.json")

local M = {}

-- Must match hydronium_dom.server.meteorite_routes (not required here: that
-- module loads the dev source registry, which a page render does not need).
M.CLIENT_DIR = ".hydronium/client"
M.CLIENT_URL = "/__hydronium/client"
M.BOOTSTRAP_URL = "/js/bootstrap"

-- islands.js and its static imports: what any page with Lua islands loads.
M.ISLAND_MODULES = { "islands.js", "priority.js", "boundary_registry.js" }
-- The VM boot path islands.js imports when the first island triggers,
-- plus the engine's own modules.
M.BOOT_MODULES = {
  "mount.js", "dom_bridge.js", "canvas_bridge.js", "host_capabilities.js", "engine_provider.js",
  "vendor/lua-wasm/5.4.9/engine.js", "vendor/lua-wasm/5.4.9/task-runtime.mjs",
}
-- Both, in load order (kept for callers that preload everything).
M.BOOTSTRAP_MODULES = {}
for _, list in ipairs({ M.ISLAND_MODULES, M.BOOT_MODULES }) do
  for _, path in ipairs(list) do M.BOOTSTRAP_MODULES[#M.BOOTSTRAP_MODULES + 1] = path end
end
M.ENGINE_WASM = "vendor/lua-wasm/5.4.9/engine.wasm"

local graph_cache

--- Chunk graph of the built bundle: `shared` URLs every island page loads and
--- `entries[module_id]` URLs per island. nil when no bundle was built.
--- @return { shared: string[], entries: table<string, string[]> }|nil
function M.chunk_graph()
  if graph_cache ~= nil then return graph_cache or nil end
  graph_cache = false
  local chunk = loadfile(M.CLIENT_DIR .. "/hydronium-manifest.lua")
  if not chunk then return nil end
  local ok, site = pcall(chunk)
  if not ok or type(site) ~= "table" or type(site.chunks) ~= "table" or #site.chunks == 0 then return nil end
  local graph = { shared = {}, entries = {} }
  for _, record in ipairs(site.chunks) do
    local url = M.CLIENT_URL .. record.url
    -- A single-chunk bundle records its root entry but serves every page.
    if record.entry == nil or #site.chunks == 1 then
      graph.shared[#graph.shared + 1] = url
    else
      local list = graph.entries[record.entry] or {}
      list[#list + 1] = url
      graph.entries[record.entry] = list
    end
  end
  graph_cache = graph
  return graph
end

--- Test seam: forget the cached manifest.
function M.reset()
  graph_cache = nil
end

--- Lua islands the browser hydrates itself (root mounts boot through mount.js).
--- @param plan table|nil
--- @return table[]
function M.lua_islands(plan)
  local out = {}
  for _, island in ipairs(plan and plan.islands or {}) do
    if island.interpreter == "lua" and not island.root then out[#out + 1] = island end
  end
  return out
end

--- Chunk URLs for these island modules, shared runtime first.
--- @param modules string[]
--- @return string[]
function M.chunks_for(modules)
  local graph = M.chunk_graph()
  if not graph then return {} end
  local urls, seen = {}, {}
  local function add(url)
    if not seen[url] then seen[url] = true; urls[#urls + 1] = url end
  end
  for _, url in ipairs(graph.shared) do add(url) end
  for _, id in ipairs(modules) do
    for _, url in ipairs(graph.entries[id] or {}) do add(url) end
  end
  return urls
end

--- @param props? { bootstrap_url?: string, bundle?: boolean }
---   `bundle = false` in development: a bundle left on disk by an earlier
---   release build is not what the dev server serves (it serves modules), and
---   request handlers cannot see Meteorite's build mode themselves.
function M.ClientBoot(props)
  props = props or {}
  local islands = M.lua_islands(server.current_client_plan())
  if #islands == 0 then return nil end
  local modules, eager_modules, seen = {}, {}, {}
  for _, island in ipairs(islands) do
    if type(island.module) == "string" and not seen[island.module] then
      seen[island.module] = true
      modules[#modules + 1] = island.module
    end
    if type(island.module) == "string" and (island.hydrate == nil or island.hydrate == "load") then
      eager_modules[#eager_modules + 1] = island.module
    end
  end
  local chunks = props.bundle ~= false and M.chunks_for(modules) or {}
  if #chunks == 0 then return nil end

  local d = require("hydronium_dom").d
  local base = (props.bootstrap_url or M.BOOTSTRAP_URL):gsub("/+$", "")
  local out = {}
  -- islands.js runs on every page with Lua islands; preloading its two
  -- imports saves a request round trip at no bandwidth cost.
  for _, path in ipairs(M.ISLAND_MODULES) do
    out[#out + 1] = d.link({ rel = "modulepreload", href = base .. "/" .. path })
  end
  -- The engine and chunks only for islands that hydrate on load: islands that
  -- wait for idle or visibility start the VM later, so fetching their code up
  -- front would spend bandwidth the first paint and the reader may never need.
  if #eager_modules > 0 then
    for _, path in ipairs(M.BOOT_MODULES) do
      out[#out + 1] = d.link({ rel = "modulepreload", href = base .. "/" .. path })
    end
    out[#out + 1] = d.link({ rel = "preload", href = base .. "/" .. M.ENGINE_WASM, as = "fetch",
      type = "application/wasm", crossorigin = "anonymous", fetchpriority = "low" })
    for _, url in ipairs(M.chunks_for(eager_modules)) do
      out[#out + 1] = d.link({ rel = "preload", href = url, as = "fetch", crossorigin = "anonymous", fetchpriority = "low" })
    end
  end
  out[#out + 1] = d.script({ id = "__HYDRONIUM_BOOT__", type = "application/json" },
    json.encode({ chunks = chunks, hmr = false }))
  local element = require("hydronium.core.element")
  return element.h(element.Fragment, nil, out)
end

return M
