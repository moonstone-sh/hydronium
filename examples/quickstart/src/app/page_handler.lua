local adapter = require("hydronium_router.meteorite")
local site = require("views.Site")

return adapter.handler(site, {
	resolve = require,
	render = function(c, page, opts)
		local Document = require("views.Document")
		local d = require("hydronium_dom").d
		local dom = require("hydronium_dom.server.meteorite")
		return dom.render(c, Document, {
			status = opts.status,
			state = opts.state,
			props = {
				title = "Hydronium + Meteorite",
				app = d.lua.mount(page, { module = "views.App" }),
			},
		})
	end,
})
