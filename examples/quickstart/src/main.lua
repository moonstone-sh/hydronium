-- Server entrypoint
local meteorite = require("meteorite")

local app = meteorite.app({
	name = "hydronium-quickstart",
	host = "0.0.0.0",
	port = 8080,
})

meteorite.site(app, {
	root = ".",
	assets = {
		["/public/:path*"] = { dir = "public", param = "path" },
	},
})

-- The compiled client bootstrap (mount.js, dom_bridge.js, hmr.js,
-- dev_reload.js) lives in the sibling hydronium checkout, served directly
-- from its real source -- dev/example serving, same as the /hydronium-src
-- and /__hydronium/client routes below, not a production asset pipeline
-- (see hydronium/docs/BUNDLING.md).
--
-- Declared here as a plain app:get rather than as one more `assets` entry
-- in m.site() above -- which is where it used to live, and where it looks
-- like it belongs -- for one concrete reason: m.site()'s asset spec has no
-- way to pass per-route `memory`, and this particular directory now
-- contains hydronium's self-hosted copy of wasmoon, whose glue.wasm is
-- 271,581 bytes.
--
-- Meteorite serves a dev `m.dir` file by reading it whole into the
-- PER-REQUEST ARENA, which the default/hybrid_dev profile sizes at 256kb
-- (262,144 bytes). The wasm binary overshoots that by ~9kb, so the request
-- died with a bare `OutOfMemory` -> HTTP 500 (visible only in
-- .meteorite/dev/server.log; the browser just saw a failed fetch and the
-- Lua VM never booted). Note this is NOT the 1mb max_response_bytes cap --
-- raising that would have changed nothing.
--
-- 1mb of arena leaves real headroom for wasmoon to grow across versions
-- without this failing again in the same confusing way. Dev-only cost.
-- VENDOR SPLIT, declared BEFORE the general /js/bootstrap route below --
-- that order is load-bearing, not cosmetic. Meteorite's router is a
-- first-match-wins linear scan in DECLARATION order (zig/server/route_dispatch.zig's
-- `inline for (routes)`); there is no longest-prefix or specificity rule.
-- Both this route and the one below match /js/bootstrap/vendor/..., so
-- whichever is declared first wins. Moving this below the other silently
-- reverts the caching fix rather than erroring.
--
-- Why it needs its own route at all: `m.dir`'s cache lifetime is
-- PER-ROUTE, and this one directory holds two things with opposite
-- caching needs -- hydronium's own client JS (mount.js, hmr.js,
-- dom_bridge.js), edited constantly during development, and the
-- vendored, version-pinned wasmoon build under vendor/ (glue.wasm +
-- index.js = ~423KB of the ~462KB total), which changes only when
-- somebody deliberately re-vendors a new wasmoon release.
--
-- Before this split every one of those files was served
-- `cache-control: no-cache` (Meteorite's `m.dir` default, see
-- src/core/handler_factories.lua), which does NOT mean "don't cache" --
-- it means "revalidate before every reuse". Measured with Playwright
-- against this running server: a repeat visit made a conditional round
-- trip for all six files (transferSize 300 bytes each, 304 Not
-- Modified) before the Lua VM could start. Cheap over localhost,
-- six serial RTTs on a real network.
--
-- NOT `immutable`, deliberately. `opts.immutable` would emit
-- `public, max-age=31536000, immutable` -- a year-long, unconditional,
-- un-revalidatable promise on a URL with NO content hash in it, so
-- re-vendoring wasmoon would strand every already-warm client on the
-- old binary with no way for the server to correct them. Real content
-- hashing (hydronium_ballad.plugins.assets' b3sum scheme) is what makes
-- `immutable` safe, and it does not apply here: that plugin rewrites
-- Ballad build-graph AssetSets, while these URLs are resolved at runtime
-- by mount.js against its own `import.meta.url` and by hand-written
-- <script type="module"> tags in views/Document.luax. Hashing them means a
-- real asset pipeline rewriting those references -- the separate,
-- still-open bundler work (hydronium/docs/BUNDLING.md).
--
-- A bounded lifetime needs none of that and cannot strand anyone:
-- Meteorite already emits a real content-derived b3 ETag per file and
-- honours If-None-Match with a 304, so once the day expires the client
-- revalidates and self-heals automatically. 24h of zero round trips for
-- a repeat visitor, 24h worst-case staleness -- instead of a year.
app:get("/js/bootstrap/vendor/:path*", {
	memory = { request_arena = "1mb" },
}, meteorite.dir("../../dom/src/hydronium_dom/client/vendor", {
	param = "path",
	cache = "public, max-age=86400, must-revalidate",
}))

-- Hydronium's own client JS. Stays revalidate-every-time (`no-cache`),
-- and that is the right answer rather than an oversight: these files are
-- edited during development, and a stale mount.js/hmr.js served out of
-- a browser cache is a genuinely confusing failure. Stated explicitly
-- rather than left to the factory default so it reads as a decision.
-- They are also small (~35KB combined) -- the caching win was never here.
app:get("/js/bootstrap/:path*", {
	memory = { request_arena = "1mb" },
}, meteorite.dir("../../dom/src/hydronium_dom/client", {
	param = "path",
	cache = "no-cache",
}))

-- Serves hydronium's own runtime source for hydronium.client.mount to
-- fetch over HTTP, exactly as hydronium/examples/meteorite_ssr does --
-- restricted to `.lua`/`.json` under the two real member source roots,
-- no `..` traversal.
app:get("/hydronium-src/:path*", function(c)
	local rel = c:param("path") or ""
	if rel:find("%.%.") or not (rel:match("%.lua$") or rel:match("%.json$")) then
		return c:text(400, "invalid path")
	end
	local source_root
	if rel:match("^hydronium/") then
		source_root = "../../core/src/"
	elseif rel:match("^hydronium_dom/") then
		source_root = "../../dom/src/"
	else
		return c:text(404, "not found")
	end
	local f = io.open(source_root .. rel, "r")
	if not f then
		return c:text(404, "not found")
	end
	local content = f:read("*a")
	f:close()
	return c:text(200, content)
end)

-- The manifest hydronium.client.mount fetches to know which framework
-- files to load -- a plain JSON file this template ships, not generated
-- per-request (see hydronium/dom/tools/gen_client_manifest.lua for how
-- it was produced; regenerate it the same way if you add new client-side
-- requires that change the transitive module graph).
app:get("/__hydronium/client_manifest.json", function(c)
	local f = assert(io.open("client_manifest.json", "r"))
	local content = f:read("*a")
	f:close()
	return c:text(200, content)
end)

-- Serves ONE of this project's own view modules, by require() id, as
-- compiled Lua source. `views.Counter` -> `views/Counter.luax`, compiled
-- on demand by hydronium_luax's serve-time loader (mtime-cached, no
-- build step) and returned as text -- never executed here, because it is
-- the browser's Lua VM that runs it, not the server's.
--
-- Both the first load and every hot update go through this one route:
-- views/Document.luax passes these URLs to mount(), and
-- hydronium_dom/client/hmr.js re-fetches the same URL on each change. One
-- source of truth, so the two can never drift apart.
--
-- SCOPE, deliberately: `views.*` only. This is not the general
-- `/__hydronium/dev/module/:id` route with a `loader.install()` package
-- searcher behind it that the roadmap's M3 describes -- it resolves no
-- framework modules (those still come from the manifest + /hydronium-src)
-- and installs no searcher. Serving arbitrary dotted ids from the project
-- root would also hand out src/main.lua and anything else on disk, which
-- a dev convenience has no business doing.
app:get("/__hydronium/dev/module/:id", function(c)
	local id = c:param("id") or ""
	if not id:match("^views%.[%w_]+$") then
		return c:text(400, "invalid module id (expected views.<Name>)")
	end

	local rel = id:gsub("%.", "/")
	local luax_path = rel .. ".luax"
	local probe = io.open(luax_path, "r")
	if probe then
		probe:close()
		local loader = require("hydronium_luax").loader
		local ok, code = pcall(loader.source, luax_path)
		if not ok then
			-- 500 with the real compiler message in the body: hmr.js treats a
			-- non-200 as "hot swap failed" and falls back to a full reload,
			-- and the message is then readable in the network panel rather
			-- than swallowed. (A real error overlay is roadmap M5.)
			return c:text(500, "-- hydronium dev: compile failed for " .. id .. "\n-- " .. tostring(code))
		end
		return c:text(200, code)
	end

	local f = io.open(rel .. ".lua", "r")
	if not f then
		return c:text(404, "not found")
	end
	local content = f:read("*a")
	f:close()
	return c:text(200, content)
end)

app:get("/", function(c)
	local meteorite_adapter = require("hydronium_dom.server.meteorite")
	local Document = require("views.Document")
	return meteorite_adapter.render(c, Document, {
		status = 200,
		props = { title = "hydronium-quickstart" },
	})
end)

app:get("/api/health", function(c)
	return c:json({ status = "ok", timestamp = os.time() })
end)

-- Dev update endpoint: the browser's hmr.js (served above) connects here
-- and is told exactly which file moved. views/App.luax and
-- views/Counter.luax are hot Lua modules, views/Document.luax is an
-- explicit page-reload boundary, and style.css is replaced in place. See
-- hydronium_dom.dev.watch's own
-- doc comment for why this route must stay written inline here rather
-- than behind a one-line library call (Meteorite's hybrid build can only
-- lift an inline handler it can see the literal source of).
--
-- Keep this list in step with the `updates` map in views/Document.luax: this
-- side decides what is watched, that side decides what a watched file
-- means to the running VM.
--
-- These files sit at the PROJECT ROOT, not under src/, and that is
-- load-bearing: `meteorite dev` watches src/ and rebuilds and restarts
-- the server when anything there changes, which would tear down the very
-- page HMR is trying to preserve.
app:get("/__hydronium/watch", function(c)
	local watch = require("hydronium_dom.dev.watch")
	watch.serve_sse(c, {
		"views/App.luax",
		"views/Counter.luax",
		"views/Document.luax",
		"public/style.css",
	})
end)

return app
