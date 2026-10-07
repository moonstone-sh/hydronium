--[[
  hydronium_dom.server.client_boot -- the browser resources a page's Lua
  islands need, decided at render time from the page's own client plan.

  Place `<ClientBoot />` after the page content (end of <body>): by then every
  `d.lua.island` has been rendered and recorded in the plan. It emits
  nothing for a page without Lua islands -- that page never starts a Lua
  engine. Otherwise, in a release build with a split Ballad bundle
  (`islands` in hydronium.sources.lua), it emits (preload hints only when
  some island hydrates on "load"):

    - <link rel="modulepreload"> for the island bootstrap's module graph,
    - low-priority <link rel="preload"> for engine.wasm and the chunks,
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

-- islands.js and everything it imports, plus the engine's own modules.
M.BOOTSTRAP_MODULES = {
  "islands.js", "mount.js", "dom_bridge.js", "host_capabilities.js", "engine_provider.js",
  "priority.js", "boundary_registry.js",
  "vendor/lua-wasm/5.4.9/engine.js", "vendor/lua-wasm/5.4.9/task-runtime.mjs",
}
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
  local modules, seen = {}, {}
  for _, island in ipairs(islands) do
    if type(island.module) == "string" and not seen[island.module] then
      seen[island.module] = true
      modules[#modules + 1] = island.module
    end
  end
  local chunks = props.bundle ~= false and M.chunks_for(modules) or {}
  if #chunks == 0 then return nil end

  local d = require("hydronium_dom").d
  local base = (props.bootstrap_url or M.BOOTSTRAP_URL):gsub("/+$", "")
  local out = {}
  -- Hints only when something hydrates on load: islands that wait for idle
  -- or visibility start the VM later (islands.js), so fetching the engine up
  -- front would spend bandwidth the first paint and the reader may never need.
  local eager = false
  for _, island in ipairs(islands) do
    if island.hydrate == nil or island.hydrate == "load" then eager = true end
  end
  for _, path in ipairs(eager and M.BOOTSTRAP_MODULES or {}) do
    out[#out + 1] = d.link({ rel = "modulepreload", href = base .. "/" .. path })
  end
  if eager then
    out[#out + 1] = d.link({ rel = "preload", href = base .. "/" .. M.ENGINE_WASM, as = "fetch",
      type = "application/wasm", crossorigin = "anonymous", fetchpriority = "low" })
    for _, url in ipairs(chunks) do
      out[#out + 1] = d.link({ rel = "preload", href = url, as = "fetch", crossorigin = "anonymous", fetchpriority = "low" })
    end
  end
  out[#out + 1] = d.script({ id = "__HYDRONIUM_BOOT__", type = "application/json" },
    json.encode({ chunks = chunks, hmr = false }))
  local element = require("hydronium.core.element")
  return element.h(element.Fragment, nil, out)
end

return M
