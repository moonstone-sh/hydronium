--[[
  A serializable, host-neutral route tree.

  The tree names logical screens and executable loader/action modules. It
  never stores component closures or host services. A host resolves the
  logical IDs when it creates a Router; build tools can inspect and lower the
  same tree without loading application code.

  Path rules are deliberately narrow:
    * the root path is "/" (or omitted, which means "/")
    * child paths are relative and have no leading/trailing slash
    * nil is a pathless layout; "" is an explicit index route
    * catch-alls are terminal and cannot have children
    * only leaf nodes are addressable endpoints
--]]

local pattern = require("hydronium_router.pattern")
local router = require("hydronium_router.router")
local url = require("hydronium_router.url")

local M = {}

local function fail(message, level)
  error("hydronium_router.site: " .. message, level or 3)
end

local function is_array(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
  end
  return count == #value
end

local function serializable(value, seen)
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
    return true
  end
  if kind ~= "table" then return false end
  seen = seen or {}
  if seen[value] then return false end
  seen[value] = true
  for key, item in pairs(value) do
    if not serializable(key, seen) or not serializable(item, seen) then
      seen[value] = nil
      return false
    end
  end
  seen[value] = nil
  return true
end

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then fail("route manifest contains a cycle", 4) end
  local out = {}
  seen[value] = out
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  seen[value] = nil
  return out
end

local function validate_id(id)
  if type(id) ~= "string" or id == "" then
    fail("node id must be a non-empty string", 4)
  end
  if id:sub(1, 1) == "." or id:sub(-1) == "." or id:find("..", 1, true) then
    fail("invalid node id " .. string.format("%q", id), 4)
  end
  for part in id:gmatch("[^%.]+") do
    if not part:match("^[%a_][%w_]*$") then
      fail("invalid node id " .. string.format("%q", id)
        .. ": segment " .. string.format("%q", part)
        .. " must match ^[%a_][%w_]*$", 4)
    end
  end
end

local function validate_logical_ref(value, label)
  if type(value) == "string" and value ~= "" then return end
  if type(value) == "table" and next(value) ~= nil and not is_array(value) then
    for target, ref in pairs(value) do
      if type(target) ~= "string" or target == "" or type(ref) ~= "string" or ref == "" then
        fail(label .. " target map must contain non-empty string pairs", 4)
      end
    end
    return
  end
  fail(label .. " must be a non-empty logical id or target map", 4)
end

local function validate_relative_path(path, label)
  if path == nil or path == "" then return end
  if type(path) ~= "string" then
    fail(label .. " path must be a string, an empty index path, or nil", 4)
  end
  if path:sub(1, 1) == "/" or path:sub(-1) == "/" then
    fail(label .. " child path must be relative and have no leading or trailing slash", 4)
  end
  if path:find("//", 1, true) then
    fail(label .. " child path may not contain duplicate slashes", 4)
  end
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      fail(label .. " child path may not contain '.' or '..' segments", 4)
    end
  end
end

local function normalize_loader(value, node_id)
  if value == nil then return nil end
  if type(value) == "string" then
    if value == "" then fail("node " .. string.format("%q", node_id) .. " has an empty loader id", 4) end
    return { ref = value, key = node_id }
  end
  if type(value) ~= "table" or type(value.ref) ~= "string" or value.ref == "" then
    fail("node " .. string.format("%q", node_id)
      .. " load must be a module id or { ref = <module id>, key? = <string> }", 4)
  end
  if value.key ~= nil and (type(value.key) ~= "string" or value.key == "") then
    fail("node " .. string.format("%q", node_id) .. " loader key must be a non-empty string", 4)
  end
  local out = copy(value)
  out.key = out.key or node_id
  return out
end

local action_methods = { POST = true, PUT = true, PATCH = true, DELETE = true }

local function normalize_actions(value, node_id)
  if value == nil then return {} end
  if type(value) ~= "table" or (next(value) ~= nil and is_array(value)) then
    fail("node " .. string.format("%q", node_id) .. " actions must be a name-keyed table", 4)
  end
  local out = {}
  for name, declaration in pairs(value) do
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
      fail("node " .. string.format("%q", node_id) .. " has invalid action name " .. string.format("%q", tostring(name)), 4)
    end
    if type(declaration) == "string" then declaration = { ref = declaration } end
    if type(declaration) ~= "table" or type(declaration.ref) ~= "string" or declaration.ref == "" then
      fail("action " .. string.format("%q", node_id .. "." .. name)
        .. " must be a module id or { ref = <module id>, ... }", 4)
    end
    local action = copy(declaration)
    action.id = action.id or (node_id .. "." .. name)
    action.name = name
    action.method = string.upper(action.method or "POST")
    action.encoding = action.encoding or "form"
    if type(action.id) ~= "string" or action.id == "" then fail("action id must be a non-empty string", 4) end
    if not action_methods[action.method] then
      fail("action " .. string.format("%q", action.id) .. " method must be POST, PUT, PATCH, or DELETE", 4)
    end
    if action.encoding ~= "form" and action.encoding ~= "json" then
      fail("action " .. string.format("%q", action.id) .. " encoding must be \"form\" or \"json\"", 4)
    end
    if action.path ~= nil and (type(action.path) ~= "string" or action.path:sub(1, 1) ~= "/") then
      fail("action " .. string.format("%q", action.id) .. " path must be absolute", 4)
    end
    out[name] = action
  end
  return out
end

---@class HydroniumRouteNode
---@field id string
---@field path string|nil
---@field screen string|nil
---@field load table|nil
---@field actions table|nil
---@field pending string|nil
---@field error string|nil
---@field reuse "keep"|nil
---@field prerender boolean|nil Explicitly include a static leaf in build-time HTML output.
---@field children HydroniumRouteNode[]

---@param spec table
---@return HydroniumRouteNode
function M.node(spec)
  if type(spec) ~= "table" then fail("node expects a table", 2) end
  if spec._hydronium_route_node == true then return spec end
  validate_id(spec.id)
  if spec.path ~= nil and type(spec.path) ~= "string" then
    fail("node " .. string.format("%q", spec.id) .. " path must be a string or nil", 2)
  end
  if spec.screen ~= nil then validate_logical_ref(spec.screen, "node " .. string.format("%q", spec.id) .. " screen") end
  if spec.pending ~= nil then validate_logical_ref(spec.pending, "node " .. string.format("%q", spec.id) .. " pending") end
  if spec.error ~= nil then validate_logical_ref(spec.error, "node " .. string.format("%q", spec.id) .. " error") end
  if spec.reuse ~= nil and spec.reuse ~= "keep" then
    fail("node " .. string.format("%q", spec.id) .. " reuse only accepts \"keep\"; "
      .. "the safe default remounts when the node's own params change", 2)
  end
  if spec.prerender ~= nil and type(spec.prerender) ~= "boolean" then
    fail("node " .. string.format("%q", spec.id) .. " prerender must be a boolean", 2)
  end
  if spec.children ~= nil and not is_array(spec.children) then
    fail("node " .. string.format("%q", spec.id) .. " children must be an array", 2)
  end
  if spec.actions ~= nil and type(spec.actions) ~= "table" then
    fail("node " .. string.format("%q", spec.id) .. " actions must be a table", 2)
  end
  if not serializable(spec) then
    fail("node " .. string.format("%q", spec.id)
      .. " must be serializable (no functions, userdata, threads, or cycles)", 2)
  end

  local out = copy(spec)
  out._hydronium_route_node = true
  out.load = normalize_loader(out.load, out.id)
  out.actions = normalize_actions(out.actions, out.id)
  out.children = out.children or {}
  for index = 1, #out.children do out.children[index] = M.node(out.children[index]) end
  return out
end

local function join_path(parent, relative)
  if relative == nil or relative == "" then return parent end
  if parent == "/" then return "/" .. relative end
  return parent .. "/" .. relative
end

local function signature(parsed)
  local parts = {}
  for index, segment in ipairs(parsed.segments) do
    if segment.kind == "literal" then
      parts[index] = "l:" .. segment.value
    elseif segment.kind == "param" then
      parts[index] = "p"
    else
      parts[index] = "c"
    end
  end
  return table.concat(parts, "/")
end

local function public_node(node)
  local out = {}
  for key, value in pairs(node) do
    if type(key) ~= "string" or key:sub(1, 1) ~= "_" then out[key] = copy(value) end
  end
  return out
end

local function manifest_value(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" or key:sub(1, 1) ~= "_" then
      out[manifest_value(key)] = manifest_value(item)
    end
  end
  return out
end

---@class HydroniumSite
local Site = {}
Site.__index = Site

local function compile_site(root)
  local by_id, endpoints, actions, by_path, by_signature, by_action_id, by_action_route = {}, {}, {}, {}, {}, {}, {}

  local function visit(node, parent_path, ancestors, inherited_params, is_root)
    validate_id(node.id)
    if by_id[node.id] then fail("duplicate node id " .. string.format("%q", node.id), 4) end

    local route_path
    if is_root then
      if node.path ~= nil and node.path ~= "/" then
        fail("root node path must be '/' or nil", 4)
      end
      route_path = "/"
    else
      validate_relative_path(node.path, "node " .. string.format("%q", node.id))
      route_path = join_path(parent_path, node.path)
    end
    route_path = url.normalize_path(route_path)

    local parsed = pattern.parse(route_path)
    if parsed.has_catch_all and #node.children > 0 then
      fail("catch-all node " .. string.format("%q", node.id) .. " may not have children", 4)
    end

    local inherited = {}
    for name in pairs(inherited_params) do inherited[name] = true end
    local own_params = {}
    local relative_pattern = node.path and node.path ~= "" and pattern.parse("/" .. node.path) or nil
    if relative_pattern then
      for _, name in ipairs(relative_pattern.params) do
        if inherited[name] then
          fail("node " .. string.format("%q", node.id) .. " redeclares ancestor param "
            .. string.format("%q", name), 4)
        end
        inherited[name] = true
        own_params[#own_params + 1] = name
      end
      if relative_pattern.has_wildcard then own_params[#own_params + 1] = "*" end
    end

    local record = public_node(node)
    record.path = node.path
    record.full_path = route_path
    record.parent_id = ancestors[#ancestors] and ancestors[#ancestors].id or nil
    record.own_params = own_params
    record.pattern = parsed
    record.children = nil
    by_id[node.id] = record

    for name, declaration in pairs(record.actions or {}) do
      local action = copy(declaration)
      action.node_id = record.id
      action.name = name
      action.path = url.normalize_path(action.path or route_path)
      pattern.parse(action.path)
      if by_action_id[action.id] then
        fail("duplicate action id " .. string.format("%q", action.id), 4)
      end
      local route_key = action.method .. " " .. action.path
      if by_action_route[route_key] then
        fail("duplicate action endpoint " .. route_key .. " for "
          .. string.format("%q", by_action_route[route_key].id) .. " and " .. string.format("%q", action.id), 4)
      end
      by_action_id[action.id] = action
      by_action_route[route_key] = action
      actions[#actions + 1] = action
      record.actions[name] = action
    end

    local chain = {}
    for index = 1, #ancestors do chain[index] = ancestors[index] end
    chain[#chain + 1] = record

    if #node.children == 0 then
      if record.screen == nil then
        fail("leaf node " .. string.format("%q", node.id) .. " must declare a screen", 4)
      end
      if record.prerender then
        if #parsed.params > 0 or parsed.has_wildcard then
          fail("prerender node " .. string.format("%q", node.id) .. " needs a literal path", 4)
        end
        for _, ancestor in ipairs(chain) do
          if ancestor.load ~= nil then
            fail("prerender node " .. string.format("%q", node.id)
              .. " cannot use a loader until build-time data is declared explicitly", 4)
          end
        end
      end
      local shape = signature(parsed)
      if by_path[route_path] then
        fail("duplicate endpoint path " .. string.format("%q", route_path)
          .. " for " .. string.format("%q", by_path[route_path].id)
          .. " and " .. string.format("%q", node.id), 4)
      end
      if by_signature[shape] then
        fail("ambiguous endpoint " .. string.format("%q", route_path)
          .. " has the same URL shape as " .. string.format("%q", by_signature[shape].path), 4)
      end
      local endpoint = { id = record.id, path = route_path, pattern = parsed, chain = chain, node = record }
      endpoints[#endpoints + 1] = endpoint
      by_path[route_path] = endpoint
      by_signature[shape] = endpoint
    else
      for index = 1, #node.children do
        visit(node.children[index], route_path, chain, inherited, false)
      end
    end
  end

  visit(root, "/", {}, {}, true)
  table.sort(actions, function(a, b)
    if a.path == b.path then return a.method < b.method end
    return a.path < b.path
  end)
  return by_id, endpoints, actions, by_action_id
end

---@param spec table `{ root = r.node(...), ...serializable options }`
---@return HydroniumSite
function M.site(spec)
  if type(spec) ~= "table" then fail("site expects { root = node(...) }", 2) end
  if spec.root == nil then fail("site requires a root node", 2) end
  -- Reconstruct from public data so mutating a declaration table after site()
  -- cannot silently change the compiled matcher or emitted manifest.
  local root = M.node(manifest_value(spec.root))
  local opts = {}
  for key, value in pairs(spec) do if key ~= "root" then opts[key] = copy(value) end end
  if not serializable(opts) then fail("site options must be serializable", 2) end
  local by_id, endpoints, actions, by_action_id = compile_site(root)
  return setmetatable({
    root = root,
    opts = opts,
    _by_id = by_id,
    _endpoints = endpoints,
    _actions = actions,
    _actions_by_id = by_action_id,
  }, Site)
end

function Site:get(id)
  local value = self._by_id[id]
  return value and public_node(value) or nil
end

function Site:manifest()
  return { root = manifest_value(self.root), opts = copy(self.opts) }
end

function Site:endpoints()
  local out = {}
  for index, endpoint in ipairs(self._endpoints) do
    out[index] = { id = endpoint.id, path = endpoint.path }
  end
  return out
end

--- Return explicitly marked, literal, loader-free GET paths in stable order.
--- Dynamic pages and unmarked routes are never exported implicitly.
---@return string[]
function Site:prerender_paths()
  local out = {}
  for _, endpoint in ipairs(self._endpoints) do
    if endpoint.node.prerender then out[#out + 1] = endpoint.path end
  end
  table.sort(out)
  return out
end

function Site:action_endpoints()
  local out = {}
  for index, action in ipairs(self._actions) do out[index] = copy(action) end
  return out
end

function Site:get_action(id)
  local action = self._actions_by_id[id]
  return action and copy(action) or nil
end

local function resolve_optional(resolve, declaration, kind, node, target)
  if declaration == nil then return nil end
  local id = declaration
  if type(declaration) == "table" then
    id = declaration[target] or declaration.default
    if id == nil then return nil end
  end
  local value = resolve(id, kind, node)
  if value == nil then
    fail("resolver returned nil for " .. kind .. " " .. string.format("%q", id)
      .. " on node " .. string.format("%q", node.id), 4)
  end
  return value
end

function Site:routes(resolve, target)
  if type(resolve) ~= "function" then
    fail("site:routes(resolve) requires a logical screen resolver", 2)
  end
  local resolved_nodes = {}
  for id, node in pairs(self._by_id) do
    local resolved = {}
    for key, value in pairs(node) do resolved[key] = value end
    resolved.component = resolve_optional(resolve, node.screen, "screen", node, target)
    resolved.pending_component = resolve_optional(resolve, node.pending, "pending screen", node, target)
    resolved.error_component = resolve_optional(resolve, node.error, "error screen", node, target)
    resolved_nodes[id] = resolved
  end

  local routes = {}
  for index, endpoint in ipairs(self._endpoints) do
    local chain = {}
    for depth, node in ipairs(endpoint.chain) do chain[depth] = resolved_nodes[node.id] end
    routes[index] = {
      id = endpoint.id,
      path = endpoint.path,
      component = resolved_nodes[endpoint.id].component,
      meta = { chain = chain, component = resolved_nodes[endpoint.id].component },
    }
  end
  return routes
end

function Site:create_router(opts)
  opts = opts or {}
  if type(opts) ~= "table" then fail("site:create_router expects an options table", 2) end
  local resolve = opts.resolve
  local router_opts = {}
  for key, value in pairs(opts) do if key ~= "resolve" and key ~= "target" then router_opts[key] = value end end
  router_opts.routes = self:routes(resolve, opts.target)
  router_opts.site = self
  return router.create_router(router_opts)
end

Site.createRouter = Site.create_router
M.Site = Site
M.create = M.site

return M
