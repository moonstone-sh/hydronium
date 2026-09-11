--[[
  hydronium_router.href -- build a URL from a route id plus params.

  WHY THIS EXISTS. Hand-writing links (`"/users/" .. id`) fails silently:
  a renamed route, a misspelled param key, or a forgotten segment all
  produce a perfectly well-formed string that 404s at runtime, usually in
  a code path nobody clicked before shipping. Every failure mode this
  module can detect, it detects LOUDLY, at call time:

    * unknown route id            -> error, listing the known ids
    * missing required param      -> error, naming the param
    * UNKNOWN key in `params`     -> error, listing the accepted names

  That third one is the point. `href(m, "users.show", { userId = 7 })`
  when the route declares `:id` is the classic typo bug; without this
  check it builds "/users/" and the failure surfaces as a mystery 404
  far from its cause.

  ENCODING RULES.
    * Param values are `tostring`ed then percent-encoded.
    * Catch-all values are STRUCTURAL: their internal "/" characters
      separate real path segments and must survive, so the value is
      split on "/", each piece encoded, and the pieces rejoined with raw
      "/". Encoding the whole thing would turn "a/b" into "a%2Fb", a
      single segment -- the exact opposite of what a catch-all means.
    * Literal segments are emitted VERBATIM, exactly as the pattern
      author wrote them. Encoding them would double-encode a pattern that
      was already written pre-encoded, and a literal cannot contain "/"
      anyway (it is one segment by construction).
--]]

local url = require("hydronium_router.url")
local pattern = require("hydronium_router.pattern")

local M = {}

local MAX_IDS_IN_ERROR = 20

local function known_ids(source)
  if type(source) == "table" and type(source.ids) == "function" then
    return source:ids()
  end
  local ids = {}
  if type(source) == "table" then
    for k in pairs(source) do
      if type(k) == "string" then ids[#ids + 1] = k end
    end
  end
  table.sort(ids)
  return ids
end

local function format_ids(ids)
  if #ids == 0 then return "(no routes are registered)" end
  local shown = {}
  for i = 1, math.min(#ids, MAX_IDS_IN_ERROR) do
    shown[i] = string.format("%q", ids[i])
  end
  local s = table.concat(shown, ", ")
  if #ids > MAX_IDS_IN_ERROR then
    s = s .. ", ... (" .. (#ids - MAX_IDS_IN_ERROR) .. " more)"
  end
  return s
end

--- Resolve `source` + `id` to a route record carrying a `.pattern`.
---
--- Accepts a `Matcher` (anything exposing `get`), or a plain table
--- mapping id -> route record, or id -> pattern source string. The
--- string form is compiled on the fly, which makes `href` usable in a
--- test or a script without standing up a whole Matcher.
local function lookup(source, id)
  if type(source) ~= "table" then
    error("hydronium_router.href: expected a Matcher or a route table, got " .. type(source), 3)
  end

  local route
  if type(source.get) == "function" then
    route = source:get(id)
  else
    route = source[id]
  end

  if route == nil then
    error("hydronium_router.href: unknown route id " .. string.format("%q", tostring(id))
      .. " -- known ids: " .. format_ids(known_ids(source))
      .. ". Check that the route is registered before building a link to it.", 3)
  end

  if type(route) == "string" then
    return { id = id, path = route, pattern = pattern.parse(route) }
  end
  if type(route) == "table" and route.pattern == nil and type(route.path) == "string" then
    return { id = id, path = route.path, pattern = pattern.parse(route.path), meta = route.meta }
  end
  if type(route) ~= "table" or type(route.pattern) ~= "table" then
    error("hydronium_router.href: route " .. string.format("%q", tostring(id))
      .. " is not a usable route record (needs a `pattern` or a `path` string)", 3)
  end
  return route
end

--- Encode a catch-all value, preserving its structural "/" separators.
local function encode_catch_all(value)
  local pieces = {}
  for piece in tostring(value):gmatch("[^/]+") do
    pieces[#pieces + 1] = url.encode(piece)
  end
  return table.concat(pieces, "/")
end

--- Build a URL for a registered route.
---
--- @param source table   a Matcher, or a table of route records/patterns
--- @param id string      the route id
--- @param params? table  path params by name; a catch-all accepts "" to
---                       mean "no trailing segments"
--- @param query? table   appended via `url.build_query` (sorted keys)
--- @return string href
function M.href(source, id, params, query)
  local route = lookup(source, id)
  local p = route.pattern
  params = params or {}

  if type(params) ~= "table" then
    error("hydronium_router.href: params must be a table, got " .. type(params), 2)
  end

  -- Which keys is this route willing to accept?
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

  -- The typo check: reject unknown keys BEFORE building, so the error
  -- names the mistake instead of producing a plausible-looking 404.
  local unknown = {}
  for k in pairs(params) do
    if not accepted[k] then unknown[#unknown + 1] = tostring(k) end
  end
  if #unknown > 0 then
    table.sort(unknown)
    local accepted_str = #accepted_list > 0
      and table.concat(accepted_list, ", ")
      or "(this route takes no params)"
    error("hydronium_router.href: unknown param key(s) " .. table.concat(unknown, ", ")
      .. " for route " .. string.format("%q", tostring(id))
      .. " (" .. string.format("%q", tostring(route.path or p.source)) .. ")"
      .. " -- accepted param names: " .. accepted_str, 2)
  end

  local out = {}
  for _, seg in ipairs(p.segments) do
    if seg.kind == "literal" then
      out[#out + 1] = seg.value
    elseif seg.kind == "param" then
      local v = params[seg.name]
      if v == nil then
        error("hydronium_router.href: missing required param " .. string.format("%q", seg.name)
          .. " for route " .. string.format("%q", tostring(id))
          .. " (" .. string.format("%q", tostring(route.path or p.source)) .. ")", 2)
      end
      out[#out + 1] = url.encode(tostring(v))
    else -- catch_all / wildcard
      local key = seg.kind == "catch_all" and seg.name or "*"
      local v = params[key]
      if v == nil then
        error("hydronium_router.href: missing required catch-all param " .. string.format("%q", key)
          .. " for route " .. string.format("%q", tostring(id))
          .. " (" .. string.format("%q", tostring(route.path or p.source)) .. ")"
          .. " -- pass \"\" if you mean no trailing segments", 2)
      end
      local encoded = encode_catch_all(v)
      if encoded ~= "" then
        out[#out + 1] = encoded
      end
    end
  end

  local path = #out > 0 and ("/" .. table.concat(out, "/")) or "/"

  local qs = url.build_query(query)
  if qs ~= "" then
    path = path .. "?" .. qs
  end

  return path
end

-- Callable module: `local href = require("hydronium_router.href")` then
-- `href(m, "users.show", { id = 7 })`, matching how this primitive reads
-- at a call site.
setmetatable(M, { __call = function(_, ...) return M.href(...) end })

return M
