--[[ Optional Meteorite lowering for a serializable Hydronium Router site. ]]

local H = require("hydronium.core")
local site_mod = require("hydronium_router.site")
local memory = require("hydronium_router.history.memory")
local outlet = require("hydronium_router.outlet")

local M = {}

local function fail(message, level)
  error("hydronium_router.meteorite: " .. message, level or 3)
end

local function require_site(site)
  if type(site) ~= "table" or getmetatable(site) ~= site_mod.Site then
    fail("expected a site returned by hydronium_router.site(...) ", 3)
  end
end

local function app_route_rows(app)
  return type(app) == "table" and type(app.routes) == "table" and app.routes or {}
end

local function collision(app, id, method, path)
  for _, route in ipairs(app_route_rows(app)) do
    local existing_method = tostring(route.method or ""):upper()
    if route.id == id then
      return "route id " .. string.format("%q", id) .. " is already used by "
        .. existing_method .. " " .. string.format("%q", tostring(route.raw_path or route.path))
    end
    if existing_method == method and (route.raw_path or route.path) == path then
      return method .. " " .. string.format("%q", path) .. " is already declared"
    end
  end
  return nil
end

--- Lower every addressable leaf endpoint to an explicit Meteorite GET declaration.
---
--- The caller provides a normal Meteorite Lua-file handler descriptor,
--- usually `meteorite.lua("app.page_handler", { arg_mode = "lazy_context" })`.
--- We intentionally do not synthesize a catch-all: API and asset routes
--- continue to be ordinary Meteorite declarations.
function M.mount(app, site, opts)
  opts = opts or {}
  require_site(site)
  if type(app) ~= "table" or type(app.get) ~= "function" then
    fail("mount(app, site, opts) requires a Meteorite app with app:get", 2)
  end
  if opts.handler == nil then
    fail("mount requires opts.handler: pass a normal Meteorite Lua module handler", 2)
  end

  local pages = site:endpoints()
  local mounted = {}
  for i = 1, #pages do
    local page = pages[i]
    local problem = collision(app, page.id, "GET", page.path)
    if problem then fail("cannot mount page " .. string.format("%q", page.id) .. ": " .. problem, 2) end
    local spec = { id = page.id, route = page.path, handler = opts.handler }
    if opts.metadata then spec.metadata = opts.metadata end
    mounted[i] = app:get(spec)
  end
  local actions = site:action_endpoints()
  if #actions > 0 and opts.action_handler == nil then
    fail("site declares actions; mount requires opts.action_handler", 2)
  end
  for _, action in ipairs(actions) do
    local problem = collision(app, action.id, action.method, action.path)
    if problem then fail("cannot mount action " .. string.format("%q", action.id) .. ": " .. problem, 2) end
    local declare = app[string.lower(action.method)]
    if type(declare) ~= "function" then
      fail("Meteorite app does not support " .. action.method .. " for action " .. string.format("%q", action.id), 2)
    end
    local spec = {
      id = action.id,
      route = action.path,
      handler = opts.action_handler,
      metadata = { hydronium_action = action },
    }
    mounted[#mounted + 1] = declare(app, spec)
  end
  return mounted
end

--- Verify the final app declaration list still agrees with the site.
--- Call this after all routes are declared, before Meteorite normalizes its
--- graph. It catches a later manual page collision without reaching into
--- Meteorite internals.
function M.validate_final(app, site)
  require_site(site)
  local seen_ids, seen_routes = {}, {}
  for _, route in ipairs(app_route_rows(app)) do
    local method = tostring(route.method or ""):upper()
    local path = route.raw_path or route.path
    if route.id ~= nil and seen_ids[route.id] then
      fail("final app has duplicate route id " .. string.format("%q", tostring(route.id)), 2)
    end
    local key = method .. " " .. tostring(path)
    if seen_routes[key] then
      fail("final app has duplicate route " .. string.format("%q", key), 2)
    end
    if route.id ~= nil then seen_ids[route.id] = route end
    seen_routes[key] = route
  end
  for _, action in ipairs(site:action_endpoints()) do
    local route = seen_ids[action.id]
    if not route or tostring(route.method or ""):upper() ~= action.method
      or (route.raw_path or route.path) ~= action.path then
      fail("final app no longer contains action " .. string.format("%q", action.id)
        .. " at " .. action.method .. " " .. string.format("%q", action.path), 2)
    end
  end
  for _, page in ipairs(site:endpoints()) do
    local route = seen_ids[page.id]
    if not route or (route.raw_path or route.path) ~= page.path then
      fail("final app no longer contains page " .. string.format("%q", page.id)
        .. " at " .. string.format("%q", page.path), 2)
    end
  end
  return true
end

local function context_value(c, name)
  if type(c) ~= "table" then return nil end
  local value = c[name]
  if type(value) == "function" then
    local ok, result = pcall(value, c)
    if ok then return result end
  end
  return value
end

local function request_target(c)
  local target = context_value(c, "target") or context_value(c, "url")
  if type(target) == "string" and target ~= "" then return target end
  local path = context_value(c, "path")
  if type(path) == "string" and path ~= "" then return path end
  return "/"
end

local function escape_html(value)
  return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
    :gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
end

--- Safe, minimal HTML response for native forms when no app-specific
--- progressive renderer is configured. The caller can replace it through
--- action_handler({ progressive = ... }).
function M.progressive_fallback(c, outcome, action)
  local title = outcome.ok and "Action complete" or "Check your submission"
  local lines = { "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>",
    title, "</title><main><h1>", title, "</h1>" }
  local fields = {}
  for field in pairs(outcome.errors or {}) do fields[#fields + 1] = field end
  table.sort(fields)
  if #fields > 0 then
    lines[#lines + 1] = "<ul>"
    for _, field in ipairs(fields) do
      for _, message in ipairs(outcome.errors[field]) do
        lines[#lines + 1] = "<li>" .. escape_html(message) .. "</li>"
      end
    end
    lines[#lines + 1] = "</ul>"
  end
  local back = action and action.return_to or "/"
  if type(back) ~= "string" or back:sub(1, 1) ~= "/" or back:sub(1, 2) == "//" then back = "/" end
  lines[#lines + 1] = '<p><a href="' .. escape_html(back) .. '">Back</a></p></main></html>'
  return c:bytes(outcome.status or (outcome.ok and 200 or 422), "text/html; charset=utf-8", table.concat(lines))
end

--- Build the function exported by a Meteorite Lua-file page handler.
---
--- `render(c, vnode, opts)` is injected so the router package has no hard
--- dependency on hydronium-dom. `hydronium_dom.server.meteorite.render` is
--- the expected production implementation.
function M.handler(site, opts)
  opts = opts or {}
  require_site(site)
  if type(opts.resolve) ~= "function" then
    fail("handler requires opts.resolve, usually `require`", 2)
  end
  if type(opts.render) ~= "function" then
    fail("handler requires opts.render(c, vnode, opts), usually hydronium_dom.server.meteorite.render", 2)
  end

  return function(c)
    local target = request_target(c)
    local router = site:create_router({
      history = memory.create_memory_history({ initial = target }),
      resolve = opts.resolve,
      resolve_loader = opts.resolve_loader,
      execute = opts.execute,
      request = c,
      services = type(opts.services) == "function" and opts.services(c) or opts.services,
      base = opts.base,
      target = opts.target or "dom",
    })
    local matched = router.match()
    local route_id = context_value(c, "route_id")
    if route_id ~= nil and (not matched or matched.id ~= route_id) then
      fail("Meteorite selected route " .. string.format("%q", tostring(route_id))
        .. " but Hydronium site selected " .. string.format("%q", matched and matched.id or "<none>")
        .. " for " .. string.format("%q", target), 2)
    end
    if not matched then
      fail("no site endpoint matches Meteorite request " .. string.format("%q", target), 2)
    end
    local redirect = router.redirect()
    if redirect then
      if type(opts.redirect) ~= "function" then
        fail("loader for " .. string.format("%q", matched.id)
          .. " returned a redirect but handler opts.redirect is not configured", 2)
      end
      return opts.redirect(c, redirect)
    end

    local chain, route_data, status = router.matches(), {}, 200
    local route_ids = {}
    for index, node in ipairs(chain) do
      route_ids[index] = node.id
      if node.load then
        local resource = router.route_data(node.id)
        if resource:ready() then
          route_data[node.load.key or node.id] = { status = "ready", value = resource:value() }
        elseif resource:error() then
          local failure = resource:error()
          status = failure.status or 500
          route_data[node.load.key or node.id] = { status = "error", error = failure }
        end
      end
      if node.status ~= nil then status = node.status end
    end
    local vnode = H.h(router.Provider, { value = router }, H.h(outlet.Outlet))
    return opts.render(c, vnode, {
      status = status,
      state = {
        hydronium_router = {
          version = 1,
          canonical_url = router.location().href,
          location = router.location(),
          route_id = matched.id,
          route_chain = route_ids,
          params = router.params_snapshot(),
          resources = route_data,
        },
      },
    })
  end
end

--- Build the shared Meteorite handler used by route-owned action endpoints.
--- Action modules receive one table with `request`, `action`, `values`, and
--- `params`, then return a Hydronium action outcome.
function M.action_handler(site, opts)
  opts = opts or {}
  require_site(site)
  if type(opts.resolve_action) ~= "function" then
    fail("action_handler requires opts.resolve_action, usually `require`", 2)
  end

  return function(c)
    local action_id = context_value(c, "route_id")
    local action = site:get_action(action_id)
    if not action then fail("Meteorite selected unknown Hydronium action " .. string.format("%q", tostring(action_id)), 2) end
    local implementation = opts.resolve_action(action.ref, action, c)
    if type(implementation) ~= "function" then
      fail("action resolver returned " .. type(implementation) .. " for " .. string.format("%q", action.ref), 2)
    end

    local parser = action.encoding == "json" and c.json_body or c.form_body
    if type(parser) ~= "function" then
      fail("Meteorite context cannot parse " .. action.encoding .. " action bodies", 2)
    end
    local values, parse_error = parser(c)
    if values == nil then
      local outcome = { ok = false, status = 400, errors = { _form = { tostring(parse_error or "invalid request body") } } }
      local accept = type(c.header) == "function" and (c:header("accept") or "") or ""
      if accept:find("application/json", 1, true) then return c:json(400, outcome) end
      return (opts.progressive or M.progressive_fallback)(c, outcome, action)
    end

    local outcome = implementation({
      request = c,
      action = action,
      values = values,
      params = context_value(c, "params") or {},
      services = type(opts.services) == "function" and opts.services(c) or opts.services,
    })
    if type(outcome) ~= "table" or type(outcome.ok) ~= "boolean" then
      fail("action " .. string.format("%q", action.id) .. " must return a Hydronium action outcome", 2)
    end
    local status = outcome.status or (outcome.ok and 200 or 422)
    local accept = type(c.header) == "function" and (c:header("accept") or "") or ""
    local enhanced = accept:find("application/json", 1, true) ~= nil
    if enhanced then return c:json(status, outcome) end
    if outcome.redirect then return c:redirect(303, outcome.redirect) end
    return (opts.progressive or M.progressive_fallback)(c, outcome, action)
  end
end

return M
