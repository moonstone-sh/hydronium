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

local server = {}

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

    local ok, res = pcall(function()
      return scopeModule.runWithScope(comp_scope, function()
        return node_tag(raw_props)
      end)
    end)

    comp_scope:dispose()

    if not ok then
      error(res, 0)
    end

    render_node(res, write_fn, parent_scope, raw_text_mode)
    return
  end

  -- Intrinsic DOM Element (e.g. "div", "button", "input")
  if type(node_tag) == "string" then
    local tag = node_tag:lower()
    local raw_props = (type(node.props) == "table" and node.props._store) or node.props or {}
    local attrs = html.serialize_attributes(node.props)
    local has_kids = has_meaningful_children(node)

    -- Strict HTML5 Void Element Check
    if html.VOID_ELEMENTS[tag] then
      if has_kids then
        error("Void element <" .. tag .. "> cannot have children", 2)
      end
      write_fn(string.format("<%s%s>", tag, attrs))
      return
    end

    -- Raw HTML handling (unsafe_raw_html or dangerouslySetInnerHTML)
    local raw_html_content = raw_props.unsafe_raw_html or (raw_props.dangerouslySetInnerHTML and raw_props.dangerouslySetInnerHTML.__html)
    if raw_html_content ~= nil then
      if has_kids then
        error("Cannot provide both children and raw HTML (unsafe_raw_html / dangerouslySetInnerHTML)", 2)
      end
      write_fn(string.format("<%s%s>%s</%s>", tag, attrs, tostring(raw_html_content), tag))
      return
    end

    write_fn(string.format("<%s%s>", tag, attrs))

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

    write_fn(string.format("</%s>", tag))
    return
  end
end

--- Deterministic JSON encoder for state serialization in SSR.
local function encode_json(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    return tostring(val)
  elseif t == "string" then
    local s = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
  elseif t == "table" then
    if #val > 0 then
      local items = {}
      for i = 1, #val do
        table.insert(items, encode_json(val[i]))
      end
      return "[" .. table.concat(items, ",") .. "]"
    else
      local keys = {}
      for k in pairs(val) do
        table.insert(keys, tostring(k))
      end
      table.sort(keys)
      local items = {}
      for _, k in ipairs(keys) do
        table.insert(items, string.format('"%s":%s', k, encode_json(val[k])))
      end
      return "{" .. table.concat(items, ",") .. "}"
    end
  else
    return '"' .. tostring(val) .. '"'
  end
end

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
      local state_json = encode_json(options.state)
      write_fn(string.format('<script id="__HYDRONIUM_STATE__" type="application/json">%s</script>', state_json))
    end
  end)

  -- Guaranteed cleanup in finally block
  root_scope:dispose()
  scopeModule.resetScopeStack(initial_scope_depth)
  contextModule.resetContextStack(initial_ctx_depth, initial_ctx_map)
  scheduler.setSSR(prev_ssr)

  if not ok then
    error(err, 0)
  end

  return table.concat(chunks, "")
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
  local write_fn

  if type(sink) == "function" then
    write_fn = sink
  elseif type(sink) == "table" and type(sink.write) == "function" then
    local info = debug.getinfo(sink.write, "u")
    if info and info.nparams == 1 and not info.isvararg then
      write_fn = function(chunk)
        sink.write(chunk)
      end
    else
      write_fn = function(chunk)
        sink:write(chunk)
      end
    end
  elseif type(sink) == "table" and (type(sink.onChunk) == "function" or type(sink.on_chunk) == "function") then
    options = sink
    local on_chunk = options.onChunk or options.on_chunk
    write_fn = on_chunk
  else
    error("server.render: sink must be a function or provide a :write(chunk) method", 2)
  end

  options.on_complete = options.on_complete or options.onComplete
  options.on_error = options.on_error or options.onError

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
      local state_json = encode_json(options.state)
      write_fn(string.format('<script id="__HYDRONIUM_STATE__" type="application/json">%s</script>', state_json))
    end

    if type(sink) == "table" and type(sink.flush) == "function" then
      sink:flush()
    end
  end)

  root_scope:dispose()
  scopeModule.resetScopeStack(initial_scope_depth)
  contextModule.resetContextStack(initial_ctx_depth, initial_ctx_map)
  scheduler.setSSR(prev_ssr)

  if type(sink) == "table" and type(sink.close) == "function" then
    pcall(function() sink:close() end)
  end

  if not ok then
    if options.on_error then
      options.on_error(err)
      return false, err
    else
      error(err, 0)
    end
  else
    if options.on_complete then
      options.on_complete()
    end
    return true
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
