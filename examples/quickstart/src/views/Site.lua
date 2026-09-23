local r = require("hydronium_router")

return r.createSite({
	root = r.node({
		id = "root",
		path = "/",
		children = {
			r.node({
				id = "home",
				path = "",
				screen = "views.Home",
				actions = { contact = { id = "contact.submit", ref = "app.contact_action", path = "/actions/contact" } },
			}),
			r.node({ id = "about", path = "about", screen = "views.About" }),
		},
	}),
})
