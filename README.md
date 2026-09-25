# Hydronium

For async ownership—local `Resource`, route loader, optional client query
cache, forms, and abortable browser fetch—see [docs/ASYNC_DATA.md](docs/ASYNC_DATA.md).

Hydronium is a reactive UI framework for Lua and LuaJIT. It aims to make the
same component model work across browser DOM, server rendering, terminal UIs,
and future hosts, without giving up Lua's small, direct programming model.

Components describe a tree. Signals track the state that tree reads. A host
turns the resulting updates into DOM nodes, terminal cells, or another target.
LUAX adds tag syntax where it helps, but ordinary Lua remains the runtime
language.

This repository is the Hydronium monorepo. It is Apache-2.0 licensed.

## Try it

The quickest proof is the browser example. It server-renders a page, runs Lua
in the browser, and preserves component state while you edit a LUAX component.

```sh
cd examples/quickstart
moon sync
moon run dev
```

Open `http://localhost:8080/`, click the counter a few times, then edit
`views/Counter.luax`. The next interaction uses the new code without resetting
the counter. `views/App.luax` and CSS update in place; only the stable
`views/Document.luax` bootstrap boundary reloads the page. The
[quickstart README](examples/quickstart/README.md) explains the example and
its development workflow.

For a terminal host, see [Ink](ink/REGISTRY_README.md). To create a fresh
project, use the generator while working in this checkout:

```sh
cd create
moon sync
moon run dev ssr my-app
```

## Packages

| Directory | Registry package | Purpose |
| --- | --- | --- |
| [`core`](core/) | `hydronium/core` | Signals, scopes, components, reconciliation, and the host contract. |
| [`dom`](dom/) | `hydronium/dom` | Browser DOM host, SSR renderer, and Meteorite integration. |
| [`luax`](luax/) | `hydronium/luax` | LUAX compiler, formatter, Tree-sitter grammar, and editor integrations. |
| [`ink`](ink/) | `hydronium/ink` | Terminal host with `Box`, `Text`, and `Newline` intrinsics. |
| [`lab`](lab/) | `hydronium/lab` | Portable component stories and explicit registries. |
| [`lab-cli`](lab-cli/) | `hydronium/lab-cli` | Optional standalone Lab setup, discovery, and launch tool. |
| [`ink-lab`](ink-lab/) | `hydronium/ink-lab` | Resizable browser workbench for canonical Ink cell frames. |
| [`router`](router/) | `hydronium/router` | Reactive Router/Outlet/hooks, typed hrefs, route matching, and memory/browser histories. |
| [`query`](query/) | `hydronium/query` | Optional browser-side cache for shared server data. |
| [`virtual`](virtual/) | `hydronium/virtual` | Host-neutral virtual-list range and measurement state. |
| [`table`](table/) | `hydronium/table` | Headless reactive table state: rows, sorting, filtering, pagination, and selection. |
| [`build`](build/) | `hydronium/ballad` | Ballad plugins for LUAX, CSS/assets, and browser bundles. |
| [`create`](create/) | `hydronium/create` | Project generator and editor bootstrapper. |
| [`cli`](cli/) | `hydronium/cli` | Developer CLI: `hydronium dev` wraps a Meteorite dev server with a live status view. |

The packages publish under the Hydronium organization's own `hydronium/*`
registry namespace. See [the namespace plan](docs/PACKAGE_NAMESPACE.md) for
the migration history from the earlier `moonstone/hydronium-*` names.

Browser and Ink applications share the host-neutral
`hydronium.core.hmr` replacement primitive. Browser transports fetch changed
modules; the generated Ink starter polls its LUAX source from the renderer's
event loop. Both refresh component families inside the existing Lua VM.
Minimal projects render once and exit, so there is no live process or state to
hot-reload.

## Routing and mutations

`hydronium-router` keeps one serializable route tree for the browser and
Meteorite. Nodes name screens, loaders, actions, pending UI, and error
boundaries without importing host code. The browser resolves those logical
names into components, while `hydronium_router.meteorite` lowers addressable
leaves into explicit server routes. Backend APIs and assets remain ordinary
Meteorite routes.

```lua
local r = require("hydronium_router")

local site = r.createSite({
  root = r.node({
    id = "root",
    path = "/",
    screen = "views.App",
    children = {
      r.node({ id = "home", path = "", screen = "views.Home" }),
      r.node({
        id = "user",
        path = "users/:id",
        screen = "views.User",
        load = "loaders.user",
      }),
    },
  }),
})
```

Mutations use host-neutral action descriptors and scoped form state:

```lua
local H = require("hydronium")

local contact = H.action({
  id = "contact.submit",
  path = "/actions/contact",
  schema = contact_schema,
})

local form = H.useForm(contact)
-- form.props: method, action, enctype, onSubmit
-- form:pending(), form:error("name"), form:data(), form:reset()
```

The generated SSR app composes browser history, abortable loader GETs, and
form transport through `mount({ luaGlobals = ... })`. `r.http.get` uses a named
Meteorite HTTP capability on the server and the browser fetch bridge after
hydration. Forms remain usable as native HTML POSTs before hydration or when
JavaScript is disabled.

### Typed Meteorite DTOs

Meteorite owns browser API clients; Hydronium does not mirror route or database
types. Generate both projections from the Meteorite application graph:

```sh
meteorite client typescript src/main.lua js/src/generated/meteorite-client.ts
meteorite client luacats src/main.lua types/meteorite-client.d.lua
```

A JavaScript island imports the generated `createClient` and receives typed
request/response values. Add `types/meteorite-client.d.lua` to the LuaLS
`workspace.library` for the Hydronium project; then a `.luax` loader or
component can annotate the decoded value without loading TypeScript or a
database driver at runtime:

```lua
---@type CreateTodoResponse
local todo = response.body
```

Both files are generated from the same normalized Meteorite graph. Drizzle rows
remain inside the Bun service; map them to a public route response before they
cross this boundary.

## A small component

Hydronium components are Lua functions. A setup-shaped component returns a
render function, so signals and effects are owned by its scope.

```lua
local h = require("hydronium")
local d = require("hydronium_dom")

local function Counter(props, scope)
  local count, set_count = h.createSignal(0)

  return function()
    return d.button({
      onClick = function()
        set_count(count() + 1)
      end,
    }, "Count: " .. count())
  end
end
```

The equivalent LUAX is useful when the host has a natural tag vocabulary:

```luax
return <d.button onClick={increment}>Count: {count()}</d.button>
```

## Editor types and ambient DOM tags

Hydronium ships LuaCATS declarations for LUAX and DOM descriptors. Adding the
LUAX and DOM `types` directories to LuaLS gives `d.button`, event handlers,
and HTML/SVG props completion and diagnostics. DOM also has an optional
`ambient-types` directory for a DOM-only workspace that wants typed bare tags
such as `<div>` and `<button>`.

```json
{
  "runtime": {
    "version": "LuaJIT",
    "path": ["?.lua", "?/init.lua", "?.luax"],
    "plugin": [
      ".moonstone/env/share/lua/5.1/hydronium_luax/luals/init.lua"
    ]
  },
  "workspace": {
    "library": [
      ".moonstone/env/libexec/luax/types",
      ".moonstone/env/libexec/dom/types",
      ".moonstone/env/libexec/dom/ambient-types"
    ]
  },
  "files": { "associations": { "*.luax": "lua" } }
}
```

`ambient-types` is opt-in. It changes LuaLS's type environment, not Lua's
runtime globals or LUAX lowering. Use `<d.table>` and `<d.select>` even when
it is enabled because those names would collide with Lua's `table` and
`select` globals.

## Development

The workspace uses Moonstone and LuaJIT. From the repository root:

```sh
moon sync
moon exec -- luajit tests/runner.lua
moon exec -- ballad play partiture.lua
```

The test suite covers the runtime, hosts, LUAX compiler and tooling. The last
command exports the registry artifacts for all packaged orbits. GitHub Actions
runs the same resolution, tests, and export path on every push and pull
request.

## Status

Hydronium is early software. The package layout and APIs are being proven by
the examples in this repository, especially Meteorite SSR and Ink. Expect
breaking changes before the first stable release.
