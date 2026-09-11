--[[
  hydronium_router.pattern -- route-pattern parsing and specificity
  comparison.

  PURE: this module has zero `require` calls and zero dependencies, by
  design. It is the bottom of the router's dependency graph -- `url`,
  `matcher`, `href` and the history adapters all sit above it -- so it
  stays loadable and testable in complete isolation (no Hydronium core,
  no host, no globals).

  GRAMMAR -- deliberately identical to Meteorite's own route grammar
  (`meteorite/src/core/route.lua`'s `parse_path`), so a path that is
  legal on the server is legal on the client and vice versa:

    /literal        a literal segment, matched verbatim
    /:name          a single-segment named parameter
    /:name*         a named catch-all; MUST be the final segment
    /*              an anonymous wildcard; MUST be the final segment

  Param names must match `^[%a_][%w_]*$` (the same check Meteorite
  applies). A name may not repeat within one pattern -- `/:id/:id` is
  rejected at parse time rather than silently letting the second capture
  clobber the first.

  Meteorite's `parse_path` returns segments shaped
  `{ kind = "param", name = ..., catch_all = bool }`; this module
  promotes catch-all to its own `kind` ("catch_all") so downstream
  matching can switch on `kind` alone. That is the one intentional
  divergence from the reference grammar's *representation*; the accepted
  *syntax* is the same.

  SPECIFICITY. Each segment scores: literal = 3, param = 2,
  catch_all/wildcard = 1. `more_specific(a, b)` compares score arrays
  left to right and, on a full prefix tie, puts the longer pattern
  first. It deliberately does NOT consider declaration order -- a pure
  function over two patterns cannot know insertion order, and pretending
  otherwise would make ordering depend on hidden state. Breaking exact
  ties by declaration order is `matcher`'s job (it is the thing that
  actually has an insertion counter).
--]]

local M = {}

M.SCORE_LITERAL = 3
M.SCORE_PARAM = 2
M.SCORE_CATCH_ALL = 1

local function fail(msg, source)
  error("hydronium_router.pattern: " .. msg .. " (in pattern " .. string.format("%q", tostring(source)) .. ")", 3)
end

--- Parse a route pattern source string into a Pattern.
---
--- @param source string  e.g. "/", "/users/:id", "/files/:rest*", "/a/*"
--- @return table Pattern
---   `.source`        the original string
---   `.segments`      array of `{ kind = "literal", value = s }`,
---                    `{ kind = "param", name = s }`,
---                    `{ kind = "catch_all", name = s }`, or
---                    `{ kind = "wildcard" }`
---   `.params`        array of param names in declaration order
---                    (catch-all included; the anonymous wildcard is not
---                    a named param and never appears here)
---   `.scores`        array of per-segment specificity scores
---   `.has_catch_all` true when the final segment absorbs any number of
---                    trailing path segments -- i.e. for BOTH `:name*`
---                    and `*`. Callers deciding "may this pattern match
---                    a longer path?" want exactly this flag.
---   `.has_wildcard`  true only for the anonymous `*` form
---   `.is_static`     true when every segment is a literal
function M.parse(source)
  if type(source) ~= "string" then
    error("hydronium_router.pattern.parse: pattern must be a string, got " .. type(source), 2)
  end
  if source == "" then
    fail("pattern must be a non-empty string", source)
  end
  if source:sub(1, 1) ~= "/" then
    fail("pattern must start with '/'", source)
  end

  local segments = {}
  local params = {}
  local scores = {}
  local seen = {}
  local has_catch_all = false
  local has_wildcard = false
  local is_static = true

  -- The final raw segment of the source, used for the "must be final"
  -- checks. Matches Meteorite's own `path:match("[^/]+$")` approach.
  local last_raw = source:match("[^/]+$")

  for segment in source:gmatch("[^/]+") do
    if has_catch_all then
      fail("no segment may follow a catch-all or wildcard segment", source)
    end

    if segment == "*" then
      if segment ~= last_raw then
        fail("wildcard '*' must be the final segment", source)
      end
      segments[#segments + 1] = { kind = "wildcard" }
      scores[#scores + 1] = M.SCORE_CATCH_ALL
      has_catch_all = true
      has_wildcard = true
      is_static = false
    elseif segment:sub(1, 1) == ":" then
      local name = segment:sub(2)
      local catch_all = false
      if name:sub(-1) == "*" then
        catch_all = true
        name = name:sub(1, -2)
        if segment ~= last_raw then
          fail("catch-all param ':" .. name .. "*' must be the final segment", source)
        end
      end
      if not name:match("^[%a_][%w_]*$") then
        fail("invalid path param name " .. string.format("%q", name)
          .. " -- must match ^[%a_][%w_]*$", source)
      end
      if seen[name] then
        fail("duplicate path param name " .. string.format("%q", name), source)
      end
      seen[name] = true
      params[#params + 1] = name
      segments[#segments + 1] = { kind = catch_all and "catch_all" or "param", name = name }
      scores[#scores + 1] = catch_all and M.SCORE_CATCH_ALL or M.SCORE_PARAM
      if catch_all then has_catch_all = true end
      is_static = false
    else
      if segment:find("*", 1, true) then
        fail("'*' is only allowed as a whole segment ('/*') or as a catch-all suffix ('/:name*')", source)
      end
      segments[#segments + 1] = { kind = "literal", value = segment }
      scores[#scores + 1] = M.SCORE_LITERAL
    end
  end

  return {
    source = source,
    segments = segments,
    params = params,
    scores = scores,
    has_catch_all = has_catch_all,
    has_wildcard = has_wildcard,
    is_static = is_static,
  }
end

--- Strict "a sorts before b" specificity comparison.
---
--- Returns true only when `a` is STRICTLY more specific than `b`. Exact
--- ties return false in both directions, which is what lets a caller
--- layer its own tiebreaker on top and still have a total order.
---
--- @param a table Pattern
--- @param b table Pattern
--- @return boolean
function M.more_specific(a, b)
  local sa, sb = a.scores, b.scores
  local n = math.min(#sa, #sb)
  for i = 1, n do
    if sa[i] ~= sb[i] then
      return sa[i] > sb[i]
    end
  end
  -- Full prefix tie: the longer pattern is the more specific one.
  if #sa ~= #sb then
    return #sa > #sb
  end
  return false
end

return M
