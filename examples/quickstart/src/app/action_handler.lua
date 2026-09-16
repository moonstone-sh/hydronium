local adapter = require("hydronium_router.meteorite")
local site = require("views.Site")

return adapter.action_handler(site, {
	resolve_action = require,
})
