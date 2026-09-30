local lab = require("hydronium_lab")
return lab.collection({ renderer = "dom", component = require("Docs"), stories = { default = {} } })
