-- Context-backed Router hooks. These are deliberately thin: routing state
-- remains ordinary Hydronium signals owned by the router object.
local H = require("hydronium.core")
local router_module = require("hydronium_router.router")

local M = {}

local function current(name)
  local router = H.useContext(router_module.RouterContext)
  if router == nil then
    error("hydronium_router." .. name .. ": no router in context; wrap the tree in router.Provider", 3)
  end
  return router
end

function M.use_router()
  return current("use_router")
end

-- Call during the tracked render whose location changes should invalidate.
function M.use_location()
  return current("use_location").location()
end

function M.use_match()
  return current("use_match").match()
end

function M.use_matches()
  return current("use_matches").matches()
end

-- Stable proxies. Field reads subscribe to only the named parameter.
function M.use_params()
  return current("use_params").params
end

function M.use_search_params()
  return current("use_search_params").search_params
end

function M.use_navigate()
  return current("use_navigate").navigate
end

function M.use_href(id, params, query)
  return current("use_href").href(id, params, query)
end

function M.use_route_data(id)
  local active = current("use_route_data")
  if id == nil then
    local route = H.useContext(router_module.RouteContext)
    if route == nil then
      error("hydronium_router.use_route_data: no current route; pass a route id or call inside an Outlet screen", 2)
    end
    id = route.id
  end
  return active.route_data(id)
end

function M.use_navigation()
  return current("use_navigation").navigation()
end

function M.use_revalidator()
  return current("use_revalidator").revalidate
end

M.useRouter = M.use_router
M.useLocation = M.use_location
M.useMatch = M.use_match
M.useMatches = M.use_matches
M.useParams = M.use_params
M.useSearchParams = M.use_search_params
M.useNavigate = M.use_navigate
M.useHref = M.use_href
M.useRouteData = M.use_route_data
M.useNavigation = M.use_navigation
M.useRevalidator = M.use_revalidator

return M
