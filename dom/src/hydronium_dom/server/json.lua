--- Deterministic, script-safe JSON serialization for SSR state.
--- This module intentionally supports only JSON data: nil, booleans, finite
--- numbers, strings, and acyclic tables with string object keys or contiguous
--- positive-integer array keys.
local M = {}

local escapes = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function escape_string(value)
  local escaped = value:gsub('[%z\1-\31\\"]', function(character)
    return escapes[character] or string.format('\\u%04x', character:byte())
  end)

  -- A JSON script is a raw-text HTML element. Escaping these code points means
  -- no string can terminate the element or start an HTML comment regardless of
  -- the JSON consumer's handling of HTML parser edge cases.
  escaped = escaped:gsub('<', '\\u003c'):gsub('>', '\\u003e'):gsub('&', '\\u0026')
  escaped = escaped:gsub('\226\128\168', '\\u2028'):gsub('\226\128\169', '\\u2029')
  return '"' .. escaped .. '"'
end

local function array_length(value)
  local max, count = 0, 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then
      return nil
    end
    if key > max then max = key end
    count = count + 1
  end
  if max == count and max > 0 then return max end
  return nil
end

local function encode(value, active)
  local kind = type(value)
  if kind == 'nil' then return 'null' end
  if kind == 'boolean' then return value and 'true' or 'false' end
  if kind == 'string' then return escape_string(value) end
  if kind == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then
      error('SSR state contains a non-finite number', 3)
    end
    return tostring(value)
  end
  if kind ~= 'table' then
    error('SSR state contains unsupported ' .. kind .. ' value', 3)
  end
  if active[value] then
    error('SSR state contains a cyclic table', 3)
  end

  active[value] = true
  local length = array_length(value)
  local result = {}
  if length then
    for index = 1, length do
      result[index] = encode(value[index], active)
    end
    active[value] = nil
    return '[' .. table.concat(result, ',') .. ']'
  end

  local keys = {}
  for key in pairs(value) do
    if type(key) ~= 'string' then
      active[value] = nil
      error('SSR state object keys must be strings', 3)
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for index, key in ipairs(keys) do
    result[index] = escape_string(key) .. ':' .. encode(value[key], active)
  end
  active[value] = nil
  return '{' .. table.concat(result, ',') .. '}'
end

function M.encode(value)
  return encode(value, {})
end

--[[
  M.decode -- minimal recursive-descent JSON reader, added for STEP 1 of
  docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md (the `vite-manifest` asset
  provider reads a real Vite `dist/.vite/manifest.json` file directly --
  the one manifest shape in this whole pipeline that genuinely originates
  as JSON, from a tool outside this codebase, rather than one this
  codebase's own build ever gets to choose Lua-table-literal for).

  Deliberately NOT a general-purpose JSON library: no streaming, no
  duplicate-key policy beyond "last write wins" (matches every mainstream
  decoder), no big-number handling beyond what Lua's own `tonumber` gives.
  Scoped exactly to what a Vite manifest.json (or any similarly plain
  JSON document) needs: objects, arrays, strings (with escapes incl.
  \uXXXX), numbers, true/false/null. Object keys become plain Lua string
  keys; JSON `null` decodes to a sentinel (M.null), never plain Lua `nil`
  (an array element or object value can't be `nil` in a Lua table without
  silently breaking `#`/iteration -- the same reason `dkjson` does this).
--]]

M.null = setmetatable({}, { __tostring = function() return "json.null" end })

local function skip_ws(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return e + 1
end

local decode_value -- forward

local unescape_map = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function decode_string(s, i)
  if s:sub(i, i) ~= '"' then
    error("json.decode: expected '\"' at position " .. i, 0)
  end
  i = i + 1
  local parts = {}
  local start = i
  while true do
    local c = s:sub(i, i)
    if c == "" then
      error("json.decode: unterminated string", 0)
    elseif c == '"' then
      parts[#parts + 1] = s:sub(start, i - 1)
      return table.concat(parts), i + 1
    elseif c == "\\" then
      parts[#parts + 1] = s:sub(start, i - 1)
      local esc = s:sub(i + 1, i + 1)
      if esc == "u" then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        if not code then
          error("json.decode: invalid \\u escape at position " .. i, 0)
        end
        -- Only the common BMP/ASCII range is round-tripped exactly; a Vite
        -- manifest's own strings (source paths, hashed filenames) never
        -- exceed this range in practice. Encode as UTF-8.
        if code < 0x80 then
          parts[#parts + 1] = string.char(code)
        elseif code < 0x800 then
          parts[#parts + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
        else
          parts[#parts + 1] = string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
          )
        end
        i = i + 6
        start = i
      else
        local replacement = unescape_map[esc]
        if not replacement then
          error("json.decode: invalid escape '\\" .. esc .. "' at position " .. i, 0)
        end
        parts[#parts + 1] = replacement
        i = i + 2
        start = i
      end
    else
      i = i + 1
    end
  end
end

local function decode_number(s, i)
  local m = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
  if not m or m == "" then
    error("json.decode: invalid number at position " .. i, 0)
  end
  local n = tonumber(m)
  if not n then
    error("json.decode: invalid number '" .. m .. "' at position " .. i, 0)
  end
  return n, i + #m
end

local function decode_array(s, i)
  i = skip_ws(s, i + 1)
  local out = {}
  if s:sub(i, i) == "]" then
    return out, i + 1
  end
  local n = 0
  while true do
    local value
    value, i = decode_value(s, i)
    n = n + 1
    out[n] = value
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "]" then
      return out, i + 1
    else
      error("json.decode: expected ',' or ']' at position " .. i, 0)
    end
  end
end

local function decode_object(s, i)
  i = skip_ws(s, i + 1)
  local out = {}
  if s:sub(i, i) == "}" then
    return out, i + 1
  end
  while true do
    i = skip_ws(s, i)
    local key
    key, i = decode_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ":" then
      error("json.decode: expected ':' at position " .. i, 0)
    end
    i = skip_ws(s, i + 1)
    local value
    value, i = decode_value(s, i)
    out[key] = value
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "}" then
      return out, i + 1
    else
      error("json.decode: expected ',' or '}' at position " .. i, 0)
    end
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then return decode_object(s, i) end
  if c == "[" then return decode_array(s, i) end
  if c == '"' then return decode_string(s, i) end
  if c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4 end
  if c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5 end
  if c == "n" and s:sub(i, i + 3) == "null" then return M.null, i + 4 end
  if c == "-" or c:match("%d") then return decode_number(s, i) end
  error("json.decode: unexpected character '" .. c .. "' at position " .. i, 0)
end

--- @param text string A complete JSON document.
--- @return any decoded value: nested tables (string-keyed objects, or
---   1-based-integer-keyed arrays), strings, numbers, booleans, or
---   M.null for JSON `null`. Raises a Lua error (not a `nil, err` pair)
---   on malformed input -- a caller that wants to degrade gracefully on
---   an absent/corrupt file should check for the file's existence first,
---   exactly as `hydronium_dom.assets.configure` already does for its
---   own Lua-table manifest.
function M.decode(text)
  if type(text) ~= "string" then
    error("json.decode: expected a string, got " .. type(text), 2)
  end
  local value, i = decode_value(text, 1)
  i = skip_ws(text, i)
  if i <= #text then
    error("json.decode: trailing data at position " .. i, 0)
  end
  return value
end

return M
