--[[
  hydronium_router.router -- the reactive router object.

  This is the layer that binds the settled, pure primitives (pattern,
  url, matcher, href) to Hydronium's reactive graph and to a History.
  Everything above it -- `outlet`, the hooks -- reads this object and
  nothing else.

  --- WHY EVERY PIECE OF STATE HERE IS A PLAIN SIGNAL --------------------

  `hydronium.createSignal`'s setter short-circuits on equality:

      if equals(signal.value, resolvedVal) then return signal.value end

  `createComputed` has no such dedup -- it is push-dirty, so it
  re-notifies whenever any upstream source changes, whether or not its
  own value actually moved. That difference is load-bearing here, and it
  is the reason the "current matched route" is a `createSignal` that this
  module explicitly `:set()`s rather than a `createComputed` derived from
  the location:

      /users/1  ->  /users/2

  is a location change but NOT a route change. Because `_match_sig`
  stores the matcher's STABLE route record (`result.route`, the identical
  table `Matcher:add` stored, not the fresh per-match wrapper), setting it
  to the same record is an equality hit and notifies nobody. The Outlet,
  which reads only that signal, therefore does not re-render, while a
  binding reading `params.id` does. That is the fine-grained property
  this whole design exists to demonstrate, and it falls out of signal
  identity plus the equality short-circuit -- no diffing, no
  memoization layer.

  --- PARAM SIGNAL IDENTITY IS STABLE ------------------------------------

  Per-param signals are created lazily and then UPDATED IN PLACE. They are
  never recreated per navigation, because a subscriber (a binding, an
  effect, a component's render observer) is keyed to the signal object it
  read. Swapping in a fresh signal on every navigation would leave every
  existing subscriber attached to an orphan that nobody ever sets again --
  the classic "it works once then goes dead" reactive bug.

  A param signal is also created on first READ, not only on first match,
  so `params.id` read before that param has ever appeared still returns a
  live signal that fires when the param does appear.

  --- THE LuaJIT `__pairs` FOOTGUN ---------------------------------------

  `params` and `search_params` are PROXY tables: they hold no keys, and
  serve reads through `__index` by delegating to a signal. LuaJIT and Lua
  5.1 have NO `__pairs` metamethod, so

      for k, v in pairs(router.params) do ... end   -- SILENTLY ITERATES NOTHING

  It does not error. It does not warn. It runs zero iterations and you get
  an empty result that looks like "there were no params". There is no way
  to intercept this from Lua, so the mitigation is the explicit
  alternative: `router.params_snapshot()` and `router.search_snapshot()`
  return REAL plain tables that `pairs` iterates correctly (and that are
  themselves reactive -- they read through the signals, so calling one
  inside a render closure subscribes to the params it saw).

  Note also that no method is hung off the proxies themselves. A
  `params.snapshot()` method would collide with a route that legitimately
  declares a param named `snapshot`, and the collision would resolve in
  favour of the method -- a silent wrong answer. Snapshots live on the
  router, where nothing can shadow them.
--]]

local H = require("hydronium")

local url = require("hydronium_router.url")
local matcher = require("hydronium_router.matcher")
local href_mod = require("hydronium_router.href")
local history_mod = require("hydronium_router.history")

local M = {}

--- The context the Provider publishes and the hooks read. Module-level on
--- purpose: `useContext` matches on context object identity, so the hooks
--- and every Provider must share this one object. Per-router state lives
--- in the VALUE the Provider supplies, not in a per-router context.
M.RouterContext = H.createContext(nil)

--- A single route declaration.
---
--- D2: this is a plain function call, deliberately NOT a `.luax` `<Route>`
--- element. It is the only declaration form that reads identically in a
--- `.luax` web app, a plain-Lua Ink TUI and a native shell, and the only
--- one a future statically-typed-params tool can analyse without running
--- the JSX compiler first.
---
--- @param id string          dot-separated route id, unique in this router
--- @param path string        a route pattern (see `hydronium_router.pattern`)
--- @param component any      the component rendered by `Outlet` for this route
--- @param opts? table        route options, stored as the matcher's `meta`:
---
---   `.params` table
---       D1, bring-your-own validation: `{ id = function(raw) ... end }`.
---       A predicate returns a coerced value to accept the segment (the
---       returned value becomes `params.id`) or nil to reject it, in which
---       case matching falls through to the next candidate route. See
---       `hydronium_router.matcher` for the full contract.
---
---   `.reuse` "remount"|nil
---       D4. Default (nil) is STAY-MOUNTED: a param change keeps the
---       component instance alive and only the bindings that read the
---       changed param update, which is this framework's whole thesis.
---       `"remount"` opts into the other behaviour: `Outlet` then derives
---       a real `key` from the matched params, and because the reconciler's
---       `canReuse` compares `oldVNode.key == newVNode.key`, a param change
---       unmounts the old instance (running its `onCleanup`s) and mounts a
---       fresh one (re-running setup).
---
---   `.loader` any
---       D3, RESERVED AND NOT IMPLEMENTED. Stored verbatim as opaque
---       metadata on the route record and never read, called, or validated
---       by this package. It exists only so that a future data-loading
---       convention has a declared place to attach without a breaking
---       change to this declaration shape. Nothing in hydronium-router
---       invokes it today; do not rely on it doing anything.
---
---   any other key is carried through untouched on `route.meta`.
---
--- @return table declaration
function M.route(id, path, component, opts)
  if type(id) ~= "string" or id == "" then
    error("hydronium_router.route: id must be a non-empty string, got " .. type(id), 2)
  end
  if type(path) ~= "string" then
    error("hydronium_router.route: path for route " .. string.format("%q", id)
      .. " must be a string, got " .. type(path), 2)
  end
  if component == nil then
    error("hydronium_router.route: route " .. string.format("%q", id)
      .. " has no component -- pass the component to render for this route", 2)
  end
  if opts ~= nil and type(opts) ~= "table" then
    error("hydronium_router.route: opts for route " .. string.format("%q", id)
      .. " must be a table, got " .. type(opts), 2)
  end

  local meta = {}
  if opts then
    for k, v in pairs(opts) do meta[k] = v end
  end
  meta.component = component

  if meta.reuse ~= nil and meta.reuse ~= "remount" and meta.reuse ~= "keep" then
    error("hydronium_router.route: route " .. string.format("%q", id)
      .. " has reuse = " .. string.format("%q", tostring(meta.reuse))
      .. " -- the only accepted values are \"remount\" and \"keep\" (the default)", 2)
  end

  return { id = id, path = path, component = component, meta = meta }
end

--- Normalize a mount base to either "/" or a "/prefix" with no trailing slash.
local function normalize_base(base)
  if base == nil then return "/" end
  if type(base) ~= "string" then
    error("hydronium_router.create_router: base must be a string, got " .. type(base), 3)
  end
  return url.normalize_path(base)
end

--- Strip the mount base off an absolute path.
---
--- @return string|nil  the path relative to the base, or nil when the path
---   lies OUTSIDE the base -- which is a non-match, not a match at "/".
---   Returning "/" there would make a router mounted at "/admin" answer
---   for "/marketing", which is exactly the bug a base is meant to prevent.
local function strip_base(base, path)
  if base == "/" then return path end
  if path == base then return "/" end
  if path:sub(1, #base + 1) == base .. "/" then
    return path:sub(#base + 1)
  end
  return nil
end

--- Update a name -> signal map in place from a fresh table of values.
---
--- Three cases, and the third is the one that is easy to forget: a param
--- present in the previous match but absent from this one must be set to
--- nil, or a binding would keep displaying a value from a route that is no
--- longer matched.
local function sync_signal_map(map, values)
  for k, v in pairs(values) do
    local sig = map[k]
    if sig then
      sig:set(v)
    else
      map[k] = H.createSignal(v)
    end
  end

  for k, sig in pairs(map) do
    if values[k] == nil then
      sig:set(nil)
    end
  end
end

--- Build a read-only reactive proxy over a name -> signal map.
---
--- Reading an absent key CREATES its signal rather than returning nil
--- outright, so the read is tracked and the reader wakes up if that name
--- ever appears. See the `__pairs` warning in this module's header.
local function make_proxy(map, label)
  return setmetatable({}, {
    __index = function(_, key)
      if type(key) ~= "string" then return nil end
      local sig = map[key]
      if not sig then
        sig = H.createSignal(nil)
        map[key] = sig
      end
      return sig:get()
    end,

    __newindex = function(_, key, _)
      error("hydronium_router: " .. label .. " is read-only -- cannot assign "
        .. label .. "." .. tostring(key)
        .. ". Navigate instead (router.navigate / useNavigate).", 2)
    end,

    __tostring = function()
      return "hydronium_router." .. label
        .. " (reactive proxy; pairs() does NOT work on it -- use router."
        .. label .. "_snapshot())"
    end,
  })
end

--- Create a router.
---
--- @param opts table
---   `.history` table   a History (see `hydronium_router.history`). Required.
---   `.routes` table[]  array of `M.route(...)` declarations. Required.
---   `.base` string     mount prefix, default "/".
--- @return table router
function M.create_router(opts)
  opts = opts or {}

  if type(opts) ~= "table" then
    error("hydronium_router.create_router: expected an options table, got " .. type(opts), 2)
  end
  if opts.history == nil then
    error("hydronium_router.create_router: opts.history is required -- pass a History "
      .. "(hydronium_router.create_memory_history() for tests, Ink and native hosts; "
      .. "create_browser_history() in a browser)", 2)
  end

  local history = history_mod.validate(opts.history, "create_router opts.history")
  local base = normalize_base(opts.base)

  local routes = opts.routes
  if type(routes) ~= "table" then
    error("hydronium_router.create_router: opts.routes must be an array of route "
      .. "declarations, got " .. type(routes), 2)
  end

  local m = matcher.new()
  for i = 1, #routes do
    local decl = routes[i]
    if type(decl) ~= "table" then
      error("hydronium_router.create_router: routes[" .. i .. "] is a " .. type(decl)
        .. ", expected a declaration from hydronium_router.route(id, path, component, opts)", 2)
    end
    if decl.component == nil and not (decl.meta and decl.meta.component) then
      error("hydronium_router.create_router: routes[" .. i .. "] ("
        .. string.format("%q", tostring(decl.id)) .. ") has no component", 2)
    end
    -- Accept a bare table as well as a `route()` result; `route()` simply
    -- builds and validates this same shape.
    local meta = decl.meta
    if not meta then
      meta = {}
      for k, v in pairs(decl) do
        if k ~= "id" and k ~= "path" then meta[k] = v end
      end
    end
    m:add(decl.id, decl.path, meta)
  end

  -- Reactive state. All plain signals -- see the module header for why
  -- none of these is a createComputed.
  local seed = H.untrack(function() return history.current() end)
  local location_sig = H.createSignal(seed)
  local match_sig = H.createSignal(nil)
  local param_sigs = {}
  local query_sigs = {}

  local params_proxy = make_proxy(param_sigs, "params")
  local search_proxy = make_proxy(query_sigs, "search_params")

  local router = {}

  --- Resolve one Location into all the reactive state.
  ---
  --- The whole update is wrapped in `batch` so a single navigation is one
  --- reactive flush rather than one per signal touched.
  local function apply_location(loc)
    local relative = strip_base(base, loc.path)
    local result = relative and m:match(relative) or nil

    H.batch(function()
      location_sig:set(loc)
      -- The stable route RECORD, not the per-match wrapper table: this is
      -- what makes a param-only change dedup to "no route change".
      match_sig:set(result and result.route or nil)
      sync_signal_map(param_sigs, result and result.params or {})
      sync_signal_map(query_sigs, loc.query or {})
    end)
  end

  -- Seed synchronously, BEFORE the effect. Effects are suppressed
  -- entirely under SSR (`Effect.new` short-circuits when
  -- `scheduler.isSSR()`), so a router that only ever populated itself
  -- from its effect would render an empty Outlet on the server. Seeding
  -- here means the first render is correct in every host; the effect's
  -- own immediate run then dedups to a no-op.
  apply_location(seed)

  -- The single subscription to navigation. `history.current()` is a
  -- reactive read, so this effect re-runs on every push/replace/go with
  -- no router-specific subscription mechanism.
  H.createEffect(function()
    apply_location(history.current())
  end)

  -- A router created inside a component scope must release its history
  -- subscription when that component unmounts. Outside a scope this is a
  -- documented silent no-op in core (`scope.onCleanup`), so a
  -- module-level router is unaffected.
  H.onCleanup(function()
    history.dispose()
  end)

  ------------------------------------------------------------------
  -- Public surface
  ------------------------------------------------------------------

  router.history = history
  router.matcher = m
  router.base = base

  --- Reactive getter for the current Location.
  --- @return hydronium_router.Location
  function router.location()
    return location_sig:get()
  end

  --- Reactive getter for the matched ROUTE RECORD (or nil).
  --- Notifies only when the matched route actually changes -- not when
  --- its params change. `Outlet` reads exactly this.
  --- @return table|nil route record
  function router.match()
    return match_sig:get()
  end

  router.params = params_proxy
  router.search_params = search_proxy

  --- A real plain table of the current path params.
  ---
  --- Use this, never `pairs(router.params)` -- see the `__pairs` note in
  --- the module header. Reactive: it reads through the signals, so calling
  --- it inside a render closure or effect subscribes to the params it saw.
  --- @return table
  function router.params_snapshot()
    match_sig:get()
    local out = {}
    for k, sig in pairs(param_sigs) do
      local v = sig:get()
      if v ~= nil then out[k] = v end
    end
    return out
  end

  --- A real plain table of the current query params. Same rules as
  --- `params_snapshot`.
  --- @return table
  function router.search_snapshot()
    location_sig:get()
    local out = {}
    for k, sig in pairs(query_sigs) do
      local v = sig:get()
      if v ~= nil then out[k] = v end
    end
    return out
  end

  --- Navigate.
  ---
  --- @param to string    an href RELATIVE to the router's base
  --- @param nav? table   `.replace` boolean (overwrite the current entry
  ---                     instead of pushing), `.state` any
  function router.navigate(to, nav)
    if type(to) ~= "string" then
      error("hydronium_router: navigate(to) expects a string href, got " .. type(to), 2)
    end
    nav = nav or {}

    local target = to
    if base ~= "/" and to:sub(1, 1) == "/" then
      target = base .. to
    end

    if nav.replace then
      history.replace(target, nav.state)
    else
      history.push(target, nav.state)
    end
  end

  --- Build a link for a registered route id, base included.
  --- Delegates to `hydronium_router.href`, which is where the unknown-id,
  --- missing-param and unknown-param-key checks live.
  --- @return string
  function router.href(id, params, query)
    local built = href_mod.href(m, id, params, query)
    if base == "/" then return built end
    return base .. built
  end

  --- Provider component. Publishes THIS router on the shared
  --- `RouterContext` so `useRouter`, `useParams`, `useNavigate` and
  --- `Outlet` can find it.
  function router.Provider(props)
    props = props or {}
    return H.h(M.RouterContext.Provider, { value = router }, props.children)
  end

  router.Context = M.RouterContext

  return router
end

M.create = M.create_router
M.createRouter = M.create_router

return M
