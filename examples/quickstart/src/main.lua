-- Server entrypoint.
--
-- Meteorite owns HTTP: every route below is an ordinary Meteorite
-- declaration. Hydronium contributes three things to it:
--
--   1. `hydronium.mount(app)` -- the framework's own routes (browser runtime,
--      framework source, dev module server, HMR stream). Nothing to copy.
--   2. `router.mount(app, site, ...)` -- one GET per addressable page in
--      views/Site.lua, rendered by app/page_handler.lua, plus its form actions.
--   3. Plain route handlers -- any Meteorite route can render a Hydronium
--      component (see /hello/:name and app/hello.lua).
--
-- Handlers live in their own modules (`meteorite.lua("app.x")`) because
-- Meteorite's hybrid build loads each handler standalone per request; an
-- inline `function(c) ... end` must not capture locals from this file.
local meteorite = require("meteorite")
local hydronium = require("hydronium_dom.server.meteorite")
local router = require("hydronium_router.meteorite")
require("hydronium_luax").loader.install()

local app = meteorite.app({
	name = "hydronium-quickstart",
	host = "127.0.0.1",
	port = tonumber(os.getenv("PORT")) or 8080,
	-- A built server also honours PORT at start-up (Meteorite 0.3.4+).
	port_env = "PORT",
	-- Hot UI modules declared in hydronium.sources.lua are passive: the browser
	-- swaps them in place, so editing one must not restart the server.
	dev_watch = hydronium.dev_watch(),
})

-- Before meteorite.site: Meteorite matches routes in declaration order, and in
-- development mount serves the watched stylesheet from disk at its own URL.
hydronium.mount(app)

meteorite.site(app, {
	root = ".",
	assets = {
		["/public/:path*"] = { dir = "public", param = "path" },
	},
})

local site = require("views.Site")
router.mount(app, site, {
	handler = meteorite.lua("app.page_handler", { arg_mode = "lazy_context" }),
	action_handler = meteorite.lua("app.action_handler", { arg_mode = "lazy_context" }),
})

-- A plain Meteorite route rendering a Hydronium component: no router, no
-- browser VM. The component lives in src/features/, not src/views/.
app:get("/hello/:name", {
	summary = "Server-rendered greeting",
},meteorite.lua("app.hello", { arg_mode = "lazy_context" }))

app:get("/api/health", { summary = "Health check" }, function(c)
	return c:json({ status = "ok", timestamp = os.time() })
end)

router.validate_final(app, site)

return app
