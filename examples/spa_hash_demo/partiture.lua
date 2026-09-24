-- M2/M3 proof for docs/HYDRONIUM_SPA_MODE_PLAN.md: bundles hydronium_router
-- into a real client chunk for the first time (M2), and produces the exact
-- chunk M3's static SPA loads via mount.js's `chunkUrls` (hydrate: false,
-- no Meteorite process at all -- see this example's own README-less
-- moonstone.toml description).
--
-- Modeled directly on examples/meteorite_ssr/partiture.lua's real
-- client.resolve/minify/bundle pipeline; the only new thing is router_src
-- joining core_src/dom_src as a third `depends_on` set, and `entries`
-- walking BOTH the router barrel and history.hash explicitly (the barrel's
-- own require graph does not reach history.hash -- see hash.lua's own doc
-- comment: browser/memory are the barrel's built-in defaults, hash is an
-- opt-in adapter an app requires itself, exactly as app.lua below does).
--
-- Run: moon exec -- ballad play partiture.lua
local ballad = require("ballad")
local hb = require("hydronium_ballad")

return ballad.partiture(function(p)
  local client = p:use(hb.plugins.client)
  local style = p:use(hb.plugins.style)
  local assets = p:use(hb.plugins.assets)
  local site = p:use(hb.plugins.site)

  local app_src = p.source.files({ "app.lua" }, {
    root = ".",
    metadata = { hydronium = { target = "client" } },
  })
  local core_src = p.source.files({ "**/*.lua" }, {
    root = "../../core/src",
    metadata = { hydronium = { target = "shared" } },
  })
  local dom_src = p.source.files({ "**/*.lua" }, {
    root = "../../dom/src",
    metadata = { hydronium = { target = "shared" } },
  })
  local router_src = p.source.files({ "**/*.lua" }, {
    root = "../../router/src",
    metadata = { hydronium = { target = "shared" } },
  })

  -- entries = {"app"}: app.lua is the one real require() edge into the
  -- whole router graph (it requires "hydronium_router" and
  -- "hydronium_router.history.hash" directly) -- nothing else needs to be
  -- listed for resolve()'s reachability walk to find the rest of
  -- hydronium_router/**, exactly the mechanism MOUNT_BOOTSTRAP_ENTRIES
  -- relies on for core/dom already.
  local resolved = client.resolve(app_src, {
    entries = { "app" },
    depends_on = { core_src, dom_src, router_src },
  })
  local minified = client.minify(resolved, { level = "safe" })
  local bundled = client.bundle(minified, { entry = "app" })

  -- M4: the asset half of an SPA. A static SPA has no SSR fallback, so a
  -- wrong asset URL or an unscoped class is a blank or unstyled page with
  -- nothing in any log -- which is why these are built and gated here rather
  -- than assumed.
  local css_src = p.source.files({ "app.css" }, { root = "." })
  local styles = style.bundle(css_src, { reset = false })

  local static_src = p.source.files({ "logo.svg" }, { root = "." })
  local hashed = assets.hash(static_src, {})

  -- One sink for the whole site: p.sink.directory removes its out tree first,
  -- so two sinks on the same dist/ would destroy each other.
  --
  -- M4: mount is opted into explicitly (site.manifest's default is no
  -- index.html at all -- see its own doc comment) because THIS partiture,
  -- unlike examples/meteorite_ssr's, really is a static SPA with nothing
  -- else serving "/". lua_globals wires up hydronium_router's hash-history
  -- adapter, which app.lua actually requires (history/hash.lua's own doc
  -- comment: it is an opt-in adapter an app requires itself, never a
  -- barrel default) -- site.manifest has no router awareness of its own,
  -- so a partiture that needs one supplies it here.
  local merged = site.manifest(hashed, {
    depends_on = { bundled, styles },
    mount = {
      title = "Hydronium SPA hash demo (static, no Meteorite)",
      lua_globals = { module = "/js/router/hash_history.js", import = "createHashHistoryGlobals" },
      -- Ships the real bytes index.html's own <script> tags reference, so
      -- dist/ is deployable to a plain static file server with nothing else
      -- running (docs/HYDRONIUM_SPA_MODE_PLAN.md section 2.1's "one HTML
      -- shell, served by anything" -- verified for real: a bare `python3 -m
      -- http.server` inside dist/ 404'd on both of these before this).
      -- dom/src/hydronium_dom/client/ is the generated-but-committed copy
      -- of @hydronium-js/dom-client (js/scripts/sync-dom-client.mjs,
      -- check-dom-client-drift.mjs -- not touched here); router/client/ is
      -- a second, unpackaged pile the SPA plan's own hazard list already
      -- flags for folding into dom-client later (not done here either).
      vendor = {
        { dir = "../../dom/src/hydronium_dom/client", url_prefix = "js/bootstrap" },
        { dir = "../../router/client", url_prefix = "js/router" },
      },
    },
  })

  p.sink.directory(merged, { out = "dist", file_graph = true })
end)
