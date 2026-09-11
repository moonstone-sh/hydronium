# Hydronium Router

`moonstone/hydronium-router` provides host-neutral reactive routing: route
declarations, matching, typed href construction, memory/browser histories,
an Outlet, and context hooks.

```sh
moon add moonstone/hydronium-router
```

```lua
local router = require("hydronium_router")

local h = require("hydronium")
local r = require("hydronium_router")

local function UserPage()
  local params = r.useParams()
  return function()
    return h.h("p", nil, "User " .. params.id)
  end
end

local app_router = r.createRouter({
  history = r.createMemoryHistory({ initial = "/users/42" }),
  routes = {
    r.route("home", "/", function() return h.h("p", nil, "Home") end),
    r.route("users.show", "/users/:id", UserPage),
  },
})

assert(app_router.href("users.show", { id = 7 }) == "/users/7")

local app = h.h(app_router.Provider, nil,
  h.h(r.Outlet, { notFound = function() return h.h("p", nil, "Not found") end })
)
```

`useParams()` and `useSearchParams()` return stable reactive proxies. Read
fields directly; LuaJIT cannot implement `__pairs`, so use
`app_router.params_snapshot()` or `search_snapshot()` when iteration is
required. The default route reuse policy keeps the page mounted across param
changes. Set `reuse = "remount"` on a route when parameter changes must reset
its component scope.

In a browser, install the supplied bridge before the app module is required:

```js
import { mount } from "/hydronium/mount.js";
import { createHistoryGlobals } from "/hydronium-router/history.js";

await mount({
  // normal chunk or unbundled source options...
  appModuleId: "app",
  container: "#app",
  hmr: true,
  luaGlobals: createHistoryGlobals(),
});
```

Then use `createBrowserHistory()` with no arguments in Lua. Page component
modules participate in the same component-family HMR as any other Hydronium
component: editing a matched page preserves compatible state; the Router and
History objects remain alive.

## API

| Area | API |
| --- | --- |
| Declarations | `route`, `createRouter` / `create_router` |
| Rendering | `RouterContext`, `router.Provider`, `Outlet` |
| Hooks | `useRouter`, `useLocation`, `useMatch`, `useParams`, `useSearchParams`, `useNavigate`, `useHref` (snake-case aliases included) |
| Navigation | `router.navigate`, `router.href`, `router.location`, `router.match` |
| Histories | `createMemoryHistory`, `createBrowserHistory` |
| Primitives | `parse_pattern`, `createMatcher`, URL encode/decode/query helpers, standalone `href` |

The package installs `hydronium_router` and resolves `hydronium`
automatically. The browser bridge is `client/history.js`.
