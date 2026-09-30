--- Hydronium Server SSR Adapter for Meteorite (Model A In-Process Hybrid Integration)
---
--- `.handler(...)` and `.stream_handler(...)` below are factories: they
--- return a closure over their `component_or_vnode`/`default_opts`
--- arguments. That is fine for Meteorite's CLI dev/invoke path, but NOT
--- for a real compiled hybrid build passed directly to `app:get(path,
--- <expr>)` -- Meteorite's hybrid mode "lifts" each inline route handler
--- (extracts its own source text, reloads it standalone per request), and
--- rejects any handler that closes over an upvalue from outside its own
--- body ("inline Lua handler captures outer local `...`"). For a real
--- compiled route, call `.render(c, vnode, opts)` / `.render_stream(c,
--- vnode, sink, opts)` / `.make_stream_sink(...)` directly from inside a
--- literal `function(c) ... end` passed to `app:get`, doing your own
--- `require(...)` inside that body (see examples/meteorite_ssr/src/main.lua).
local server = require("hydronium_dom.server")
local context_api = require("hydronium.core.context")
local h = require("hydronium.core.element").createElement

local meteorite_adapter = {}

--- RequestContext for Hydronium components rendered in Meteorite.
--- Components can consume this with `useContext(meteorite.RequestContext)`.
local RequestContext = context_api.createContext({
  url = "/",
  params = {},
  query = {},
  headers = {},
  request_id = nil,
  state = {},
  scope = {},
  c = nil,
})
meteorite_adapter.RequestContext = RequestContext

--- Safely extract request details from Meteorite context `c`
--- @param c table
--- @return table req_data
local function extract_request_data(c)
  local req = {
    params = {},
    query = {},
    headers = {},
    state = {},
    scope = {},
    request_id = nil,
    c = c,
  }

  if type(c) ~= "table" then
    return req
  end

  local function context_value(name)
    local value = c[name]
    if type(value) ~= "function" then return value end
    local ok, result = pcall(value, c)
    return ok and result or nil
  end

  req.url = context_value("target") or context_value("url") or context_value("path") or "/"
  req.path = context_value("path") or req.url:match("^[^?]*") or "/"
  req.route_id = context_value("route_id")

  -- Params
  if type(c.params) == "table" then
    for k, v in pairs(c.params) do
      req.params[k] = v
    end
  end

  -- Query
  if type(c.query) == "table" then
    for k, v in pairs(c.query) do
      req.query[k] = v
    end
  end

  -- State & Scope
  if type(c.state) == "table" then
    for k, v in pairs(c.state) do
      req.state[k] = v
    end
  end
  if type(c.scope) == "table" then
    for k, v in pairs(c.scope) do
      req.scope[k] = v
    end
  end

  -- Request ID
  if type(c.request_id) == "function" then
    local ok, rid = pcall(function() return c:request_id() end)
    if ok and rid then req.request_id = rid end
  elseif type(c.request_id) == "string" then
    req.request_id = c.request_id
  end

  return req
end

--- Render a Hydronium vnode or component in the context of a Meteorite HTTP request.
--- @param c table Meteorite context (or context mock)
--- @param vnode table|function Hydronium vnode or component function
--- @param opts? table Render options { status?: integer, headers?: table, doctype?: boolean|string, props?: table }
--- @return table Response table compatible with Meteorite
function meteorite_adapter.render(c, vnode, opts)
  opts = opts or {}
  local status = opts.status or 200
  local custom_headers = opts.headers or {}

  local req_data = extract_request_data(c)

  -- Prepare element tree wrapped in RequestContext.Provider
  local root_element
  if type(vnode) == "function" then
    local props = opts.props or {}
    -- If props not explicitly passed, supply request params and query as defaults
    if props.params == nil then props.params = req_data.params end
    if props.query == nil then props.query = req_data.query end
    if props.c == nil then props.c = c end
    root_element = h(RequestContext.Provider, { value = req_data }, {
      h(vnode, props)
    })
  elseif type(vnode) == "table" then
    root_element = h(RequestContext.Provider, { value = req_data }, {
      vnode
    })
  else
    error("meteorite.render expects a vnode or component function, got " .. type(vnode), 2)
  end

  -- Render to HTML string
  local render_opts = {
    doctype = opts.doctype,
    state = opts.state,
    suppress_state_script = opts.suppress_state_script,
  }

  local html_output = server.render_to_string(root_element, render_opts)

  -- Use Meteorite's c:html if available
  if type(c) == "table" and type(c.html) == "function" then
    return c:html(status, html_output, { headers = custom_headers })
  end

  -- Standard Meteorite response table fallback. NOTE: `content-type` must
  -- NOT appear in `headers` -- Meteorite reserves it (along with
  -- content-length/connection/date/transfer-encoding) and rejects any
  -- handler-supplied header with that name; it belongs only in the
  -- separate top-level `content_type` field below.
  local resp_headers = {}
  for k, v in pairs(custom_headers) do
    resp_headers[k] = v
  end

  return {
    status = status,
    content_type = "text/html; charset=utf-8",
    headers = resp_headers,
    body = html_output,
  }
end

--- Create a Meteorite route handler from a component function or vnode.
--- @param component_or_vnode table|function
--- @param default_opts? table
--- @return fun(c: table): table
function meteorite_adapter.handler(component_or_vnode, default_opts)
  default_opts = default_opts or {}
  return function(c)
    local opts = {}
    for k, v in pairs(default_opts) do
      opts[k] = v
    end
    -- Allow dynamic status / headers resolution if functions provided
    if type(opts.status) == "function" then
      opts.status = opts.status(c)
    end
    if type(opts.headers) == "function" then
      opts.headers = opts.headers(c)
    end
    return meteorite_adapter.render(c, component_or_vnode, opts)
  end
end

--- Builds a Hydronium server-sink backed directly by Meteorite's real
--- `stream_begin`/`stream_write`/`stream_end` Lua globals (installed by
--- `zig/bridge/lua_bindings.zig` for the currently-executing inline Lua
--- handler). Headers are sent lazily on the first chunk, so a component
--- that renders nothing still gets a correctly-terminated empty stream.
--- @param status? integer HTTP status for the streamed response
--- @param content_type? string
--- @return table sink `{ write, flush, close }` per `hydronium.server.sink`
function meteorite_adapter.make_stream_sink(status, content_type)
  local began = false
  local function ensure_begun()
    if not began then
      stream_begin(status or 200, content_type or "text/html; charset=utf-8")
      began = true
    end
  end
  return {
    write = function(_, chunk)
      ensure_begun()
      if chunk ~= "" then
        stream_write(chunk)
      end
    end,
    flush = function() end,
    close = function()
      ensure_begun()
      stream_end()
    end,
  }
end

--- Stream a Hydronium vnode or component into a Meteorite sink.
--- @param c table Meteorite context
--- @param vnode table|function
--- @param sink table Sink object with :write(chunk), :flush(), :close()
--- @param opts? table
function meteorite_adapter.render_stream(c, vnode, sink, opts)
  opts = opts or {}
  local req_data = extract_request_data(c)

  local root_element
  if type(vnode) == "function" then
    local props = opts.props or {}
    if props.params == nil then props.params = req_data.params end
    if props.query == nil then props.query = req_data.query end
    if props.c == nil then props.c = c end
    root_element = h(RequestContext.Provider, { value = req_data }, {
      h(vnode, props)
    })
  else
    root_element = h(RequestContext.Provider, { value = req_data }, {
      vnode
    })
  end

  return server.render(root_element, sink, opts)
end

--- Create a Meteorite route handler that streams a component's SSR output
--- chunk-by-chunk over a real HTTP/1.1 chunked-transfer response, using
--- Meteorite's `stream_begin`/`stream_write`/`stream_end` globals. Requires
--- the app to be built in hybrid mode (inline Lua handlers only).
--- @param component_or_vnode table|function
--- @param default_opts? table
--- @return fun(c: table)
function meteorite_adapter.stream_handler(component_or_vnode, default_opts)
  default_opts = default_opts or {}
  return function(c)
    local opts = {}
    for k, v in pairs(default_opts) do
      opts[k] = v
    end
    if type(opts.status) == "function" then
      opts.status = opts.status(c)
    end
    local sink = meteorite_adapter.make_stream_sink(opts.status, opts.content_type)
    local ok, err = meteorite_adapter.render_stream(c, component_or_vnode, sink, opts)
    if not ok then
      error(err, 0)
    end
  end
end

-- ---------------------------------------------------------------------
-- App mounting
--
-- Meteorite owns the HTTP surface; a Hydronium app still needs a handful of
-- framework routes of its own (client runtime, framework source, dev module
-- server, HMR stream). `mount` declares those so an application's main.lua
-- only contains its own routes. Lua handlers are `m.lua` file handlers that
-- point into this installed package (hydronium_dom/server/meteorite_routes/),
-- never inline closures, so Meteorite's hybrid lifting has nothing to reject.
-- ---------------------------------------------------------------------

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or "."
end

local function is_file(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

--- Resolve the on-disk directory of a module namespace through package.path.
local function module_dir(namespace)
  local init = package.searchpath(namespace, package.path)
  return init and dirname(init) or nil
end

--- A published package ships browser assets inside its module directory
--- (`hydronium_router/client/`); a workspace path dependency keeps them at the
--- package root (`router/client/`). Probe both instead of hardcoding either.
local function asset_dir(candidates, probe)
  for _, dir in ipairs(candidates) do
    if dir and is_file(dir .. "/" .. probe) then return dir end
  end
  return nil
end

local function route_file(name)
  local path = package.searchpath("hydronium_dom.server.meteorite_routes." .. name, package.path)
  if not path then
    error("hydronium_dom.server.meteorite.mount: cannot locate route module `" .. name .. "` on package.path", 3)
  end
  return path
end

--- True when Meteorite is compiling a release build (release-hybrid,
--- release-static). Meteorite sets METEORITE_BUILD_MODE before main.lua runs.
--- @return boolean
function meteorite_adapter.is_release_build()
  return tostring(rawget(_G, "METEORITE_BUILD_MODE") or ""):match("^release") ~= nil
end

--- Declare Hydronium's framework routes on a Meteorite app.
---
---   GET /js/bootstrap/vendor/:path*         vendored wasmoon (1-day cache)
---   GET /js/bootstrap/:path*                mount.js, hmr.js, dom_bridge.js, ...
---   GET /js/router/{history,http}.js        when hydronium_router is installed
---   GET /hydronium-src/:path*               framework Lua for the browser VM
---   GET /__hydronium/client_manifest.json   framework modules, from the require graph
---   GET /__hydronium/dev/manifest.json      project module metadata   (dev)
---   GET /__hydronium/dev/module/:id         compiled project module   (dev)
---   GET /__hydronium/watch                  HMR change stream (SSE)   (not in release builds)
---   GET /__hydronium/client/:path*          Ballad browser bundle     (release builds, when built)
---
--- @param app table Meteorite app
--- @param opts? { meteorite?: table, dev?: boolean, hmr?: boolean, router?: boolean, client_manifest?: string|false }
---   `hmr` defaults to false in release builds: no watch stream, and the module
---   manifest reports `hmr: false` so the page skips installHmr.
---   `client_manifest`: a path serves that static file instead; `false` omits the route.
--- @return table[] declared routes
function meteorite_adapter.mount(app, opts)
  opts = opts or {}
  if type(app) ~= "table" or type(app.get) ~= "function" then
    error("hydronium_dom.server.meteorite.mount(app, opts) requires a Meteorite app", 2)
  end
  local m = opts.meteorite or require("meteorite")
  local mounted = {}
  local function get(path, options, handler)
    mounted[#mounted + 1] = app:get(path, options, handler)
  end
  local function lua(name)
    return m.lua("hydronium_dom.server.meteorite_routes." .. name, { path = route_file(name), arg_mode = "lazy_context" })
  end

  -- Prefer the package's libexec tree: Meteorite refuses to bake a static
  -- directory containing symlinks, and share/lua may be materialized as links
  -- into the Moonstone store.
  local dom_dir = module_dir("hydronium_dom")
  -- Namespaced mounts first (Moonstone 0.5.9+), then the flat aliases older
  -- Moonstone versions create.
  local client_dir = asset_dir({
    ".moonstone/env/libexec/hydronium/dom/hydronium_dom/client",
    ".moonstone/env/libexec/hydronium/dom/src/hydronium_dom/client",
    ".moonstone/env/libexec/dom/hydronium_dom/client",
    ".moonstone/env/libexec/dom/src/hydronium_dom/client",
    dom_dir and (dom_dir .. "/client"),
  }, "mount.js")
  if not client_dir then
    error("hydronium_dom.server.meteorite.mount: cannot locate hydronium_dom/client/mount.js", 2)
  end

  -- Declared vendor-first: Meteorite matches in declaration order, and both
  -- patterns match /js/bootstrap/vendor/... . glue.wasm (~270KB) is read into
  -- the request arena, so both need 1mb rather than the 256kb default. The
  -- vendored build is version-pinned (bounded cache, content ETag); the
  -- runtime JS changes during development (revalidate every time).
  get("/js/bootstrap/vendor/:path*", {
    id = "hydronium_client_vendor",
    summary = "Hydronium: vendored wasmoon runtime",
    memory = { request_arena = "1mb" },
  }, m.dir(client_dir .. "/vendor", { param = "path", cache = "public, max-age=86400, must-revalidate" }))
  get("/js/bootstrap/:path*", {
    id = "hydronium_client_runtime",
    summary = "Hydronium: browser client runtime",
    memory = { request_arena = "1mb" },
  }, m.dir(client_dir, { param = "path", cache = "no-cache" }))

  if opts.router ~= false then
    local router_dir = module_dir("hydronium_router")
    local router_client = router_dir and asset_dir({
      ".moonstone/env/libexec/hydronium/router/hydronium_router/client",
      ".moonstone/env/libexec/hydronium/router/client",
      ".moonstone/env/libexec/router/hydronium_router/client",
      ".moonstone/env/libexec/router/client",
      router_dir .. "/client",
      dirname(dirname(router_dir)) .. "/client",
    }, "history.js")
    if router_client then
      get("/js/router/history.js", { id = "hydronium_router_history", summary = "Hydronium Router: browser history" },
        m.file(router_client .. "/history.js", { cache = "no-cache" }))
      get("/js/router/http.js", { id = "hydronium_router_http", summary = "Hydronium Router: browser fetch bridge" },
        m.file(router_client .. "/http.js", { cache = "no-cache" }))
    elseif opts.router == true then
      error("hydronium_dom.server.meteorite.mount: router = true but hydronium_router/client/history.js was not found", 2)
    end
  end

  get("/hydronium-src/:path*", { id = "hydronium_framework_source", summary = "Hydronium: framework Lua for the browser VM" },
    lua("framework_source"))

  -- Derived from the project's real require graph by default; a path pins a
  -- static file instead, and `false` omits the route.
  local client_manifest = opts.client_manifest
  if type(client_manifest) == "string" then
    get("/__hydronium/client_manifest.json", { id = "hydronium_client_manifest", summary = "Hydronium: framework module manifest" },
      m.file(client_manifest, { cache = "no-cache", content_type = "application/json" }))
  elseif client_manifest ~= false then
    get("/__hydronium/client_manifest.json", { id = "hydronium_client_manifest", summary = "Hydronium: framework module manifest" },
      lua("client_manifest"))
  end

  -- Module delivery stays in release builds (pages still load app modules
  -- unbundled); only the HMR stream is development-only. Meteorite sets
  -- METEORITE_BUILD_MODE before evaluating main.lua.
  local hmr = opts.hmr
  if hmr == nil then hmr = not meteorite_adapter.is_release_build() end
  if opts.dev ~= false then
    get("/__hydronium/dev/manifest.json", { id = "hydronium_dev_manifest", summary = "Hydronium: project module manifest" },
      lua(hmr and "dev_manifest" or "release_manifest"))
    get("/__hydronium/dev/module/:id", { id = "hydronium_dev_module", summary = "Hydronium: compiled project module" },
      lua("dev_module"))
    if not hmr then
      -- Release: serve the content-hashed Ballad bundle when it was built
      -- first (`ballad play build.partiture.lua`); pages then boot from it.
      local routes = require("hydronium_dom.server.meteorite_routes")
      if routes.client_chunks() then
        get(routes.CLIENT_URL .. "/:path*", { id = "hydronium_client_bundle", summary = "Hydronium: production browser bundle" },
          m.dir(routes.CLIENT_DIR, { param = "path", immutable = true }))
      end
    end
    if hmr then
      get("/__hydronium/watch", { id = "hydronium_dev_watch", summary = "Hydronium dev: HMR change stream" },
        lua("watch"))
      -- Watched stylesheets (`{ path, href }` in hydronium.sources.lua) are
      -- served from disk at their own URL, ahead of the app's static routes
      -- (Meteorite matches in declaration order: call mount before
      -- meteorite.site).
      for index, entry in ipairs(meteorite_adapter.dev_files()) do
        get(entry.href, { id = "hydronium_dev_file_" .. index, summary = "Hydronium dev: " .. entry.path .. " from disk" },
          lua("dev_file"))
      end
    end
  end
  return mounted
end

--- Watched files served from disk in development: `{ path, href }` entries
--- of hydronium.sources.lua's `watch` list.
--- @return { path: string, href: string }[]
function meteorite_adapter.dev_files()
  local ok, registry = pcall(require("hydronium_dom.server.meteorite_routes").registry)
  local files = {}
  if not ok then return files end
  for _, entry in ipairs(registry.watch) do
    if entry.href then files[#files + 1] = entry end
  end
  return files
end

--- A `dev_watch` table for `meteorite.app({ dev_watch = ... })`. Hot client
--- modules are passive (the browser swaps them; the server must not restart)
--- wherever they live, so views are not tied to a particular directory.
--- @param opts? { graph?: string[] } extra graph inputs appended to the defaults
--- @return table
function meteorite_adapter.dev_watch(opts)
  opts = opts or {}
  local routes = require("hydronium_dom.server.meteorite_routes")
  local graph = { "src", "zig", "public", "build.zig", "moonstone.toml", routes.PROJECT_SOURCES, routes.DISCOVERED_SOURCES }
  for _, path in ipairs(opts.graph or {}) do graph[#graph + 1] = path end
  local hot = {}
  local ok, registry = pcall(routes.registry)
  if ok then
    for _, record in ipairs(registry.records) do
      if record.update == "hot" then hot[#hot + 1] = record.path end
    end
    -- Stylesheets mount serves from disk need no rebuild either. Plain
    -- (href-less) `watch` files stay graph inputs: Meteorite bakes
    -- m.dir/m.site content, so those do need the rebuild to be served.
  end
  for _, entry in ipairs(meteorite_adapter.dev_files()) do hot[#hot + 1] = entry.path end
  return { graph = graph, passive = hot, exclude = hot }
end

return meteorite_adapter
