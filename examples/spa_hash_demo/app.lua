-- Real two-route static SPA entry for docs/HYDRONIUM_SPA_MODE_PLAN.md's
-- M3 gate: hash-routed, mounted with hydrate = false, served by a dumb
-- static file server with no Meteorite process at all. Compiled and
-- bundled by hydronium-ballad's real client plugin (see ../partiture.lua)
-- into one package_preload_v1 chunk under dist/client/, fetched and
-- mounted client-side by mount.js.
--
-- Hand-written plain Lua (no .luax compile step needed for two static
-- screens) -- same pattern as
-- examples/meteorite_ssr/hydrate_demo/app.lua: `d.<tag>(...)` intrinsics
-- from hydronium_dom, `H.h(Component, props, children)` from the
-- "hydronium" barrel for composing non-intrinsic components.
--
-- Routes are built through `hydronium_router.site` (R.node/R.createSite),
-- NOT by hand-assembling a bare `routes = {{id=,path=,component=},...}`
-- table for `create_router` -- found live, the hard way: every existing
-- router spec (tests/router/router_spec.lua) goes through `site()` too,
-- and for a real reason, not just convention. `site:routes(resolve)`
-- resolves each matched route into a `meta.chain` array whose entries
-- carry `.component` at their OWN top level (site.lua's `Site:routes`);
-- `Outlet` reads `node.component` off exactly that per-depth chain entry
-- (`router.route_at(depth)`). A hand-rolled flat `routes` table with no
-- `meta.chain` falls through `router.lua`'s `match_chain` to
-- `{ match_result.route }` instead -- the MATCHER's own internal record,
-- whose `.component` lives one level down at `.meta.component`, not at
-- the top level `Outlet` reads. The symptom was not a thrown error: the
-- router matched correctly (`router.match().id == "home"`) and the
-- Outlet's OWN `H.useContext` found the Provider fine, but
-- `router.route_at(1).component` was silently nil, so `Outlet` took its
-- documented no-`notFound` fallback path and rendered nothing, with the
-- rest of the tree (both screens) never even instantiated.
local H = require("hydronium")
local dom = require("hydronium_dom")
local d = dom.d
local R = require("hydronium_router")
local hash_history = require("hydronium_router.history.hash")
-- M4: the same stylesheet the build scopes. css.sheet indexes to the scoped
-- class name at runtime; plugins.style rewrites the selector at build time.
-- The browser gate proves they agree by checking the rule actually applies.
local styles = require("hydronium_dom.css").sheet("app.css")
-- M4: the OTHER half. Unlike css.sheet (a pure function -- the scoped name is
-- derivable), a content hash is not computable without the file's bytes, so
-- this needs the build's real manifest. mount()'s `assetManifestUrl` is what
-- gets it into the VM; without that, url() returns its documented dev
-- fallback ("/logo.svg"), which in a static SPA is a 404 and nothing else.
local assets = require("hydronium_dom.assets")

-- A plain `<button>`, not an `<a href>` -- deliberately: dom_bridge.js's
-- set_listener documents that "wasmoon cannot safely marshal a browser
-- Event as a Lua callback argument" (onClick fires with NO arguments
-- unless a payload factory is registered for that event name, which
-- "click" has none of), so there is nothing here to call
-- event:preventDefault() on. A real `<a href="#/...">` would need that
-- (its own default action would ALSO change location.hash, racing the
-- router's own history.push), which is exactly the failure mode a plain
-- button with no default navigation action sidesteps entirely -- the
-- same proven pattern examples/meteorite_ssr/hydrate_demo/app.lua
-- already uses for its own onClick.
local function nav_button(id, label, navigate, to)
  return d.button({
    id = id,
    onClick = function() navigate(to) end,
  }, label)
end

-- Pass-through root layout: the two leaf screens are siblings under one
-- pathless root node, matching the shape every real router spec uses
-- (tests/router/router_spec.lua's own `Root = function(props) return
-- props.outlet end`).
local function RootLayout(props)
  return function(current_props)
    current_props = current_props or props
    return current_props.outlet
  end
end

local function HomeScreen()
  local navigate = R.use_navigate()
  return function()
    return d.div({ id = "home-screen", class = styles.card },
      d.img({ id = "logo", src = assets.url("logo.svg"), alt = "Hydronium" }),
      d.h1({}, "Home"),
      d.p({ id = "home-marker" }, "This is the home route."),
      nav_button("go-second", "Go to Second", navigate, "/second")
    )
  end
end

local function SecondScreen()
  local navigate = R.use_navigate()
  return function()
    return d.div({ id = "second-screen" },
      d.h1({}, "Second"),
      d.p({ id = "second-marker" }, "This is the second route."),
      nav_button("go-home", "Go Home", navigate, "/")
    )
  end
end

local components = { Root = RootLayout, Home = HomeScreen, Second = SecondScreen }

local site = R.createSite({
  root = R.node({
    id = "root",
    path = "/",
    screen = "Root",
    children = {
      { id = "home", path = "", screen = "Home" },
      { id = "second", path = "second", screen = "Second" },
    },
  }),
})

return function(props)
  local router = site:create_router({
    history = hash_history.create_hash_history(),
    resolve = function(id) return components[id] end,
  })

  return function()
    return H.h(router.Provider, {}, H.h(R.Outlet, {}))
  end
end
