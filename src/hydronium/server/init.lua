--[[
  Hydronium Server-Side Rendering (SSR) Engine
  Provides synchronous string rendering (render_to_string / renderToString)
  and streaming chunk rendering (render / render_to_stream / renderToStream).
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local scopeModule = require("hydronium.core.scope")
local contextModule = require("hydronium.core.context")
local scheduler = require("hydronium.core.scheduler")
local html = require("hydronium.server.html")
local json = require("hydronium.server.json")
local sink_protocol = require("hydronium.server.sink")
local resourceModule = require("hydronium.core.resource")

local server = {}

--[[
  Per-render bookkeeping for islands and the client plan (v1: SSR-only,
  buffered). Module-local rather than threaded through every render_node/
  render_children call site, matching this file's existing pattern for
  per-render state (see scheduler.setSSR / scopeModule's stack, both saved
  and restored around each top-level render_to_string/render call below).
  Not reentrant -- correct for the single synchronous render pass this
  file has always assumed (render_to_string/render are not called
  concurrently against the same Lua state).
--]]
local render_state = {
  island_seq = 0,
  client_plan = nil,
  -- Stack of interpreters ("lua"|"js") for currently-open ancestor
  -- islands, innermost last. Used only to diagnose a Lua event-callback
  -- prop with no enclosing d.lua.island/d.lua.mount boundary -- see
  -- html.serialize_attributes's caller below.
  island_stack = {},
}

local function reset_render_state()
  render_state.island_seq = 0
  render_state.client_plan = { version = "hydronium.client-plan.v1", islands = {}, scripts = {} }
  render_state.island_stack = {}
end

local function next_island_id()
  render_state.island_seq = render_state.island_seq + 1
  -- Deterministic, tree-order-derived, versioned -- never a pointer,
  -- random value, or timestamp (see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md).
  return "hy:i" .. tostring(render_state.island_seq)
end

function server.current_lua_island()
  local stack = render_state.island_stack
  for i = #stack, 1, -1 do
    if stack[i] == "lua" then return true end
  end
  return false
end

-- Export HTML helpers on server table
server.escape_html = html.escape_html
server.escape_script_content = html.escape_script_content
server.escape_style_content = html.escape_style_content

--- Helper to inspect if a node has any non-empty children
local function has_meaningful_children(node)
  local props = node.props
  local raw_props = (type(props) == "table" and props._store) or props
  local children = node.children
  if children == nil and raw_props and type(raw_props) == "table" then
    children = raw_props.children
  end
  if children == nil then return false end
  local t = type(children)
  if t == "string" then return #children > 0 end
  if t == "number" or t == "boolean" then return true end
  if t == "userdata" then
    return #children > 0
  elseif t == "table" then
    if children._typeof == symbols.VNODE then return true end
    if #children > 0 then return true end
    local raw = (type(children) == "table" and children._store) or children
    if #raw > 0 or raw[1] ~= nil then return true end
  end
  return false
end

-- Forward declaration of render_node
local render_node

--- Recursively renders children to write_fn
local function render_children(children, write_fn, parent_scope, raw_text_mode)
  if children == nil then return end
  local t = type(children)

  if t == "userdata" then
    local len = #children
    for i = 1, len do
      render_node(children[i], write_fn, parent_scope, raw_text_mode)
    end
    return
  elseif t == "table" and children._typeof ~= symbols.VNODE then
    local len = #children
    if len > 0 then
      for i = 1, len do
        render_node(children[i], write_fn, parent_scope, raw_text_mode)
      end
      return
    end
    local raw = children._store or children
    if #raw > 0 then
      for i = 1, #raw do
        render_node(raw[i], write_fn, parent_scope, raw_text_mode)
      end
      return
    end
    return
  end

  render_node(children, write_fn, parent_scope, raw_text_mode)
end

--- Recursive rendering of virtual DOM nodes to the write function sink.
render_node = function(node, write_fn, parent_scope, raw_text_mode)
  if node == nil or node == false or node == true then
    return
  end

  local node_type = type(node)

  -- Raw primitive strings / numbers
  if node_type == "string" or node_type == "number" then
    if raw_text_mode then
      write_fn(tostring(node))
    else
      write_fn(html.escape_html(node))
    end
    return
  end

  -- Evaluated reactive accessors / signals passed directly as child
  if node_type == "table" and (node._typeof == symbols.SIGNAL or node._typeof == symbols.COMPUTED or node._is_signal or node._is_computed) then
    local evaluated = html.evaluate_value(node)
    render_node(evaluated, write_fn, parent_scope, raw_text_mode)
    return
  end

  -- Function child (e.g. getter)
  if node_type == "function" and not (node._typeof == symbols.VNODE) then
    local ok, res = pcall(node)
    if ok then
      render_node(res, write_fn, parent_scope, raw_text_mode)
      return
    end
  end

  if node_type ~= "table" and node_type ~= "userdata" then
    return
  end

  local node_tag = node.tag
  if type(node_tag) == "table" and (node_tag["$$typeof"] == symbols.INTRINSIC or node_tag._typeof == symbols.INTRINSIC) then
    node_tag = node_tag.tag
  end

  -- Text VNode (kind == symbols.TEXT)
  if node.kind == symbols.TEXT or (node.type == symbols.TEXT) then
    local text = node.text or (node.props and node.props.text) or ""
    if raw_text_mode then
      write_fn(tostring(text))
    else
      write_fn(html.escape_html(text))
    end
    return
  end

  -- Fragment rendering
  if node_tag == symbols.FRAGMENT or (node.type == symbols.FRAGMENT) or (node.kind == symbols.FRAGMENT) then
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props
    local children = node.children or (raw_props and raw_props.children) or {}
    render_children(children, write_fn, parent_scope, raw_text_mode)
    return
  end

  -- Array of child nodes
  if node[1] ~= nil and node._typeof ~= symbols.VNODE then
    for i = 1, #node do
      render_node(node[i], write_fn, parent_scope, raw_text_mode)
    end
    return
  end

  -- ErrorBoundary Component
  if node.kind == symbols.BOUNDARY or node_tag == errors.ErrorBoundary then
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props or {}
    local children = raw_props.children or node.children or {}
    local buffered = {}
    local buffer_write = function(chunk)
      table.insert(buffered, chunk)
    end

    local ok, err = pcall(function()
      render_children(children, buffer_write, parent_scope, raw_text_mode)
    end)

    if ok then
      for _, chunk in ipairs(buffered) do
        write_fn(chunk)
      end
    elseif resourceModule.isSuspension(err) then
      -- A pending Resource is not a render error -- ErrorBoundary and
      -- Suspense are orthogonal (see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md).
      -- Let it keep propagating toward the nearest actual <h.Suspense>.
      error(err, 0)
    else
      if raw_props.onError and type(raw_props.onError) == "function" then
        pcall(raw_props.onError, err)
      end

      local fallback = raw_props.fallback
      if type(fallback) == "function" then
        local err_obj = errors.wrapPhaseError("render", err)
        local fb_ok, fb_node = pcall(fallback, err_obj, function() end)
        if fb_ok then
          render_node(fb_node, write_fn, parent_scope, raw_text_mode)
        else
          error(fb_node, 0)
        end
      elseif fallback ~= nil then
        render_node(fallback, write_fn, parent_scope, raw_text_mode)
      end
    end
    return
  end

  -- Suspense: "can this subtree render right now, and what shows while it
  -- can't" -- deliberately independent of ErrorBoundary (above) and of
  -- island/client-ownership (below). v1: sequential/buffered only -- no
  -- out-of-order streaming replacement yet (see
  -- docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md). Isolates its subtree's writes
  -- in an internal buffer (same trick as ErrorBoundary above) so a
  -- suspension partway through never leaks partial bytes to the real sink.
  if node.kind == symbols.SUSPENSE then
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props or {}
    local children = raw_props.children or node.children or {}
    local buffered = {}
    local buffer_write = function(chunk)
      table.insert(buffered, chunk)
    end

    local ok, err = pcall(function()
      render_children(children, buffer_write, parent_scope, raw_text_mode)
    end)

    if ok then
      for _, chunk in ipairs(buffered) do
        write_fn(chunk)
      end
    elseif resourceModule.isSuspension(err) then
      local fallback = raw_props.fallback
      if fallback ~= nil then
        render_node(fallback, write_fn, parent_scope, raw_text_mode)
      end
    else
      -- A real render error (not a suspension) is not this boundary's
      -- concern -- let it keep propagating toward the nearest ErrorBoundary.
      error(err, 0)
    end
    return
  end

  -- Island: "who executes this subtree in the browser" -- a DOM-bound
  -- client-execution boundary (d.lua.island / d.js.island / d.lua.mount),
  -- NOT an implementation of an interpreter (see hydronium/dom/init.lua).
  -- v1 (SSR only): render children normally, wrap them in stable-ID HTML
  -- comment markers a future client bootstrap can locate, and record a
  -- ClientPlan island entry. No interpreter is loaded or referenced here.
  if node.kind == symbols.ISLAND then
    local descriptor = node_tag
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props or {}
    local children = raw_props.children or node.children or {}
    local id = next_island_id()

    local plan = render_state.client_plan
    if plan then
      table.insert(plan.islands, {
        id = id,
        interpreter = descriptor.interpreter,
        root = raw_props.root == true,
        module = raw_props.module,
        mode = raw_props.mode,
        hydrate = raw_props.hydrate or "load",
        props = raw_props.props,
      })
    end

    write_fn("<!--hy:i:" .. id .. ":" .. tostring(descriptor.interpreter) .. "-->")
    table.insert(render_state.island_stack, descriptor.interpreter)
    local ok, err = pcall(function()
      render_children(children, write_fn, parent_scope, raw_text_mode)
    end)
    table.remove(render_state.island_stack)
    write_fn("<!--hy:/i:" .. id .. "-->")
    if not ok then
      error(err, 0)
    end
    return
  end

  -- Script: a client-plan resource, not an unstructured `<script>` string
  -- (d.js.script). Produces no HTML output of its own in v1 -- loading
  -- strategy/injection is a client-plan concern for a future client
  -- bootstrap, not something SSR decides today.
  if node.kind == symbols.SCRIPT then
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props or {}
    local plan = render_state.client_plan
    if plan then
      table.insert(plan.scripts, {
        src = raw_props.src,
        module = raw_props.type == "module" and raw_props.src or nil,
        type = raw_props.type,
        strategy = raw_props.strategy,
        integrity = raw_props.integrity,
        bindings = raw_props.binds,
      })
    end
    return
  end

  -- Context Provider Component
  if type(node_tag) == "table" and node_tag.__context then
    local ctx = node_tag.__context
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props or {}
    local val = raw_props.value
    local current_map = contextModule.getCurrentContextMap() or {}
    local new_map = setmetatable({ [ctx] = val }, { __index = current_map })

    contextModule.pushContext(new_map)
    local children = raw_props.children or node.children
    local ok, err = pcall(function()
      render_children(children, write_fn, parent_scope, raw_text_mode)
    end)
    contextModule.popContext()
    if not ok then
      error(err, 0)
    end
    return
  end

  -- Custom Component (Function or Callable Table)
  if type(node_tag) == "function" or (type(node_tag) == "table" and getmetatable(node_tag) and getmetatable(node_tag).__call) then
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props or {}
    local comp_scope = scopeModule.Scope.new(parent_scope)

    -- Mirrors ComponentInstance:render's (props, scope) calling convention
    -- (src/hydronium/core/component.lua) exactly, including the
    -- setup-function-returns-a-render-function ("double function") pattern:
    -- both the setup call and the render call it may return receive the
    -- same (raw_props, comp_scope) arguments the client path passes. Calling
    -- the setup function with only `raw_props` and no `scope` -- and, worse,
    -- letting a returned render closure fall through to render_node's
    -- generic zero-argument function-child case -- silently gave SSR
    -- components `nil` for any second/`scope` parameter their render
    -- closure reads, a real client/server divergence for the documented
    -- component pattern.
    local ok, res = pcall(function()
      return scopeModule.runWithScope(comp_scope, function()
        local result = node_tag(raw_props, comp_scope)
        if type(result) == "function" then
          result = result(raw_props, comp_scope)
        end
        -- Render descendants while their owner scope is live. This preserves
        -- client ownership: nested component scopes are children of this
        -- component, and child cleanup runs before parent cleanup.
        render_node(result, write_fn, comp_scope, raw_text_mode)
      end)
    end)

    local disposed, dispose_err = pcall(function() comp_scope:dispose() end)

    if not ok then
      error(res, 0)
    end
    if not disposed then
      error(dispose_err, 0)
    end
    return
  end

  -- Intrinsic DOM Element (e.g. "div", "button", "input")
  if type(node_tag) == "string" then
    if not html.is_valid_tag_name(node_tag) then
      error("Invalid SSR tag name: " .. tostring(node_tag), 2)
    end
    local tag = node_tag:lower()
    -- SVG is case-sensitive XML; a handful of real SVG element names
    -- (linearGradient, clipPath, feGaussianBlur, ...) are camelCase and
    -- naively lowercasing them (as HTML tag names normally are) would
    -- output an element name the SVG spec doesn't recognize. `tag` (always
    -- lowercase) remains the internal comparison key for VOID_ELEMENTS /
    -- script / style checks below; `output_tag` is what's actually written.
    local output_tag = html.SVG_TAG_CASING[tag] or tag
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props or {}

    -- html.serialize_attributes already drops function-valued props (never
    -- serialized into HTML -- see its own filter). A Lua function on an
    -- event-shaped prop (onClick, onInput, ...) with no enclosing Lua
    -- client boundary would therefore be silently dropped there, which the
    -- project's diagnostics policy forbids: it must be a build/SSR error,
    -- not silent data loss (see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md).
    if not server.current_lua_island() then
      for k, v in pairs(raw_props) do
        if type(k) == "string" and type(v) == "function" and #k > 2 and k:sub(1, 2) == "on" and k:byte(3) >= 65 and k:byte(3) <= 90 then
          error("Hydronium: Lua callback `" .. k .. "` requires a Lua client execution boundary.\n"
            .. "Wrap this subtree in <d.lua.island>, mount the root through d.lua.mount(), "
            .. "or use a JavaScript client integration.", 0)
        end
      end
    end

    local attrs = html.serialize_attributes(node.props, tag)
    local has_kids = has_meaningful_children(node)

    -- Strict HTML5 Void Element Check
    if html.VOID_ELEMENTS[tag] then
      if has_kids then
        error("Void element <" .. tag .. "> cannot have children", 2)
      end
      write_fn(string.format("<%s%s>", output_tag, attrs))
      return
    end

    -- Raw HTML handling (unsafe_raw_html or dangerouslySetInnerHTML)
    local raw_html_content = raw_props.unsafe_raw_html or (raw_props.dangerouslySetInnerHTML and raw_props.dangerouslySetInnerHTML.__html)
    if raw_html_content ~= nil then
      if has_kids then
        error("Cannot provide both children and raw HTML (unsafe_raw_html / dangerouslySetInnerHTML)", 2)
      end
      write_fn(string.format("<%s%s>%s</%s>", output_tag, attrs, tostring(raw_html_content), output_tag))
      return
    end

    write_fn(string.format("<%s%s>", output_tag, attrs))

    local children = raw_props.children or node.children
    local child_raw = raw_text_mode or (tag == "script") or (tag == "style")

    if tag == "script" then
      local buffer = {}
      render_children(children, function(chunk) table.insert(buffer, chunk) end, parent_scope, true)
      local content = table.concat(buffer, "")
      write_fn(html.escape_script_content(content))
    elseif tag == "style" then
      local buffer = {}
      render_children(children, function(chunk) table.insert(buffer, chunk) end, parent_scope, true)
      local content = table.concat(buffer, "")
      write_fn(html.escape_style_content(content))
    else
      render_children(children, write_fn, parent_scope, child_raw)
    end

    write_fn(string.format("</%s>", output_tag))
    return
  end
end

--- Deterministic JSON encoder for state serialization in SSR.
server.encode_state = json.encode

--- Synchronously renders a virtual DOM tree to an HTML string.
--- @param vnode table Root VNode or Component
--- @param options? table Options { doctype?: boolean|string, state?: table, suppress_state_script?: boolean }
--- @return string Serialized HTML
function server.render_to_string(vnode, options)
  options = options or {}
  local chunks = {}
  local write_fn = function(chunk)
    table.insert(chunks, chunk)
  end

  reset_render_state()
  local prev_ssr = scheduler.isSSR()
  scheduler.setSSR(true)

  local initial_scope_depth = scopeModule.getScopeStackDepth()
  local initial_ctx_depth = contextModule.getContextStackDepth()
  local initial_ctx_map = contextModule.getCurrentContextMap()
  local root_scope = scopeModule.Scope.new(nil)

  local ok, err = pcall(function()
    if options.doctype then
      local dt = (type(options.doctype) == "string" and options.doctype) or "<!DOCTYPE html>\n"
      write_fn(dt)
    end

    render_node(vnode, write_fn, root_scope, false)

    if options.state and not options.suppress_state_script then
      local state_json = json.encode(options.state)
      write_fn(string.format('<script id="__HYDRONIUM_STATE__" type="application/json">%s</script>', state_json))
    end

    -- Emitted only when the page actually declared client surface
    -- (islands/scripts): an SSR-only page ships no client-plan tag and no
    -- client bootstrap reference at all (see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md).
    local plan = render_state.client_plan
    if plan and not options.suppress_client_plan_script and (#plan.islands > 0 or #plan.scripts > 0) then
      local plan_json = json.encode(plan)
      write_fn(string.format('<script id="__HYDRONIUM_CLIENT_PLAN__" type="application/json">%s</script>', plan_json))
    end
  end)

  -- Guaranteed cleanup in finally block
  local disposed, dispose_err = pcall(function() root_scope:dispose() end)
  scopeModule.resetScopeStack(initial_scope_depth)
  contextModule.resetContextStack(initial_ctx_depth, initial_ctx_map)
  scheduler.setSSR(prev_ssr)

  if not ok then
    if resourceModule.isSuspension(err) then
      error("Hydronium: a Resource was read while pending with no enclosing <h.Suspense> boundary "
        .. "(root suspension policy is not defined -- wrap the resource's reader in <h.Suspense fallback={...}>)", 0)
    end
    error(err, 0)
  end
  if not disposed then
    error(dispose_err, 0)
  end

  return table.concat(chunks, ""), render_state.client_plan
end

server.renderToString = server.render_to_string

--- Streams virtual DOM rendering chunks into a sink.
--- The sink must implement `{ write = fun(chunk: string), flush = fun(), close = fun() }`.
--- @param vnode table Root VNode or Component
--- @param sink table Sink object
--- @param options? table Options
--- @return boolean ok
--- @return string|nil err
function server.render(vnode, sink, options)
  options = options or {}
  local normalized_sink
  local write_fn

  if type(sink) == "table" and (type(sink.onChunk) == "function" or type(sink.on_chunk) == "function") then
    options = sink
    local on_chunk = options.onChunk or options.on_chunk
    write_fn = on_chunk
  else
    normalized_sink = sink_protocol.normalize(sink)
    write_fn = normalized_sink.write
  end

  options.on_complete = options.on_complete or options.onComplete
  options.on_error = options.on_error or options.onError

  reset_render_state()
  local prev_ssr = scheduler.isSSR()
  scheduler.setSSR(true)

  local initial_scope_depth = scopeModule.getScopeStackDepth()
  local initial_ctx_depth = contextModule.getContextStackDepth()
  local initial_ctx_map = contextModule.getCurrentContextMap()
  local root_scope = scopeModule.Scope.new(nil)

  local ok, err = pcall(function()
    if options.doctype then
      local dt = (type(options.doctype) == "string" and options.doctype) or "<!DOCTYPE html>\n"
      write_fn(dt)
    end

    render_node(vnode, write_fn, root_scope, false)

    if options.state and not options.suppress_state_script then
      local state_json = json.encode(options.state)
      write_fn(string.format('<script id="__HYDRONIUM_STATE__" type="application/json">%s</script>', state_json))
    end

    -- Emitted only when the page actually declared client surface
    -- (islands/scripts): an SSR-only page ships no client-plan tag and no
    -- client bootstrap reference at all (see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md).
    local plan = render_state.client_plan
    if plan and not options.suppress_client_plan_script and (#plan.islands > 0 or #plan.scripts > 0) then
      local plan_json = json.encode(plan)
      write_fn(string.format('<script id="__HYDRONIUM_CLIENT_PLAN__" type="application/json">%s</script>', plan_json))
    end

    if normalized_sink then
      normalized_sink.flush()
    end
  end)

  local disposed, dispose_err = pcall(function() root_scope:dispose() end)
  scopeModule.resetScopeStack(initial_scope_depth)
  contextModule.resetContextStack(initial_ctx_depth, initial_ctx_map)
  scheduler.setSSR(prev_ssr)

  if normalized_sink then
    pcall(normalized_sink.close)
  end

  if not ok then
    if resourceModule.isSuspension(err) then
      err = "Hydronium: a Resource was read while pending with no enclosing <h.Suspense> boundary "
        .. "(root suspension policy is not defined -- wrap the resource's reader in <h.Suspense fallback={...}>)"
    end
    if options.on_error then
      options.on_error(err)
      return false, err
    else
      error(err, 0)
    end
  elseif not disposed then
    if options.on_error then
      options.on_error(dispose_err)
      return false, dispose_err
    end
    error(dispose_err, 0)
  else
    if options.on_complete then
      options.on_complete(render_state.client_plan)
    end
    return true, render_state.client_plan
  end
end

server.render_to_stream = function(vnode, opts)
  return server.render(vnode, opts)
end

server.renderToStream = server.render_to_stream

-- Lazy load meteorite adapter to prevent circular require
server.meteorite = setmetatable({}, {
  __index = function(_, k)
    return require("hydronium.server.meteorite")[k]
  end,
})

return server
