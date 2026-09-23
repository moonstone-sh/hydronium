-- Host-neutral reactive routing over a resolved, serializable route tree.
local H = require("hydronium.core")
local url = require("hydronium_router.url")
local matcher = require("hydronium_router.matcher")
local href_mod = require("hydronium_router.href")
local history_mod = require("hydronium_router.history")
local route_resource = require("hydronium_router.resource")
local result_mod = require("hydronium_router.result")
local hydration_state = require("hydronium_router.state")

local M = {}

M.RouterContext = H.createContext(nil)
M.RouteContext = H.createContext(nil)
M.OutletDepthContext = H.createContext(1)

local function shallow_copy(value)
  local out = {}
  for key, item in pairs(value or {}) do out[key] = item end
  return out
end

local function normalize_base(base)
  if base == nil then return "/" end
  if type(base) ~= "string" then
    error("hydronium_router.create_router: base must be a string", 3)
  end
  return url.normalize_path(base)
end

local function strip_base(base, path)
  if base == "/" then return path end
  if path == base then return "/" end
  if path:sub(1, #base + 1) == base .. "/" then return path:sub(#base + 1) end
  return nil
end

local function with_base(base, target)
  if base ~= "/" and target:sub(1, 1) == "/" then return base .. target end
  return target
end

local function sync_signal_map(map, values)
  for key, value in pairs(values) do
    local signal = map[key]
    if signal then signal:set(value) else map[key] = H.createSignal(value) end
  end
  for key, signal in pairs(map) do
    if values[key] == nil then signal:set(nil) end
  end
end

local function make_proxy(map, label)
  return setmetatable({}, {
    __index = function(_, key)
      if type(key) ~= "string" then return nil end
      local signal = map[key]
      if not signal then
        signal = H.createSignal(nil)
        map[key] = signal
      end
      return signal:get()
    end,
    __newindex = function(_, key)
      error("hydronium_router: " .. label .. " is read-only; cannot assign " .. tostring(key), 2)
    end,
    __tostring = function()
      return "hydronium_router." .. label .. " (reactive proxy; snapshot it before iteration)"
    end,
  })
end

--- The chain of nodes Outlet renders, innermost last.
---
--- `site()` builds a real nesting and records it as `meta.chain`. A FLAT
--- `routes` declaration passed straight to `create_router` has no nesting and
--- so no chain, and the fallback must then produce something Outlet can
--- actually render -- it reads `node.component` (plus optional `node.load`
--- and `node.error_component`).
---
--- The caller's own declaration is that node: create_router stores
--- `declaration.meta or declaration` as the route's meta, so for a flat
--- declaration the meta IS the table the caller wrote, `component` and all.
--- The matcher's internal record is NOT -- it carries id/path/pattern/meta
--- and no component. Returning the record, as this did, meant Outlet read a
--- nil component and `render_component` returned nil for it WITHOUT error:
--- the page rendered nothing at all, while `router.match().id` still
--- reported the right route, so everything looked correct from the outside.
--- Silent, and only on the flat path -- every existing spec goes through
--- site(), which is why nothing caught it.
local function match_chain(match_result)
  if not match_result then return {} end
  local meta = match_result.route.meta
  local chain = meta and meta.chain
  if type(chain) == "table" then return chain end
  if type(meta) == "table" then return { meta } end
  return { match_result.route }
end

local function node_scope_identity(node, params)
  if node.reuse == "keep" then return node.id end
  local parts = { node.id }
  for _, name in ipairs(node.own_params or {}) do
    parts[#parts + 1] = name .. "=" .. tostring(params[name])
  end
  return table.concat(parts, "\1")
end

local function normalized_error(err, node)
  if result_mod.kind(err) == "error" then
    if err.route_id == nil then err.route_id = node.id end
    return err
  end
  return {
    _hydronium_route_result = "error",
    status = 500,
    kind = "loader_error",
    message = tostring(err),
    cause = err,
    route_id = node.id,
  }
end

local function default_executor(resolve_loader)
  return function(descriptor, context, done)
    if type(resolve_loader) ~= "function" then
      done(nil, "no loader executor or resolve_loader function was provided for "
        .. string.format("%q", descriptor.ref))
      return nil
    end
    local loader = resolve_loader(descriptor.ref, "loader", context.route)
    if type(loader) ~= "function" then
      done(nil, "loader resolver returned " .. type(loader) .. " for "
        .. string.format("%q", descriptor.ref))
      return nil
    end
    local callback_called = false
    local function settle(value, failure)
      callback_called = true
      done(value, failure)
    end
    local ok, value = pcall(loader, context, settle)
    if not ok then done(nil, value); return nil end
    if type(value) == "function" then return value end
    if not callback_called then done(value, nil) end
    return nil
  end
end

--- Internal resolved-route constructor. Public applications use site/node.
function M.route(id, path, component, opts)
  opts = shallow_copy(opts)
  opts.component = component
  return { id = id, path = path, component = component, meta = opts }
end

---@param opts table
---@return table router
function M.create_router(opts)
  opts = opts or {}
  if type(opts) ~= "table" then error("hydronium_router.create_router expects a table", 2) end
  if opts.history == nil then error("hydronium_router.create_router requires opts.history", 2) end
  if type(opts.routes) ~= "table" then error("hydronium_router.create_router requires resolved routes", 2) end

  local history = history_mod.validate(opts.history, "create_router opts.history")
  local base = normalize_base(opts.base)
  local routes = opts.routes
  local route_matcher = matcher.new()
  for index, declaration in ipairs(routes) do
    if type(declaration) ~= "table" or type(declaration.id) ~= "string"
      or type(declaration.path) ~= "string" then
      error("hydronium_router.create_router: routes[" .. index .. "] is invalid", 2)
    end
    route_matcher:add(declaration.id, declaration.path, declaration.meta or declaration)
  end

  local seed = H.untrack(function() return history.current() end)
  local seed_relative = strip_base(base, seed.path)
  local seed_result = seed_relative and route_matcher:match(seed_relative) or nil
  local seed_chain = match_chain(seed_result)

  local location_sig = H.createSignal(seed)
  local leaf_sig = H.createSignal(seed_result and seed_result.route or nil)
  local chain_sigs = {}
  for depth, node in ipairs(seed_chain) do chain_sigs[depth] = H.createSignal(node) end
  local chain_length_sig = H.createSignal(#seed_chain)
  local param_sigs, query_sigs = {}, {}
  for key, value in pairs(seed_result and seed_result.params or {}) do param_sigs[key] = H.createSignal(value) end
  for key, value in pairs(seed.query or {}) do query_sigs[key] = H.createSignal(value) end

  local params_proxy = make_proxy(param_sigs, "params")
  local search_proxy = make_proxy(query_sigs, "search_params")
  local navigation_state_sig = H.createSignal("idle")
  local navigation_location_sig = H.createSignal(nil)
  local redirect_sig = H.createSignal(nil)
  local transition_id = 0
  local current_transition = nil
  local resources = {}
  local initializing = true
  local executor = opts.execute or default_executor(opts.resolve_loader)
  if type(executor) ~= "function" then error("hydronium_router: execute must be a function", 2) end

  local router = {}

  local function resource_for(node, params, force_new)
    if not node.load then return nil end
    local identity = node_scope_identity(node, params)
    local existing = resources[node.id]
    if not force_new and existing and existing.identity == identity then return existing end
    local resource = route_resource.new({
      status = "idle",
      route_id = node.id,
      key = node.load.key or node.id,
      identity = identity,
    })
    resources[node.id] = resource
    return resource
  end

  local function initialize_resource(resource, status, value, failure)
    resource._status._signal.value = status
    resource._value._signal.value = value
    resource._error._signal.value = failure
  end

  local function cancel_transition()
    local transition = current_transition
    if not transition then return end
    transition.cancelled = true
    for _, cancel in ipairs(transition.cancels) do pcall(cancel) end
    current_transition = nil
  end

  local function start_loaders(chain, params, loc, reason)
    cancel_transition()
    transition_id = transition_id + 1
    local transition = {
      id = transition_id,
      cancelled = false,
      cancels = {},
      chain = chain,
      location = loc,
      reason = reason,
    }
    current_transition = transition
    redirect_sig._signal.value = nil

    local loading = false
    for _, node in ipairs(chain) do if node.load then loading = true break end end
    if initializing then
      navigation_state_sig._signal.value = loading and "loading" or "idle"
      navigation_location_sig._signal.value = loading and loc or nil
    else
      H.batch(function()
        redirect_sig:set(nil)
        navigation_state_sig:set(loading and "loading" or "idle")
        navigation_location_sig:set(loading and loc or nil)
      end)
    end

    local index = 1
    local function finish()
      if current_transition ~= transition or transition.cancelled then return end
      current_transition = nil
      if initializing then
        navigation_state_sig._signal.value = "idle"
        navigation_location_sig._signal.value = nil
      else
        H.batch(function()
          navigation_state_sig:set("idle")
          navigation_location_sig:set(nil)
        end)
      end
    end

    local run_next
    run_next = function()
      if current_transition ~= transition or transition.cancelled then return end
      local node
      while index <= #chain do
        node = chain[index]
        index = index + 1
        if node.load then break end
        node = nil
      end
      if not node then finish(); return end

      local resource = resource_for(node, params, false)
      if initializing then initialize_resource(resource, "pending", nil, nil) else resource:set_pending() end
      local settled = false
      local context = {
        route = node,
        route_id = node.id,
        descriptor = node.load,
        location = loc,
        params = shallow_copy(params),
        search = shallow_copy(loc.query),
        transition_id = transition.id,
        reason = reason,
        request = opts.request,
        services = opts.services,
        parent = function(id)
          local parent_resource = resources[id]
          return parent_resource and parent_resource:value() or nil
        end,
        cancelled = function() return transition.cancelled end,
      }

      local function done(value, failure)
        if settled then return end
        settled = true
        if current_transition ~= transition or transition.cancelled then return end
        local kind = result_mod.kind(value)
        if failure ~= nil then
          local err = normalized_error(failure, node)
          if initializing then initialize_resource(resource, "error", nil, err) else resource:reject(err) end
          finish()
          return
        elseif kind == "redirect" then
          if initializing then redirect_sig._signal.value = value else redirect_sig:set(value) end
          finish()
          if not initializing then history.replace(with_base(base, value.to), nil) end
          return
        elseif kind == "error" then
          local err = normalized_error(value, node)
          if initializing then initialize_resource(resource, "error", nil, err) else resource:reject(err) end
          finish()
          return
        end
        if initializing then initialize_resource(resource, "ready", value, nil) else resource:resolve(value) end
        run_next()
      end

      local ok, cancel_or_error = pcall(executor, node.load, context, done)
      if not ok then done(nil, cancel_or_error)
      elseif not settled and type(cancel_or_error) == "function" then
        transition.cancels[#transition.cancels + 1] = cancel_or_error
      end
    end

    run_next()
  end

  local function sync_chain_signals(chain)
    local previous_length = chain_length_sig._signal.value
    for depth = 1, math.max(previous_length, #chain) do
      local signal = chain_sigs[depth]
      if not signal then
        signal = H.createSignal(nil)
        chain_sigs[depth] = signal
      end
      signal:set(chain[depth])
    end
    chain_length_sig:set(#chain)
  end

  local function apply_location(loc)
    local relative = strip_base(base, loc.path)
    local matched = relative and route_matcher:match(relative) or nil
    local chain = match_chain(matched)
    local params = matched and matched.params or {}
    H.batch(function()
      location_sig:set(loc)
      leaf_sig:set(matched and matched.route or nil)
      sync_chain_signals(chain)
      sync_signal_map(param_sigs, params)
      sync_signal_map(query_sigs, loc.query or {})
    end)
    start_loaders(chain, params, loc, "navigation")
  end

  local hydrated = false
  local hydration = opts.hydration or rawget(_G, "__hydronium_router_state")
  if hydration ~= nil then
    hydration = hydration_state.decode(hydration)
    local same_location = hydration.canonical_url == seed.href
    local same_chain = #hydration.route_chain == #seed_chain
    for depth, node in ipairs(seed_chain) do
      if hydration.route_chain[depth] ~= node.id then same_chain = false; break end
    end
    if same_location and same_chain and hydration.route_id == (seed_result and seed_result.route.id) then
      hydrated = true
      for _, node in ipairs(seed_chain) do
        if node.load then
          local entry = hydration.resources[node.load.key or node.id]
          if type(entry) ~= "table" or (entry.status ~= "ready" and entry.status ~= "error") then
            hydrated = false
            break
          end
          local resource = resource_for(node, seed_result and seed_result.params or {}, false)
          initialize_resource(resource, entry.status, entry.value, entry.error)
        end
      end
    end
  end

  -- Seed route resources before the router is exposed. Raw initialization is
  -- intentional: create_router may run during component setup, where signal
  -- writes are forbidden, and no observer can exist yet.
  if not hydrated then start_loaders(seed_chain, seed_result and seed_result.params or {}, seed, "initial") end
  initializing = false

  local first_history_effect = true
  H.createEffect(function()
    local current = history.current()
    if first_history_effect then first_history_effect = false; return end
    apply_location(current)
  end)
  H.onCleanup(function()
    cancel_transition()
    history.dispose()
  end)

  router.history = history
  router.matcher = route_matcher
  router.base = base
  router.params = params_proxy
  router.search_params = search_proxy
  router.resources = resources

  function router.location() return location_sig:get() end
  function router.match() return leaf_sig:get() end
  function router.route_at(depth)
    local signal = chain_sigs[depth]
    return signal and signal:get() or nil
  end
  function router.matches()
    local out = {}
    local length = chain_length_sig:get()
    for depth = 1, length do out[depth] = chain_sigs[depth]:get() end
    return out
  end
  function router.params_snapshot()
    leaf_sig:get()
    local out = {}
    for key, signal in pairs(param_sigs) do
      local value = signal:get()
      if value ~= nil then out[key] = value end
    end
    return out
  end
  function router.search_snapshot()
    location_sig:get()
    local out = {}
    for key, signal in pairs(query_sigs) do
      local value = signal:get()
      if value ~= nil then out[key] = value end
    end
    return out
  end
  function router.route_data(id)
    local resource = resources[id]
    if not resource then
      error("hydronium_router: route " .. string.format("%q", tostring(id))
        .. " has no active loader resource", 2)
    end
    return resource
  end
  function router.navigation()
    return {
      state = function() return navigation_state_sig:get() end,
      location = function() return navigation_location_sig:get() end,
      transition_id = function() return transition_id end,
    }
  end
  function router.redirect() return redirect_sig:get() end
  function router.revalidate()
    local loc = location_sig:get()
    local relative = strip_base(base, loc.path)
    local matched = relative and route_matcher:match(relative) or nil
    start_loaders(match_chain(matched), matched and matched.params or {}, loc, "revalidation")
  end
  function router.navigate(to, nav)
    if type(to) ~= "string" then error("hydronium_router.navigate expects a string", 2) end
    nav = nav or {}
    local target = with_base(base, to)
    if nav.replace then history.replace(target, nav.state) else history.push(target, nav.state) end
  end
  function router.href(id, params, query)
    local built = href_mod.href(route_matcher, id, params, query)
    return base == "/" and built or base .. built
  end
  function router.scope_identity(node)
    return node_scope_identity(node, router.params_snapshot())
  end
  function router.Provider(props)
    props = props or {}
    return H.h(M.RouterContext.Provider, { value = router },
      H.h(M.OutletDepthContext.Provider, { value = 1 }, props.children))
  end
  router.Context = M.RouterContext
  return router
end

M.create = M.create_router
M.createRouter = M.create_router
return M
