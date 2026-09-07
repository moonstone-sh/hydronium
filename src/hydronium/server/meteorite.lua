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
local server = require("hydronium.server")
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

return meteorite_adapter
