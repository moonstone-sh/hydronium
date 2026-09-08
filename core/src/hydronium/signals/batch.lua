--[[
  Hydronium Batch & Untrack Utilities
  Batched mutation blocks and untracked read boundaries.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local scheduler = require("hydronium.core.scheduler")
local graph = require("hydronium.signals.graph")

local unpack = table.unpack or unpack

local batchModule = {}

function batchModule.batch(fn, ...)
  scheduler.startBatch()
  local args = { ... }
  local n = select("#", ...)
  local ok, res1, res2, res3 = pcall(function()
    return fn(unpack(args, 1, n))
  end)

  if not ok then
    scheduler.cancelBatch()
    error(res1, 0)
  end

  scheduler.endBatch()
  return res1, res2, res3
end

batchModule.untrack = graph.untrack

return batchModule
