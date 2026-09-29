-- Render default or named screens from the current matched chain.
local H = require("hydronium.core")
local router_mod = require("hydronium_router.router")

local M = {}

local function callable(value)
  if type(value) == "function" then return true end
  if type(value) ~= "table" then return false end
  local mt = getmetatable(value)
  return mt ~= nil and mt.__call ~= nil
end

local function render_component(component, props)
  if component == nil then return nil end
  if type(component) == "table" and component._typeof == H.symbols.VNODE then return component end
  if not callable(component) then
    error("hydronium_router.Outlet: resolved screen is not a component", 0)
  end
  return H.h(component, props)
end

local function nearest_error(router, depth, chain)
  for failed_depth = depth, #chain do
    local node = chain[failed_depth]
    if node.load then
      local ok, resource = pcall(router.route_data, node.id)
      local failure = ok and resource:error() or nil
      if failure ~= nil then
        for boundary_depth = failed_depth, depth, -1 do
          if chain[boundary_depth].error_component ~= nil then
            return boundary_depth, failure
          end
        end
        if failed_depth == depth then return depth, failure end
      end
    end
  end
  return nil, nil
end

local function fallback(props, router)
  local value = props and props.notFound
  if value == nil then return nil end
  return render_component(value, { location = router.location() })
end

function M.Outlet(props)
  local router = H.useContext(router_mod.RouterContext)
  local depth = H.useContext(router_mod.OutletDepthContext) or 1
  if router == nil then
    error("hydronium_router.Outlet: no router in context; wrap the tree in router.Provider", 0)
  end

  return function(current_props)
    current_props = current_props or props or {}
    local name = current_props.name
    if name == "default" then name = nil end
    if name ~= nil and (type(name) ~= "string" or not name:match("^[%a_][%w_%-]*$")) then
      error("hydronium_router.Outlet: name must be a portable slot identifier", 0)
    end
    local render_depth = depth
    local node = router.route_at(render_depth)
    if name then
      while node and not (node.slot_components and node.slot_components[name]) do
        render_depth = render_depth + 1
        node = router.route_at(render_depth)
      end
    end
    if node == nil then
      if name then return render_component(current_props.fallback, { location = router.location() }) or H.createTextVNode("") end
      if depth == 1 then return fallback(current_props, router) end
      return nil
    end

    local chain = router.matches()
    local boundary_depth, failure
    if name or node.error_component then
      boundary_depth, failure = nearest_error(router, depth, chain)
    elseif node.load then
      local resource = router.route_data(node.id)
      failure = resource:error()
      if failure ~= nil then boundary_depth = render_depth end
    end
    local error_node = boundary_depth and chain[boundary_depth]
    if error_node and error_node.error_component and boundary_depth <= render_depth then
      local body = render_component(error_node.error_component, {
        key = router.scope_identity(error_node) .. (name and ("\1slot:" .. name) or ""),
        error = failure,
        route = error_node, slot = name,
      })
      return H.h(router_mod.RouteContext.Provider, { value = error_node }, body)
    elseif failure and render_depth == #chain and not node.error_component then
      error(failure, 0)
    end

    for index = (name and depth or render_depth), render_depth do
      local pending_node = chain[index]
      if pending_node.load then
        local resource = router.route_data(pending_node.id)
        if resource:pending() and pending_node.pending_component then
          return H.h(router_mod.RouteContext.Provider, { value = pending_node },
            render_component(pending_node.pending_component, {
              key = router.scope_identity(pending_node) .. (name and ("\1slot:" .. name) or ""),
              route = pending_node, slot = name,
            }))
        end
      end
    end

    local child = H.h(M.Outlet, { name = name, fallback = current_props.fallback, notFound = current_props.notFound })
    local outlets = {}
    for index = render_depth + 1, #chain do
      for slot in pairs(chain[index].slot_components or {}) do
        if not outlets[slot] then outlets[slot] = H.h(M.Outlet, { name = slot }) end
      end
    end
    local body
    local component = name and node.slot_components[name] or node.component
    if component then
      body = render_component(component, {
        key = router.scope_identity(node) .. (name and ("\1slot:" .. name) or ""),
        route = node,
        outlet = child,
        outlets = outlets,
        slot = name,
      })
    else
      body = child
    end
    return H.h(router_mod.RouteContext.Provider, { value = node },
      H.h(router_mod.OutletDepthContext.Provider, { value = render_depth + 1 }, body))
  end
end

setmetatable(M, { __call = function(_, ...) return M.Outlet(...) end })
return M
