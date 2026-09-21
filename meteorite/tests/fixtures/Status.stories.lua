local H = require("hydronium")
local ink = require("hydronium_ink")
local lab = require("hydronium_lab")

return lab.collection({
  title = "Fixture/Status",
  render = function(args) return H.h(ink.Text, { color = "green" }, args.label) end,
  controls = { label = { type = "text" } },
  stories = { healthy = { args = { label = "healthy" } } },
})
