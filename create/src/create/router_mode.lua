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
constraint = "^0.3.12"
role = "runtime"]=]

local ROUTER_DEP_BLOCK = [=[

[[dependencies]]
name = "hydronium/router"
constraint = "^0.2.3"
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

  -- Pages come from a route manifest instead of hand-written app:get calls.
  -- The views themselves are the base template's (src/views/*.luax).
  files["src/views/Site.lua"] = [[-- The page manifest: every page in one place, lowered to Meteorite GET
-- routes by hydronium_router.meteorite (see src/main.lua).
local r = require("hydronium_router")

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

  local handler, handler_err = insert_after(files["src/app/page_handler.lua"], "local M = {}\n", [[

-- Pages declared in src/views/Site.lua, rendered through the same Document.
function M.routed(c)
  local adapter = require("hydronium_router.meteorite")
  return adapter.handler(require("views.Site"), {
    resolve = require,
    resolve_loader = require,
    render = function(request, page, opts)
      local state = opts.state and opts.state.hydronium_router
      local path = state and state.location and state.location.pathname or "/"
      return render(request, page, { path = path, status = opts.status })
    end,
  })(c)
end
]])
  if not handler then error("create.router_mode: " .. tostring(handler_err) .. " in src/app/page_handler.lua", 2) end
  files["src/app/page_handler.lua"] = handler

  local routes = 'app:get("/", function(c) return require("app.page_handler").home(c) end)\n'
    .. 'app:get("/about", function(c) return require("app.page_handler").about(c) end)\n'
  local main = files["src/main.lua"]
  local s_at, e_at = main:find(routes, 1, true)
  if not s_at then error("create.router_mode: page routes not found in src/main.lua", 2) end
  main = main:sub(1, s_at - 1) .. [[local router = require("hydronium_router.meteorite")
local site = require("views.Site")
router.mount(app, site, {
  handler = function(c) return require("app.page_handler").routed(c) end,
})
]] .. main:sub(e_at + 1)
  main = main:gsub("\nreturn app\n$", "\nrouter.validate_final(app, site)\n\nreturn app\n")
  files["src/main.lua"] = main

  files["README.md"] = (files["README.md"] or "") .. [[

## Routing

Scaffolded with `--router hydronium`: `src/views/Site.lua` lists the pages, and
`hydronium_router.meteorite` turns them into Meteorite routes. Navigation is
still full page loads; add a page with an `r.node({...})` in `Site.lua` and a
`src/views/<Name>.luax`.
]]

  return files
end

return M
