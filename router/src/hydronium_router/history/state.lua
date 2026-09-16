--[[
  JSON-shaped navigation-state codec.

  Browser history crosses the JS/Lua boundary as text.  Keeping the wire
  value textual avoids depending on a host runtime's object/table marshaller,
  while this deliberately small codec makes the accepted data model explicit:
  nil, booleans, finite numbers, strings, and acyclic arrays or objects.
--]]

local M = {}

local function fail(message, level)
  error("hydronium_router history state: " .. message, level or 3)
end

local escapes = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function quote(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    return escapes[character] or string.format('\\u%04x', character:byte())
  end) .. '"'
end

local function table_shape(value)
  local max, count, strings, numbers = 0, 0, 0, 0
  for key in pairs(value) do
    count = count + 1
    if type(key) == "string" then
      strings = strings + 1
    elseif type(key) == "number" and key >= 1 and key == math.floor(key) then
      numbers = numbers + 1
      if key > max then max = key end
    else
      fail("table keys must be strings or contiguous positive integers")
    end
  end
  if count == 0 or strings == count then return "object", 0 end
  if numbers == count and max == count then return "array", max end
  if strings > 0 and numbers > 0 then
    fail("a table cannot mix object keys and array indexes")
  end
  fail("array indexes must be contiguous from 1")
end

local function encode(value, active)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "string" then return quote(value) end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      fail("numbers must be finite")
    end
    return tostring(value)
  end
  if kind ~= "table" then
    fail("unsupported " .. kind .. " value")
  end
  if active[value] then fail("tables must not be cyclic") end

  active[value] = true
  local shape, length = table_shape(value)
  local out = {}
  if shape == "array" then
    for index = 1, length do out[index] = encode(value[index], active) end
    active[value] = nil
    return "[" .. table.concat(out, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys)
  for index, key in ipairs(keys) do
    out[index] = quote(key) .. ":" .. encode(value[key], active)
  end
  active[value] = nil
  return "{" .. table.concat(out, ",") .. "}"
end

--- Encode a JSON-shaped Lua value for the browser bridge.
---@param value any
---@return string
function M.encode(value)
  return encode(value, {})
end

local function utf8(codepoint)
  if codepoint <= 0x7f then return string.char(codepoint) end
  if codepoint <= 0x7ff then
    return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
  end
  if codepoint <= 0xffff then
    return string.char(
      0xe0 + math.floor(codepoint / 0x1000),
      0x80 + math.floor(codepoint / 0x40) % 0x40,
      0x80 + codepoint % 0x40
    )
  end
  return string.char(
    0xf0 + math.floor(codepoint / 0x40000),
    0x80 + math.floor(codepoint / 0x1000) % 0x40,
    0x80 + math.floor(codepoint / 0x40) % 0x40,
    0x80 + codepoint % 0x40
  )
end

--- Decode text emitted by `encode`. This is intentionally strict so a page
--- cannot smuggle executable Lua through a forged history entry.
---@param source string|nil
---@return any
function M.decode(source)
  if source == nil then return nil end
  if type(source) ~= "string" then fail("bridge payload must be a string or nil", 2) end
  local position, length = 1, #source

  local function skip_space()
    local _, finish = source:find("^[ \t\r\n]*", position)
    position = (finish or position - 1) + 1
  end

  local parse_value
  local function parse_string()
    position = position + 1
    local out, start = {}, position
    while position <= length do
      local byte = source:byte(position)
      if byte == 34 then
        out[#out + 1] = source:sub(start, position - 1)
        position = position + 1
        return table.concat(out)
      end
      if byte < 32 then fail("string contains an unescaped control character", 2) end
      if byte == 92 then
        out[#out + 1] = source:sub(start, position - 1)
        local escape = source:sub(position + 1, position + 1)
        local simple = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
        if simple[escape] then
          out[#out + 1] = simple[escape]
          position = position + 2
        elseif escape == "u" then
          local hex = source:sub(position + 2, position + 5)
          if not hex:match("^%x%x%x%x$") then fail("invalid unicode escape", 2) end
          local codepoint = tonumber(hex, 16)
          position = position + 6
          if codepoint >= 0xd800 and codepoint <= 0xdbff then
            if source:sub(position, position + 1) ~= "\\u" then fail("unpaired unicode surrogate", 2) end
            local low_hex = source:sub(position + 2, position + 5)
            local low = tonumber(low_hex, 16)
            if not low or low < 0xdc00 or low > 0xdfff then fail("unpaired unicode surrogate", 2) end
            codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
            position = position + 6
          elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
            fail("unpaired unicode surrogate", 2)
          end
          out[#out + 1] = utf8(codepoint)
        else
          fail("invalid string escape", 2)
        end
        start = position
      else
        position = position + 1
      end
    end
    fail("unterminated string", 2)
  end

  local function parse_array()
    position = position + 1
    local result = {}
    skip_space()
    if source:sub(position, position) == "]" then position = position + 1; return result end
    while true do
      result[#result + 1] = parse_value()
      skip_space()
      local token = source:sub(position, position)
      if token == "]" then position = position + 1; return result end
      if token ~= "," then fail("expected ',' or ']'", 2) end
      position = position + 1
    end
  end

  local function parse_object()
    position = position + 1
    local result = {}
    skip_space()
    if source:sub(position, position) == "}" then position = position + 1; return result end
    while true do
      skip_space()
      if source:sub(position, position) ~= '"' then fail("object key must be a string", 2) end
      local key = parse_string()
      skip_space()
      if source:sub(position, position) ~= ":" then fail("expected ':' after object key", 2) end
      position = position + 1
      result[key] = parse_value()
      skip_space()
      local token = source:sub(position, position)
      if token == "}" then position = position + 1; return result end
      if token ~= "," then fail("expected ',' or '}'", 2) end
      position = position + 1
    end
  end

  function parse_value()
    skip_space()
    local token = source:sub(position, position)
    if token == '"' then return parse_string() end
    if token == "[" then return parse_array() end
    if token == "{" then return parse_object() end
    if source:sub(position, position + 3) == "true" then position = position + 4; return true end
    if source:sub(position, position + 4) == "false" then position = position + 5; return false end
    if source:sub(position, position + 3) == "null" then position = position + 4; return nil end
    local number_text = source:match("^-?%d+%.?%d*[eE]?[+-]?%d*", position)
    if number_text and number_text ~= "" then
      local value = tonumber(number_text)
      if value then position = position + #number_text; return value end
    end
    fail("invalid value at byte " .. position, 2)
  end

  local value = parse_value()
  skip_space()
  if position <= length then fail("trailing data at byte " .. position, 2) end
  return value
end

return M
