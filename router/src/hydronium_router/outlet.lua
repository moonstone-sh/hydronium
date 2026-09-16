-- Render one level of the current matched chain.
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
    local node = router.route_at(depth)
    if node == nil then
      if depth == 1 then return fallback(current_props, router) end
      return nil
    end

    local chain = router.matches()
    local boundary_depth, failure
    if node.error_component then
      boundary_depth, failure = nearest_error(router, depth, chain)
    elseif node.load then
      local resource = router.route_data(node.id)
      failure = resource:error()
      if failure ~= nil then boundary_depth = depth end
    end
    if boundary_depth == depth and node.error_component then
      return render_component(node.error_component, {
        key = router.scope_identity(node),
        error = failure,
        route = node,
      })
    elseif failure and depth == #chain and not node.error_component then
      error(failure, 0)
    end

    if node.load then
      local resource = router.route_data(node.id)
      if resource:pending() and node.pending_component then
        return render_component(node.pending_component, {
          key = router.scope_identity(node),
          route = node,
        })
      end
    end

    local child = H.h(router_mod.OutletDepthContext.Provider, { value = depth + 1 },
      H.h(M.Outlet, current_props))
    local body
    if node.component then
      body = render_component(node.component, {
        key = router.scope_identity(node),
        route = node,
        outlet = child,
      })
    else
      body = child
    end
    return H.h(router_mod.RouteContext.Provider, { value = node }, body)
  end
end

setmetatable(M, { __call = function(_, ...) return M.Outlet(...) end })
return M
