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
