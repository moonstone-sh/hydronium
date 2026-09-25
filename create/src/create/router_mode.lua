--[[
  Additive Hydronium Router wiring for the `islands` template.

  `islands`'s default routing story is deliberately the simplest one: ONE
  static page, hand-declared as a literal `app:get("/", function(c) ...
  end)` in `src/main.lua` (see that file's own header comment in
  templates/islands.lua). This module adds the OTHER option
  `create`'s wizard / `--router hydronium` flag offers: a real
  `hydronium/router` site manifest, lowered to explicit Meteorite GET
  routes -- the same `hydronium_router.meteorite` adapter
  templates/ssr.lua already uses (`M.handler`/`M.mount`/`M.validate_final`,
  read directly from router/src/hydronium_router/meteorite.lua to confirm
  this call shape), applied to a second, real page (`/about`) so the
  manifest has more than one leaf to actually demonstrate.

  Unlike ssr.lua, there is no client-side Lua VM here: `opts.render` hands
  the matched route's vnode straight to
  `hydronium_dom.server.meteorite.render` with no `d.lua.mount(...)`
  wrapper, so this stays a purely server-rendered, JS-island-hydrated page
  set -- multi-page navigation is ordinary `<a href>` full page loads, not
  client-side routing. That is the actual, honest tradeoff behind
  "recommended": a typed, centrally-declared route manifest and less
  hand-written per-route dispatch code, not a client SPA. `--router
  meteorite` (the default) stays exactly today's `islands` template,
  unmodified.

  NOT independently verified against a real `zig build`/running server the
  way ssr.lua's and islands.lua's own base content were (see each of those
  files' header comments, and this repo's CLAUDE.md, for what that
  verification bar means here -- a live build, run, and curl/click). This
  was checked for syntactic and require-graph validity only: every
  generated `.lua`/`.luax` file here loads/compiles cleanly (see
  tests/create_spec.lua's router-mode tests), and the API calls below were
  matched against a direct reading of
  router/src/hydronium_router/{meteorite.lua,site.lua,init.lua}, not a
  live request. Treat it accordingly until someone runs it for real.
]]

local M = {}

local function insert_after(haystack, anchor, insertion)
  local s, e = haystack:find(anchor, 1, true)
  if not s then return nil, "anchor not found" end
  return haystack:sub(1, e) .. insertion .. haystack:sub(e + 1)
end

-- `[=[ ... ]=]` (not plain `[[ ... ]]`) because the anchor's own content
-- contains the literal substring "[[dependencies]]" -- see ssr.lua's own
-- header comment for the identical reason.
local DOM_DEP_ANCHOR = [=[[[dependencies]]
name = "hydronium/dom"
constraint = "^0.2.0"
role = "runtime"]=]

local ROUTER_DEP_BLOCK = [=[

[[dependencies]]
name = "hydronium/router"
constraint = "^0.2.0"
role = "runtime"]=]

--- Mutates `files` in place (and returns it) to replace `islands`'s single
--- hand-written route with a `hydronium/router` site manifest of two
--- pages. Errors loudly on a missing anchor (a programmer error at the
--- call site -- `islands.lua`'s base content drifting out from under this
--- module -- not a user input error).
function M.apply_islands(files, opts)
  opts = opts or {}
  local project_name = opts.name or "my-hydronium-islands"

  local toml, err = insert_after(files["moonstone.toml"], DOM_DEP_ANCHOR, ROUTER_DEP_BLOCK)
  if not toml then
    error("create.router_mode: " .. tostring(err) .. " in moonstone.toml", 2)
  end
  files["moonstone.toml"] = toml

  -- The shared shell. Page content moves to views/Home.luax and
  -- views/About.luax so both can be rendered into `{props.page}` by
  -- whichever route the router manifest matched.
  files["views/Document.luax"] = string.format([=[-- Server-rendered shell shared by every page the router manifest below
-- resolves. src/app/page_handler.lua renders whichever page the URL
-- matched into `props.page`.
local H = require("hydronium")

local function Document(props)
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>%s</title>
        <link rel="stylesheet" href="/public/style.css" />
      </head>
      <body>
        <div class="shell">{props.page}</div>

        {H.h("script", { type = "module" },
          "import { activate } from '/js/bootstrap/bootstrap.js'; activate();")}
        {H.h("script", { type = "module", src = "/js/bootstrap/dev_reload.js" })}
      </body>
    </html>
  )
end

return Document
]=], project_name)

  files["src/views/Home.lua"] = [[return require("hydronium_luax").loader.load("views/Home.luax")
]]

  files["views/Home.luax"] = string.format([=[-- The home page's own content -- moved out of Document.luax so the shell
-- can be shared with router-resolved pages (see views/About.luax).
-- `local H` is required even though every tag below is bare (not
-- `d.<tag>`): compiled LUAX emits `H.h(...)` for every element regardless
-- of tag syntax, resolved as an ordinary Lua name -- verified the hard
-- way (a real `moon run build` + `curl` against this exact file failed
-- with "attempt to index a nil value (global 'H')" before this line was
-- added). See templates/ssr.lua's Counter.luax for the same convention.
local H = require("hydronium")
local d = require("hydronium_dom").d

-- Rendered once during SSR (initial value only) AND shipped as the real
-- hydration target for public/js/island/counter.js's hydrate(context) --
-- it must render as exactly ONE root element (a bare <button>). See
-- templates/islands.lua's own header comment for why.
local function JsCounter(props)
  return <button class="btn btn-primary" data-testid="js-counter-btn">Count: {tostring(props.initial or 0)}</button>
end

local function Home()
  local initial = 10

  return (
    <main>
      <header>
        <h1>%s</h1>
        <p>Server-rendered shell with one real, client-hydrated JS island</p>
        <a href="/about">About this app</a>
      </header>

      <section class="content">
        <h2>Static Content (0 KB Client JavaScript)</h2>
        <p>This section is rendered purely on the server; nothing below it ships any client code for it.</p>
      </section>

      <section class="island-container">
        <h2>Interactive Island (real hydration)</h2>
        <d.js.island module="/js/island/counter.js" hydrate="visible" props={{ initial = initial }}>
          <JsCounter initial={initial} />
        </d.js.island>
      </section>
    </main>
  )
end

return Home
]=], project_name)

  files["src/views/About.lua"] = [[return require("hydronium_luax").loader.load("views/About.luax")
]]

  files["views/About.luax"] = [[-- A second, real page -- exists so the router manifest below has more
-- than one leaf to demonstrate. Plain server-rendered content, no
-- signals, no client hooks: this template ships no client-side Lua VM, so
-- page-to-page navigation is an ordinary full page load via <a href>, not
-- client-side routing.
-- `local H` is required for the bare tags below -- see views/Home.luax's
-- own comment for why (verified live: this file 500'd with "attempt to
-- index a nil value (global 'H')" before this line was added).
local H = require("hydronium")

local function About()
  return (
    <main>
      <header>
        <h1>About</h1>
        <p>This page is selected by the shared hydronium/router site manifest, not a hand-written route.</p>
        <a href="/">Back home</a>
      </header>
    </main>
  )
end

return About
]]

  files["views/Site.lua"] = [[local r = require("hydronium_router")

return r.createSite({
  root = r.node({
    id = "root",
    path = "/",
    children = {
      r.node({ id = "home", path = "", screen = "views.Home" }),
      r.node({ id = "about", path = "about", screen = "views.About" }),
    },
  }),
})
]]

  files["src/app/page_handler.lua"] = [[local adapter = require("hydronium_router.meteorite")
local dom = require("hydronium_dom.server.meteorite")
local site = require("views.Site")

return adapter.handler(site, {
  resolve = require,
  resolve_loader = require,
  render = function(c, page, opts)
    local Document = require("views.Document")
    return dom.render(c, Document, {
      status = opts.status,
      state = opts.state,
      props = { page = page },
    })
  end,
})
]]

  files["src/main.lua"] = string.format([[local meteorite = require("meteorite")

local app = meteorite.app({
  name = "%s",
  host = "127.0.0.1",
  port = 8080,
})

meteorite.site(app, {
  root = ".",
  assets = {
    ["/public/:path*"] = { dir = "public", param = "path" },
    ["/js/bootstrap/:path*"] = { dir = "public/js/bootstrap", param = "path" },
    ["/js/island/:path*"] = { dir = "public/js/island", param = "path" },
  },
})

-- `dev_reload.js` performs a full page reload when this bounded SSE handler
-- observes an edit. This is intentionally live reload, not state-preserving HMR.
app:get("/__hydronium/watch", meteorite.lua("dev_watch", { arg_mode = "lazy_context" }))

-- Every page is declared once, in views/Site.lua, and lowered here to
-- explicit Meteorite GET routes -- see hydronium_router.meteorite's own
-- doc comment for why this does not synthesize a catch-all: asset routes
-- above stay ordinary Meteorite declarations.
local site = require("views.Site")
local router_adapter = require("hydronium_router.meteorite")
router_adapter.mount(app, site, {
  handler = meteorite.lua("app.page_handler", { arg_mode = "lazy_context" }),
})
router_adapter.validate_final(app, site)

return app
]], project_name)

  files["src/dev_watch.lua"] = [[-- Full-page development reload transport for the generated app.
local watch = require("hydronium_dom.dev.watch")

return function(c)
  watch.serve_sse(c, {
    "views/Document.luax",
    "views/Home.luax",
    "views/About.luax",
    "views/Site.lua",
    "src/app/page_handler.lua",
    "src/main.lua",
    "src/dev_watch.lua",
    "public/style.css",
    "public/js/bootstrap/bootstrap.js",
    "public/js/bootstrap/boundary_registry.js",
    "public/js/bootstrap/priority.js",
    "public/js/bootstrap/dev_transport.js",
    "public/js/bootstrap/dev_reload.js",
    "public/js/island/counter.js",
  })
end
]]

  files["README.md"] = (files["README.md"] or "") .. [[

## Routing (Hydronium Router)

This project was scaffolded with `--router hydronium`: `views/Site.lua`
declares every page in one typed manifest, and `hydronium_router.meteorite`
lowers it to explicit Meteorite GET routes in `src/main.lua` (see
`src/app/page_handler.lua`) instead of hand-written `app:get(...)` calls
per page.

There is no client-side Lua VM in this template, so this is still
full-page navigation (`<a href="/about">`), not client-side routing --
`views/Site.lua` buys a single source of truth for the route table, not an
SPA. Add a new page by adding a `r.node({...})` to `views/Site.lua` and a
matching `views/<Name>.luax`.
]]

  return files
end

return M
