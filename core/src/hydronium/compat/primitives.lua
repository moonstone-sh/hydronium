-- Non-reflective Lua dialect helpers. This module never compiles code or
-- reads debug metadata; ordinary UI and signal code can import it directly.
local function integral(value)
  if type(value) == "number" and value == math.floor(value)
    and value > -math.huge and value < math.huge then return value end
  return nil
end

local unpack_values, tointeger
if jit ~= nil or _VERSION == "Lua 5.1" then
  unpack_values, tointeger = unpack, integral
else
  unpack_values, tointeger = table.unpack, math.tointeger or integral
end
---@type HydroniumCompatPrimitives
return { unpack = unpack_values, tointeger = tointeger }
