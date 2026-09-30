local H = require("hydronium")
local lab = require("hydronium_lab")
return lab.story({ id = "terminal", renderer = "ink", title = "Terminal", args = { label = "Ink" }, controls = { label = { type = "text" } }, render = function(args) return H.h("text", nil, args.label) end })
