# Hydronium

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
the counter. The [quickstart README](examples/quickstart/README.md) explains
the example and its development workflow.

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
| [`core`](core/) | `moonstone/hydronium` | Signals, scopes, components, reconciliation, and the host contract. |
| [`dom`](dom/) | `moonstone/hydronium-dom` | Browser DOM host, SSR renderer, and Meteorite integration. |
| [`luax`](luax/) | `moonstone/hydronium-luax` | LUAX compiler, formatter, Tree-sitter grammar, and editor integrations. |
| [`ink`](ink/) | `moonstone/hydronium-ink` | Terminal host with `Box`, `Text`, and `Newline` intrinsics. |
| Router | Reserved as `moonstone/hydronium-router` | Route patterns, matching, href construction, and history adapters. It joins the published workspace when its in-progress source lands. |
| [`build`](build/) | `moonstone/hydronium-ballad` | Ballad plugins for LUAX, CSS/assets, and browser bundles. |
| [`create`](create/) | `moonstone/hydronium-create` | Project generator and editor bootstrapper. |

The current packages live in Moonstone's registry namespace. A future
Hydronium organization will own the source and publish them as
`hydronium/*`; that package-name migration is planned as a breaking change.
See [the namespace plan](docs/PACKAGE_NAMESPACE.md) for the exact mapping.

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

## Development

The workspace uses Moonstone and LuaJIT. From the repository root:

```sh
moon sync
moon exec luajit tests/runner.lua
moon exec ballad play partiture.lua
```

The test suite covers the runtime, hosts, LUAX compiler and tooling. The last
command exports the registry artifacts for all packaged orbits. GitHub Actions
runs the same resolution, tests, and export path on every push and pull
request.

## Status

Hydronium is early software. The package layout and APIs are being proven by
the examples in this repository, especially Meteorite SSR and Ink. Expect
breaking changes before the first stable release.
