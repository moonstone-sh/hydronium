--[[
  Hydronium Test act() Utility
  Executes user interaction and state updates inside a synchronous flush boundary.
  Guarantees that all component renders and effects are fully committed.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local scheduler = require("hydronium.core.scheduler")

local unpack = table.unpack or unpack

local actModule = {}

function actModule.act(fn, ...)
  local args = { ... }
  local n = select("#", ...)

  local ok, res1, res2, res3 = pcall(function()
    return fn(unpack(args, 1, n))
  end)

  scheduler.flush()

  if not ok then
    error(res1, 0)
  end

  return res1, res2, res3
end

return actModule
