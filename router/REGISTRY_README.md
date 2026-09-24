# hydronium-router

Host-neutral routing for Hydronium. One serializable route tree drives DOM,
Ink, memory-history tests, and Meteorite SSR.

## Install

```sh
moon add hydronium/router
```

## Define a site

```lua
local r = require("hydronium_router")

return r.createSite({
  root = r.node({
    id = "root",
    path = "/",
    screen = "views.App",
    error = "views.RootError",
    children = {
      r.node({ id = "home", path = "", screen = "views.Home", prerender = true }),
      r.node({
        id = "package",
        path = "packages/:namespace/:package",
        screen = "views.Package",
        pending = "views.PackagePending",
        error = "views.PackageError",
        load = "loaders.package",
        actions = {
          star = {
            ref = "actions.star",
            path = "/actions/packages/:namespace/:package/star",
          },
        },
        children = {
          r.node({ id = "package.readme", path = "", screen = "views.Readme" }),
          r.node({ id = "package.manifest", path = "manifest", screen = "views.Manifest" }),
        },
      }),
    },
  }),
})
```

The root path is `/`. Child paths are relative. `path = ""` declares an
index route, while an omitted path declares a pathless layout. Catch-alls must
be terminal. Only leaves become addressable GET endpoints.

`prerender = true` opts a literal, loader-free leaf into static HTML output.
`site:prerender_paths()` returns those paths in stable order for build tools.
Parameterized routes, including the package route above, and any route with
an ancestor loader cannot be marked for prerendering. Unmarked routes stay out
of static search and offline precaches by default.

Screens, loaders, actions, pending UI, and error boundaries are logical module
IDs. The tree contains no component closures or host services, so build tools
can inspect it without running application code.

A screen may also be a target map, such as
`screen = { dom = "views.dom.Package", ink = "views.ink.Package" }`. Pass
`target = "dom"` or `target = "ink"` to `site:createRouter`. This keeps route
identity and data loading shared while each renderer owns its leaf UI.

## Load data

A loader receives the matched node, location, params, search values, request,
services, and its transition ID.

```lua
-- loaders/package.lua
local r = require("hydronium_router")

return function(ctx, done)
  local path = "/api/hydronium/v1/packages/" .. ctx.params.namespace .. "/" .. ctx.params.package
  return r.http.get(ctx, "registry", path, function(response, err)
    if err then return done(nil, err) end
    if response.status == 404 then return done(r.routeError(404, "package not found")) end
    if response.status ~= 200 then return done(r.routeError(502, "registry unavailable")) end
    done(response.body.data)
  end)
end
```

Parent loaders run before children. A child can read an earlier result with
`ctx.parent("parent.route.id")`. Navigation has a monotonically increasing
transition ID; late callbacks from an older transition cannot overwrite the
current route.

`r.http.get` uses the named Meteorite HTTP capability during SSR and an
abortable browser fetch on client navigation. Install the browser half with
`createHttpGlobals({ request })` from `hydronium-router/client/http.js` in
`mount({ luaGlobals })`. A newer navigation aborts the previous fetch. A
`request` should be `createBrowserRequest()` from Hydronium DOM; forms use the
same primitive. A loader that returns a value directly remains synchronous;
custom transports can instead use `ctx.services` and return a cancellation
function.

```lua
local H = require("hydronium")

return function()
  -- Hooks belong to component setup, not the returned render function.
  local data = r.useRouteData("package")

  return function()
    if data:pending() then return H.h("p", nil, "Loading") end
    if data:error() then return H.h("p", nil, "Could not load package") end
    return H.h("h1", nil, data:value().coordinate)
  end
end
```

Use `r.redirect("/signin")` in a loader for navigation and
`r.routeError(status, message, data)` for a route error. `pending` and `error`
screens resolve at the nearest node that declares them.

## Render nested routes

Layouts receive their child as `props.outlet`. They may also render
`r.Outlet` directly.

```lua
local H = require("hydronium")

return function(props)
  return H.h("main", nil,
    H.h("nav", nil, "Registry"),
    props.outlet
  )
end
```

The default scope identity remounts a node when one of its own path params
changes. Set `reuse = "keep"` only when the component deliberately owns state
across those param changes.

## Create a router

```lua
local router = site:createRouter({
  history = r.createBrowserHistory(),
  resolve = function(module_id) return require(module_id) end,
  resolve_loader = function(module_id) return require(module_id) end,
  services = { registry = registry_client },
})

return H.h(router.Provider, nil, H.h(r.Outlet))
```

For tests, Ink, and other hosts, use `createMemoryHistory({ initial = "/" })`.
A custom history implements `current`, `push`, `replace`, `go`, `back`,
`forward`, `can_go_back`, `can_go_forward`, and `dispose`.

| API | Value |
| --- | --- |
| `useRouter()` | Current router |
| `useLocation()` | Reactive location |
| `useMatch()` | Matched leaf |
| `useMatches()` | Root-to-leaf node chain |
| `useParams()` | Stable reactive param proxy |
| `useSearchParams()` | Stable reactive query proxy |
| `useNavigate()` | `navigate(to, { replace?, state? })` |
| `useHref(id, params, query)` | URL for a route ID |
| `useRouteData(id)` | Loader resource |
| `useNavigation()` | Current transition state and target |
| `useRevalidator()` | Function that reruns the active loader chain |

A route resource exposes `status()`, `pending()`, `ready()`, `error()`, and
`value()`.

## Mount on Meteorite

The adapter emits explicit GET and mutation routes. API routes and assets stay
ordinary Meteorite declarations.

```lua
local adapter = require("hydronium_router.meteorite")

adapter.mount(app, site, {
  handler = meteorite.lua("app.page_handler", { arg_mode = "lazy_context" }),
  action_handler = meteorite.lua("app.action_handler", { arg_mode = "lazy_context" }),
})

adapter.validate_final(app, site)
```

The page module uses `adapter.handler(site, opts)`. Supply `resolve`,
`resolve_loader`, and the DOM server renderer. `opts.services(c)` can expose
declared Meteorite capabilities to loaders. SSR state uses the versioned
`hydronium_router` envelope and contains the canonical URL, matched route
chain, params, and loader results.

The action module uses `adapter.action_handler(site, opts)` and resolves action
modules by `ref`. An action receives `{ request, action, values, params,
services }`, then returns `hydronium.action_ok(...)` or
`hydronium.action_fail(...)`. Enhanced submissions receive JSON. A native HTML
submission must return a redirect or use `opts.progressive` to render HTML.

## Lower-level API

Most applications only need `node`, `createSite`, a history adapter, `Outlet`,
and the hooks. The package also exports:

- Pattern and URL functions: `parse_pattern`, `more_specific`, `encode`,
  `decode`, `split`, `parse_query`, `build_query`, `normalize_path`.
- Matching and links: `createMatcher`, `href`.
- Host integration: `createRouter`, `validate_history`, `to_location`,
  `RouterContext`, and `RouteContext`.
- Result constructors: `redirect` and `routeError`.

Snake-case aliases remain for Lua codebases that use that convention.
