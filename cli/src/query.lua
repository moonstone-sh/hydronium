--[[
  hydronium_cli.query -- the filter language for the fullscreen request view.

  SYNTAX
    method:GET            a tag: field and value
    -method:POST          negated -- exclude anything matching
    status:5xx            classes as well as exact codes
    duration:>100         numeric comparison (ms)
    body:"not found"      quoted value, so a value may contain spaces
    anything else         free text, matched across the whole request

  MERGING, decided deliberately rather than by accident:
    - AND across DIFFERENT fields.  method:GET status:200  -> both must hold.
    - OR within a REPEATED field.   method:GET method:POST -> either.
    - AND NOT for every negation.   -status:2xx            -> none may match.
  That combination removes the need for explicit boolean operators, which is
  the whole reason to pick it: a filter bar people type into under time
  pressure should not require parentheses.

  MATCH STRATEGY IS PER FIELD, not uniform. Trigram similarity is only worth
  its cost on high-cardinality free text, which here means `body` alone.
  Applying it to `method` -- a seven-value enum -- would be strictly worse
  than an exact compare: slower, and it would match GET against DELETE on a
  shared trigram. Each field below declares how it is matched and why.

  Parsing is total: an unknown field or a malformed value never raises and
  never silently drops the whole query. It degrades to free text and is
  reported as `unknown` in the token stream, so the UI can render it
  differently (an unrecognised tag should LOOK unrecognised while you type,
  not vanish or filter everything away).
--]]

local event_model = require("event_model")

local M = {}

--- Lowercase, nil-safe.
local function lower(s)
  return type(s) == "string" and s:lower() or nil
end

--- The request's headers as a normalised {name, value} list, or nil.
---
--- Goes through event_model rather than reading `event.headers` directly, so
--- there is ONE interpretation of the wire shape in this CLI. Meteorite emits
--- headers as an ARRAY of {name, value} pairs and says so explicitly in
--- zig/server/dev_events.zig: order and duplicates are meaningful in HTTP, so
--- it is "an array of pairs, never a map".
---
--- An earlier version of this file assumed a map and iterated it with pairs()
--- looking for string keys. Against real Meteorite output that found nothing,
--- every time, with no error -- `mime:`, `origin:` and `header:` would simply
--- never have matched. The specs passed because their fixtures encoded the
--- same wrong assumption.
--- @param event table
--- @return table[]|nil
local function header_pairs(event)
  local list = event_model.normalize_headers(event.headers)
  return list
end

--- The value of a header, case-insensitively by name. First match wins;
--- duplicates are preserved in the list above for anything that needs them.
--- @param event table
--- @param name string
--- @return string|nil
local function header(event, name)
  local list = header_pairs(event)
  if not list then return nil end
  local want = name:lower()
  for _, entry in ipairs(list) do
    if entry.name:lower() == want then
      return entry.value
    end
  end
  return nil
end

--- Trigram similarity: the fraction of the needle's 3-grams present in the
--- haystack. Used for `body` only.
---
--- Under three characters there are no trigrams to compare, so it falls back
--- to a plain substring test -- the same rule the house convention uses, and
--- the reason a one- or two-character body query still behaves sensibly
--- instead of matching everything.
--- @param haystack string
--- @param needle string
--- @return boolean
local function trigramMatch(haystack, needle)
  if #needle < 3 then
    return haystack:find(needle, 1, true) ~= nil
  end
  local present, total, hits = {}, 0, 0
  for i = 1, #haystack - 2 do
    present[haystack:sub(i, i + 2)] = true
  end
  for i = 1, #needle - 2 do
    total = total + 1
    if present[needle:sub(i, i + 2)] then hits = hits + 1 end
  end
  if total == 0 then return false end
  -- 0.6 rather than 1.0 so a typo or a partial word still finds the request
  -- you half-remember, which is the entire point of reaching for trigrams on
  -- a body in the first place.
  return (hits / total) >= 0.6
end

--- Status matching: an exact code (404), or a class (4xx, 2XX).
local function statusMatch(actual, want)
  if not actual then return false end
  local class = want:match("^(%d)[xX][xX]$")
  if class then
    return math.floor(tonumber(actual) / 100) == tonumber(class)
  end
  return tostring(actual) == want
end

--- Numeric comparison: `>100`, `<50`, `>=10`, or a bare number (equality).
local function numericMatch(actual, want)
  if type(actual) ~= "number" then return false end
  local op, rhs = want:match("^([<>]=?)%s*(%-?%d+%.?%d*)$")
  if op then
    local n = tonumber(rhs)
    if not n then return false end
    if op == ">" then return actual > n end
    if op == "<" then return actual < n end
    if op == ">=" then return actual >= n end
    return actual <= n
  end
  local n = tonumber(want)
  return n ~= nil and actual == n
end

--- The field vocabulary. `get` pulls the comparable value off an event;
--- `test` decides a match. Aliases exist where the event's own field name is
--- not what a person would type (`ip` for remote_addr).
M.FIELDS = {
  -- Low cardinality, exact and case-insensitive. Trigram here would be a
  -- pessimisation AND a correctness problem (GET/DELETE share "et"... and
  -- with longer methods, real trigrams).
  method = {
    get = function(e) return lower(e.method) end,
    test = function(actual, want) return actual == want:lower() end,
  },
  kind = {
    get = function(e) return lower(e.kind) end,
    test = function(actual, want) return actual == want:lower() end,
  },
  -- Paths are long-ish but structured; substring is what people mean when
  -- they type `path:/api`.
  path = {
    get = function(e) return lower(e.path) end,
    test = function(actual, want) return actual:find(want:lower(), 1, true) ~= nil end,
  },
  status = {
    get = function(e) return e.status end,
    test = statusMatch,
  },
  duration = {
    get = function(e) return tonumber(e.duration_ms) end,
    test = numericMatch,
  },
  ip = {
    get = function(e) return lower(e.remote_addr) end,
    test = function(actual, want) return actual:find(want:lower(), 1, true) ~= nil end,
  },
  mime = {
    get = function(e) return lower(header(e, "content-type")) end,
    test = function(actual, want) return actual:find(want:lower(), 1, true) ~= nil end,
  },
  origin = {
    get = function(e) return lower(header(e, "origin") or header(e, "referer")) end,
    test = function(actual, want) return actual:find(want:lower(), 1, true) ~= nil end,
  },
  -- The one high-cardinality free-text field, and so the one place trigram
  -- similarity earns its keep.
  body = {
    get = function(e) return lower(e.body) end,
    test = function(actual, want) return trigramMatch(actual, want:lower()) end,
  },
  header = {
    get = header_pairs,
    test = function(actual, want)
      local name, value = want:match("^([^=]+)=(.*)$")
      for _, entry in ipairs(actual) do
        local ename = entry.name:lower()
        if name then
          if ename == name:lower() and entry.value:lower():find(value:lower(), 1, true) then
            return true
          end
        elseif ename:find(want:lower(), 1, true) then
          return true
        end
      end
      return false
    end,
  },
}

--- @class hydronium_cli.QueryToken
--- @field type "tag"|"unknown"|"text"
--- @field field string|nil
--- @field value string|nil
--- @field negated boolean|nil
--- @field text string The raw source text of this token
--- @field from integer 1-based byte offset of the token's first character
--- @field to integer 1-based byte offset of the token's last character

--- Splits raw filter text into positioned tokens.
---
--- Positions are returned because the UI renders known tags as chips in
--- place, and a chip has to know exactly which run of the input it covers in
--- order to highlight it and to keep the caret arithmetic honest.
--- @param text string
--- @return hydronium_cli.QueryToken[]
function M.tokenize(text)
  local tokens = {}
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      local start = i
      -- Consume to the next unquoted whitespace, so a quoted value keeps its
      -- spaces: body:"not found" is one token, not two.
      local inQuote = false
      while i <= n do
        local ch = text:sub(i, i)
        if ch == '"' then
          inQuote = not inQuote
        elseif ch:match("%s") and not inQuote then
          break
        end
        i = i + 1
      end
      local raw = text:sub(start, i - 1)
      local negated = false
      local body = raw
      if body:sub(1, 1) == "-" then
        negated = true
        body = body:sub(2)
      end
      local field, value = body:match("^([%a_]+):(.*)$")
      if field then
        value = value:gsub('^"(.*)"$', "%1")
        tokens[#tokens + 1] = {
          type = M.FIELDS[field:lower()] and "tag" or "unknown",
          field = field:lower(),
          value = value,
          negated = negated,
          text = raw,
          from = start,
          to = i - 1,
        }
      else
        tokens[#tokens + 1] = { type = "text", text = raw, from = start, to = i - 1 }
      end
    end
  end
  return tokens
end

--- @class hydronium_cli.Query
--- @field include table<string, string[]> field -> values, OR within a field
--- @field exclude table<string, string[]> field -> values, AND NOT
--- @field terms string[] free text, AND
--- @field tokens hydronium_cli.QueryToken[]
--- @field empty boolean

--- @param text string
--- @return hydronium_cli.Query
function M.parse(text)
  local tokens = M.tokenize(text or "")
  local query = { include = {}, exclude = {}, terms = {}, tokens = tokens, empty = true }
  for _, t in ipairs(tokens) do
    if t.type == "tag" and t.value ~= "" then
      local bucket = t.negated and query.exclude or query.include
      bucket[t.field] = bucket[t.field] or {}
      table.insert(bucket[t.field], t.value)
      query.empty = false
    else
      -- Unknown tags fall through to free text rather than being dropped: a
      -- half-typed `meth` should narrow by text, not silently match nothing.
      table.insert(query.terms, t.text:lower())
      query.empty = false
    end
  end
  return query
end

--- Everything about an event a free-text term is matched against.
local function haystack(event)
  local parts = {
    event.method, event.path, tostring(event.status or ""),
    event.kind, event.remote_addr, event.body,
  }
  local out = {}
  for _, p in ipairs(parts) do
    if type(p) == "string" then out[#out + 1] = p:lower() end
  end
  return table.concat(out, " ")
end

--- @param event table
--- @param field string
--- @param values string[]
--- @return boolean matchedAny
local function anyValueMatches(event, field, values)
  local spec = M.FIELDS[field]
  if not spec then return false end
  local actual = spec.get(event)
  if actual == nil then return false end
  for _, want in ipairs(values) do
    if spec.test(actual, want) then return true end
  end
  return false
end

--- @param event table
--- @param query hydronium_cli.Query
--- @return boolean
function M.matches(event, query)
  if not query or query.empty then return true end

  -- AND across fields, OR within one.
  for field, values in pairs(query.include) do
    if not anyValueMatches(event, field, values) then return false end
  end
  -- AND NOT: any match at all excludes the event.
  for field, values in pairs(query.exclude) do
    if anyValueMatches(event, field, values) then return false end
  end
  if #query.terms > 0 then
    local hay = haystack(event)
    for _, term in ipairs(query.terms) do
      if not hay:find(term, 1, true) then return false end
    end
  end
  return true
end

return M
