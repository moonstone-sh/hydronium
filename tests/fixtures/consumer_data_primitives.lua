-- Copied into a fresh artifact-only consumer by the release gate.
local query = require("hydronium_query")
local virtual = require("hydronium_virtual")
local table_api = require("hydronium_table")

local client = query.createClient({ clock = function() return 0 end })
local observed
client:observe({ key = { "people" }, stale_time = 60, query = function(_, done) done(nil, { ok = true }) end }, function(state) observed = state end)
assert(observed.status == "success" and observed.data.ok)

local people = { { id = "ada", team = "compiler", score = 10 }, { id = "lin", team = "compiler", score = 20 } }
local model = table_api.createTable({
  rows = people, row_id = function(row) return row.id end,
  columns = {
    { id = "team", accessor = function(row) return row.team end },
    { id = "score", accessor = function(row) return row.score end },
  },
  grouping = { "team" },
  aggregations = { score = function(rows) local total = 0; for _, row in ipairs(rows) do total = total + row.original.score end; return total end },
})
model:setColumnPinning({ left = { "team" }, right = {} })
assert(model:getGroupedRows()[1].cells.score == 30)

local list = virtual.createVirtualizer({ count = function() return #model:getRows() end, estimate_size = 24, key = function(index) return model:getRows()[index + 1].id end })
list:setViewportSize(30); list:measure(0, 30)
assert(list:getVirtualItems()[1].key == "ada")
assert(model:getColumnGroups().left[1].id == "team")
print("consumer data primitives: ok")

-- Auth must come from its own artifact rather than leaking through Core.
local auth = require("hydronium_auth")
local reply, cancelled
local flow = auth.createFlow({transport=function(_, _, done)
  reply=done
  return function()cancelled=true end
end})
assert(flow:submit("email", {}))
assert(flow.state().pending)
flow:reset()
reply(nil, {step="complete"})
assert(cancelled and flow.state().step=="credentials" and not flow.state().pending)
flow:dispose()
assert(not flow:submit("email", {}))
