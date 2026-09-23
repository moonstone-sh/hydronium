--[[
  hydronium-router -- routing primitives for Hydronium.
  Version 0.1.0

  Pure matching primitives, History adapters, and the reactive Router,
  Outlet, and hooks share this public barrel.
--]]

local pattern = require("hydronium_router.pattern")
local url = require("hydronium_router.url")
local matcher = require("hydronium_router.matcher")
local href = require("hydronium_router.href")
local history = require("hydronium_router.history")
local memory_history = require("hydronium_router.history.memory")
local browser_history = require("hydronium_router.history.browser")
local router = require("hydronium_router.router")
local outlet = require("hydronium_router.outlet")
local hooks = require("hydronium_router.hooks")
local site = require("hydronium_router.site")
local route_resource = require("hydronium_router.resource")
local result = require("hydronium_router.result")
local state = require("hydronium_router.state")
local http = require("hydronium_router.http")
local topology = require("hydronium_router.topology")

local Router = {
  _VERSION = "0.1.0",
  _DESCRIPTION = "Host-neutral reactive routing for Hydronium",

  -- Modules
  pattern = pattern,
  url = url,
  matcher = matcher,
  history = history,
  hooks = hooks,
  site = site,
  Site = site.Site,
  RouterContext = router.RouterContext,
  RouteContext = router.RouteContext,
  Outlet = outlet.Outlet,
  RouteResource = route_resource.Resource,
  state = state,
  http = http,
  topology = topology,
  routes_from_topology = topology.routes,

  -- Pattern parsing
  parse_pattern = pattern.parse,
  more_specific = pattern.more_specific,

  -- URL codec
  encode = url.encode,
  decode = url.decode,
  split = url.split,
  parse_query = url.parse_query,
  build_query = url.build_query,
  normalize_path = url.normalize_path,

  -- Matching
  createMatcher = matcher.new,
  create_matcher = matcher.new,

  -- Link building
  href = href.href,

  -- History adapters
  createMemoryHistory = memory_history.create_memory_history,
  create_memory_history = memory_history.create_memory_history,
  createBrowserHistory = browser_history.create_browser_history,
  create_browser_history = browser_history.create_browser_history,
  validate_history = history.validate,
  to_location = history.to_location,

  -- Reactive router
  node = site.node,
  createSite = site.site,
  create_site = site.site,
  createRouter = router.create_router,
  create_router = router.create_router,
  useRouter = hooks.use_router,
  use_router = hooks.use_router,
  useLocation = hooks.use_location,
  use_location = hooks.use_location,
  useMatch = hooks.use_match,
  use_match = hooks.use_match,
  useMatches = hooks.use_matches,
  use_matches = hooks.use_matches,
  useParams = hooks.use_params,
  use_params = hooks.use_params,
  useSearchParams = hooks.use_search_params,
  use_search_params = hooks.use_search_params,
  useNavigate = hooks.use_navigate,
  use_navigate = hooks.use_navigate,
  useHref = hooks.use_href,
  use_href = hooks.use_href,
  useRouteData = hooks.use_route_data,
  use_route_data = hooks.use_route_data,
  useNavigation = hooks.use_navigation,
  use_navigation = hooks.use_navigation,
  useRevalidator = hooks.use_revalidator,
  use_revalidator = hooks.use_revalidator,

  redirect = result.redirect,
  routeError = result.error,
  route_error = result.error,
}

return Router
