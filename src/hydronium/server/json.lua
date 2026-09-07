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

return M
