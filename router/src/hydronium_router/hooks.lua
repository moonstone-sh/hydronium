-- Context-backed Router hooks. These are deliberately thin: routing state
-- remains ordinary Hydronium signals owned by the router object.
local H = require("hydronium")
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

M.useRouter = M.use_router
M.useLocation = M.use_location
M.useMatch = M.use_match
M.useParams = M.use_params
M.useSearchParams = M.use_search_params
M.useNavigate = M.use_navigate
M.useHref = M.use_href

return M
