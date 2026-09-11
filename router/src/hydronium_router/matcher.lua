--[[
  hydronium_router.matcher -- the route table.

  `Matcher:add(id, path, meta)` registers a route; `Matcher:match(path)`
  resolves a concrete path to a route plus its decoded params.

  TWO STORAGE TIERS, on purpose:

    * STATIC routes (every segment a literal) go into a hash map keyed by
      their normalized path, so the overwhelmingly common case is an O(1)
      table lookup with no pattern walking at all.
    * DYNAMIC routes go into an array sorted by specificity.

  DETERMINISM is the whole point of this module, so two things are
  load-bearing:

    1. Dynamic routes live in an ARRAY, never a hash. Nothing here ever
       iterates `pairs` over routes to decide a match, because `pairs`
       order is unspecified in Lua and would make routing depend on
       memory layout.
    2. `table.sort` in Lua is NOT stable. So each route carries an
       `order` field (a monotonically increasing insertion counter) and
       the comparator falls back to it when two patterns are exactly
       equally specific. That turns the comparator into a TOTAL order,
       which makes the sorted result identical no matter what order the
       routes were added in or how the sort algorithm happens to
       partition. `tests/router/matcher_spec.lua` verifies this by
       registering the same two competing routes in both orders and
       asserting identical match results.

  The sort is LAZY: `add` only sets a dirty flag, so registering N routes
  is N appends and one sort at first `match`, not N sorts.

  PARAM PREDICATES ("bring your own validation"). A route's `meta` may
  carry `params = { <name> = function(raw_string) ... end }`. Each
  predicate is handed the DECODED raw segment and returns either

    * a non-nil value -- the segment is accepted AND the returned value
      REPLACES the raw string in `params`, so a predicate doubles as a
      coercion (`tonumber`, a date parser, an enum lookup); or
    * nil -- this route does not match, and matching FALLS THROUGH to the
      next candidate.

  The fall-through is the point. It is what lets a numeric "/users/:id"
  and a textual "/users/:slug" coexist: the numeric route declares
  `params = { id = tonumber }`, so "/users/alice" fails its predicate and
  resolution continues to the slug route instead of stopping at the first
  pattern-shaped match.

  Predicate KEYS are validated at `add` time against the pattern's own
  param names, for the same reason `href` rejects unknown param keys: a
  predicate attached to a misspelled name would otherwise never run and
  the route would silently accept everything.

  Every declared predicate must pass for the route to match, so the
  `pairs` iteration order over the predicate table cannot change the
  accept/reject outcome. Predicates should therefore be pure -- a
  predicate with side effects would observe an unspecified order, and may
  run for candidate routes that ultimately do not match.
--]]

local pattern = require("hydronium_router.pattern")
local url = require("hydronium_router.url")

local M = {}

local Matcher = {}
Matcher.__index = Matcher
M.Matcher = Matcher

--- Route ids are dot-separated identifiers ("users", "users.show",
--- "admin.users.edit"). Validated segment-by-segment because Lua
--- patterns cannot express "repeat this group".
local function validate_id(id)
  if type(id) ~= "string" or id == "" then
    error("hydronium_router.matcher: route id must be a non-empty string, got "
      .. (type(id) == "string" and "\"\"" or type(id)), 3)
  end
  if id:sub(1, 1) == "." or id:sub(-1) == "." or id:find("..", 1, true) then
    error("hydronium_router.matcher: invalid route id " .. string.format("%q", id)
      .. " -- dot-separated identifiers may not be empty (e.g. \"users.show\")", 3)
  end
  for part in id:gmatch("[^%.]+") do
    if not part:match("^[%a_][%w_]*$") then
      error("hydronium_router.matcher: invalid route id " .. string.format("%q", id)
        .. " -- segment " .. string.format("%q", part)
        .. " must match ^[%a_][%w_]*$", 3)
    end
  end
end

--- Validate a route's `meta.params` predicate table against the pattern
--- it is attached to.
---
--- Rejects (a) a non-table `params`, (b) a non-function predicate, and
--- (c) a predicate keyed by a name this pattern does not declare. (c) is
--- the important one: silently ignoring `params = { userId = tonumber }`
--- on a route declaring `:id` would leave the route matching everything
--- while its author believed it was constrained.
local function validate_param_predicates(id, path, p, specs)
  if type(specs) ~= "table" then
    error("hydronium_router.matcher: route " .. string.format("%q", id)
      .. " has meta.params of type " .. type(specs)
      .. " -- it must be a table mapping param name -> predicate function", 3)
  end

  local accepted = {}
  local accepted_list = {}
  for _, name in ipairs(p.params) do
    accepted[name] = true
    accepted_list[#accepted_list + 1] = name
  end
  if p.has_wildcard then
    accepted["*"] = true
    accepted_list[#accepted_list + 1] = "*"
  end

  local unknown = {}
  for name, pred in pairs(specs) do
    if not accepted[name] then
      unknown[#unknown + 1] = tostring(name)
    elseif type(pred) ~= "function" then
      error("hydronium_router.matcher: route " .. string.format("%q", id)
        .. " declares meta.params." .. tostring(name) .. " as a " .. type(pred)
        .. " -- a param predicate must be a function(raw_string) returning"
        .. " a coerced value, or nil to reject the match", 3)
    end
  end

  if #unknown > 0 then
    table.sort(unknown)
    local accepted_str = #accepted_list > 0
      and table.concat(accepted_list, ", ")
      or "(this route takes no params)"
    error("hydronium_router.matcher: route " .. string.format("%q", id)
      .. " (" .. string.format("%q", path) .. ") declares meta.params predicate(s) for "
      .. table.concat(unknown, ", ")
      .. ", which this pattern does not have -- declared param names: " .. accepted_str, 3)
  end
end

--- Run a route's param predicates over a candidate param table.
---
--- Mutates and returns `params` on success (each predicate's return
--- value replaces the raw string); returns nil when any predicate
--- rejects, which the caller treats as "not a match, keep looking".
local function apply_param_predicates(route, params)
  local specs = route.meta and route.meta.params
  if specs == nil then return params end

  for name, pred in pairs(specs) do
    local coerced = pred(params[name])
    if coerced == nil then return nil end
    params[name] = coerced
  end

  return params
end

--- @return table Matcher
function M.new()
  return setmetatable({
    _routes = {},     -- id -> route record
    _static = {},     -- normalized path -> route record
    _dynamic = {},    -- array of route records, specificity-sorted lazily
    _order = 0,       -- insertion counter; the stable-sort tiebreaker
    _dirty = false,
  }, Matcher)
end

--- Register a route.
---
--- @param id string    dot-separated identifier, unique within this matcher
--- @param path string  a route pattern (see `hydronium_router.pattern`)
--- @param meta? table  arbitrary caller data carried through to matches
--- @return table route  the stored route record
function Matcher:add(id, path, meta)
  validate_id(id)

  if self._routes[id] then
    error("hydronium_router.matcher: duplicate route id " .. string.format("%q", id)
      .. " -- already registered for path " .. string.format("%q", self._routes[id].path), 2)
  end

  local p = pattern.parse(path)

  if meta ~= nil and meta.params ~= nil then
    validate_param_predicates(id, path, p, meta.params)
  end

  self._order = self._order + 1
  local route = {
    id = id,
    path = path,
    pattern = p,
    meta = meta,
    order = self._order,
  }

  if p.is_static then
    local key = url.normalize_path(path)
    local clash = self._static[key]
    if clash then
      error("hydronium_router.matcher: duplicate static path " .. string.format("%q", key)
        .. " -- already registered by route " .. string.format("%q", clash.id)
        .. ", cannot also register it for route " .. string.format("%q", id), 2)
    end
    route.static_key = key
    self._static[key] = route
  else
    self._dynamic[#self._dynamic + 1] = route
    self._dirty = true
  end

  self._routes[id] = route
  return route
end

--- @param id string
--- @return table|nil route
function Matcher:get(id)
  return self._routes[id]
end

--- All registered ids, sorted -- for error messages and introspection.
--- @return string[]
function Matcher:ids()
  local ids = {}
  for id in pairs(self._routes) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

--- The total order described in the module doc comment.
--- The `a.order < b.order` line IS the stable-sort tiebreaker; removing
--- it makes the result depend on `table.sort`'s internal partitioning.
local function route_precedes(a, b)
  if pattern.more_specific(a.pattern, b.pattern) then return true end
  if pattern.more_specific(b.pattern, a.pattern) then return false end
  return a.order < b.order
end

function Matcher:_ensure_sorted()
  if self._dirty then
    table.sort(self._dynamic, route_precedes)
    self._dirty = false
  end
end

--- The dynamic routes in resolution order. Exposed for tests and
--- debugging; the returned array is a copy.
--- @return table[]
function Matcher:ordered_dynamic()
  self:_ensure_sorted()
  local out = {}
  for i = 1, #self._dynamic do out[i] = self._dynamic[i] end
  return out
end

--- Try one pattern against already-split raw path segments.
--- @return table|nil params
local function try(p, segs)
  local params = {}
  local psegs = p.segments

  for i = 1, #psegs do
    local ps = psegs[i]
    local kind = ps.kind

    if kind == "catch_all" or kind == "wildcard" then
      -- Absorbs every remaining segment, INCLUDING none at all (which
      -- yields "" rather than being a non-match). Each remaining segment
      -- is decoded individually and only then joined with "/", so a
      -- percent-encoded %2F inside a segment stays data and does not
      -- silently become a structural separator.
      local rest = {}
      for j = i, #segs do
        rest[#rest + 1] = url.decode(segs[j])
      end
      local joined = table.concat(rest, "/")
      if kind == "catch_all" then
        params[ps.name] = joined
      else
        params["*"] = joined
      end
      return params
    end

    local seg = segs[i]
    if seg == nil then return nil end

    if kind == "literal" then
      -- Compare raw first (the common case), then decoded, so both
      -- "/caf%C3%A9" and "/café" hit a literal written as "café".
      if seg ~= ps.value and url.decode(seg) ~= ps.value then
        return nil
      end
    else -- "param"
      params[ps.name] = url.decode(seg)
    end
  end

  -- Every pattern segment consumed. Leftover path segments are only
  -- acceptable when the pattern absorbs them, and it does not -- a
  -- catch-all/wildcard would have returned above.
  if #segs > #psegs then return nil end

  return params
end

--- Resolve a path to a route.
---
--- Accepts a bare path or a full href; any query string and fragment are
--- split off and ignored (matching is a path-only concern).
---
--- @param path string
--- @return table|nil  `{ route = <record>, params = <table>, path = <normalized path> }`
function Matcher:match(path)
  local raw_path = url.split(path)
  local clean = url.normalize_path(raw_path)

  local static_hit = self._static[clean]
  if static_hit then
    return { route = static_hit, params = {}, path = clean }
  end

  self:_ensure_sorted()
  local segs = url.path_segments(clean)

  for i = 1, #self._dynamic do
    local route = self._dynamic[i]
    local params = try(route.pattern, segs)
    if params then
      -- A pattern-shaped match is only a real match once the route's own
      -- predicates accept it; a rejection continues the loop rather than
      -- ending it, which is what makes predicate fall-through work.
      params = apply_param_predicates(route, params)
      if params then
        return { route = route, params = params, path = clean }
      end
    end
  end

  return nil
end

return M
