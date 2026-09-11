--[[
  hydronium_router.url -- percent-encoding, href splitting, query
  parsing/building, and path normalization.

  PURE: zero `require` calls, like `pattern`.

  THE `+` TRAP. `+` means a space in `application/x-www-form-urlencoded`
  data -- which is what a QUERY STRING is -- and means a literal plus
  sign everywhere else, a PATH included. Decoding `/a+b` as `/a b` is a
  real, silent corruption bug. So `decode` takes an explicit
  `plus_as_space` flag defaulting to FALSE (path-safe), and only
  `parse_query` passes true. `encode` never emits `+`: a space always
  becomes `%20`, which is correct in both contexts.
--]]

local M = {}

-- RFC 3986 unreserved set. Everything else is percent-encoded.
local function is_unreserved(byte)
  return (byte >= 65 and byte <= 90)      -- A-Z
    or (byte >= 97 and byte <= 122)       -- a-z
    or (byte >= 48 and byte <= 57)        -- 0-9
    or byte == 45 or byte == 95           -- - _
    or byte == 46 or byte == 126          -- . ~
end

--- Percent-encode a single URL component.
--- A space becomes `%20`, never `+` (see the module doc comment).
--- @param s string
--- @return string
function M.encode(s)
  s = tostring(s)
  return (s:gsub("[^A-Za-z0-9%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- Percent-decode a single URL component.
---
--- @param s string
--- @param plus_as_space? boolean  Treat `+` as a space. Default FALSE.
---   Pass true ONLY when decoding a piece of a query string; never for a
---   path segment.
--- @return string
function M.decode(s, plus_as_space)
  s = tostring(s)
  if plus_as_space then
    s = s:gsub("%+", " ")
  end
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Split an href into its path, raw query, and fragment.
---
--- Order matters: per RFC 3986 the fragment is last, so a `#` before a
--- `?` means that `?` is part of the fragment, not a query delimiter.
--- The fragment is therefore stripped FIRST.
---
--- @param href string
--- @return string path      never nil; "" when the href is only a query/hash
--- @return string|nil raw_query  without the leading "?"; nil when absent
--- @return string|nil hash       without the leading "#"; nil when absent
function M.split(href)
  href = tostring(href or "")

  local hash = nil
  local hash_at = href:find("#", 1, true)
  if hash_at then
    hash = href:sub(hash_at + 1)
    href = href:sub(1, hash_at - 1)
  end

  local raw_query = nil
  local q_at = href:find("?", 1, true)
  if q_at then
    raw_query = href:sub(q_at + 1)
    href = href:sub(1, q_at - 1)
  end

  return href, raw_query, hash
end

--- Parse a raw query string into a table.
---
--- A key that appears more than once becomes an array of its values, in
--- first-seen order. A key with no `=` gets the value `""`.
--- Both keys and values are decoded WITH `+`-as-space (this is the one
--- context where that is correct).
---
--- @param raw string|nil
--- @return table
function M.parse_query(raw)
  local out = {}
  if raw == nil or raw == "" then return out end

  for pair in tostring(raw):gmatch("[^&]+") do
    local eq = pair:find("=", 1, true)
    local k, v
    if eq then
      k = pair:sub(1, eq - 1)
      v = pair:sub(eq + 1)
    else
      k = pair
      v = ""
    end
    if k ~= "" then
      k = M.decode(k, true)
      v = M.decode(v, true)
      local existing = out[k]
      if existing == nil then
        out[k] = v
      elseif type(existing) == "table" then
        existing[#existing + 1] = v
      else
        out[k] = { existing, v }
      end
    end
  end

  return out
end

--- Build a query string from a table.
---
--- Keys are emitted in SORTED order so the output is deterministic and
--- therefore testable -- Lua's `pairs` order is not specified and would
--- otherwise make the same input produce different hrefs across runs.
--- An array value emits one `key=value` pair per element, in array
--- order. Booleans and numbers are `tostring`ed.
---
--- @param t table|nil
--- @return string  without a leading "?"; "" for nil/empty input
function M.build_query(t)
  if t == nil then return "" end
  if type(t) ~= "table" then
    error("hydronium_router.url.build_query: expected a table, got " .. type(t), 2)
  end

  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local parts = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    local ek = M.encode(tostring(k))
    if type(v) == "table" then
      for _, item in ipairs(v) do
        parts[#parts + 1] = ek .. "=" .. M.encode(tostring(item))
      end
    else
      parts[#parts + 1] = ek .. "=" .. M.encode(tostring(v))
    end
  end

  return table.concat(parts, "&")
end

--- Normalize a path: collapse duplicate slashes, resolve `.` and `..`
--- for real, and guarantee a leading `/`.
---
--- `..` pops the previous segment; at the root it is DISCARDED rather
--- than allowed to escape above `/` (so `/../a` is `/a`, not `../a`).
--- A trailing slash is dropped (`/a/b/` -> `/a/b`); `/` itself stays
--- `/`. Trailing slashes are irrelevant to matching anyway -- the
--- matcher splits on `[^/]+` -- so dropping them just makes the
--- canonical form unambiguous.
---
--- @param p string|nil
--- @return string
function M.normalize_path(p)
  if p == nil or p == "" then return "/" end
  p = tostring(p)

  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == "." then
      -- current directory: no-op
    elseif seg == ".." then
      if #parts > 0 then
        parts[#parts] = nil
      end
      -- else: already at root, discard rather than escape
    else
      parts[#parts + 1] = seg
    end
  end

  if #parts == 0 then return "/" end
  return "/" .. table.concat(parts, "/")
end

--- Split a path into its decoded-agnostic raw segments.
--- Shared by `matcher`; kept here so the "what is a segment" rule lives
--- in exactly one place.
--- @param path string
--- @return string[]
function M.path_segments(path)
  local segs = {}
  for seg in tostring(path or ""):gmatch("[^/]+") do
    segs[#segs + 1] = seg
  end
  return segs
end

return M
