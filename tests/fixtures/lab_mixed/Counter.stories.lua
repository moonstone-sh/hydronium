local H = require("hydronium")
local lab = require("hydronium_lab")
local Counter = require("Counter")
return lab.collection({ renderer = "dom", component = Counter, args = { label = "DOM" }, controls = { label = { type = "text" } }, stories = { default = {}, alternate = { args = { label = "Alternate" } } } })
