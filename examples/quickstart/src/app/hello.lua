-- A Meteorite route handler that renders a Hydronium component on the server.
-- Each hybrid request VM has its own package loaders, so install the LUAX
-- searcher at this entry before requiring a .luax module.
require("hydronium_luax").loader.install()
local dom = require("hydronium_dom.server.meteorite")
local Greeting = require("features.greeting.Greeting")

return function(c)
	return dom.render(c, Greeting, {
		props = { name = c:param("name") },
	})
end
