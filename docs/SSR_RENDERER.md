# Plain rendering and site integrations

For rendering that does not need Meteorite or Vite, import the renderer directly:

```lua
local h = require("hydronium.core.element").h
local renderer = require("hydronium_dom.server.renderer")
local html = renderer.render_to_string(h("h1", {}, "Hello"))
```

This entrypoint has no Meteorite adapter, build-mode global, filesystem manifest
loader, or Vite configuration dependency. It retains component rendering,
contexts, Suspense, client plans, islands, streaming, and page-wide island IDs.
Function sinks receive `chunk`; table sinks implement `sink:write(chunk)` and
optional `:flush()` / `:close()` methods.

JavaScript island module URLs pass through unchanged by default. An embedding
can resolve them for one render without mutating global configuration:

```lua
local html, plan = renderer.render_to_string(vnode, {
  module_resolver = function(specifier)
    return manifest[specifier] or specifier
  end,
})
```

The resolver applies only to string-valued JavaScript module specifiers. Lua
module IDs never reach it, and the next render gets no resolver unless it is
explicitly supplied again. Plain rendering never reads `manifest` itself.

## Existing site entrypoint

`require("hydronium_dom.server")` remains the site-facing entrypoint. It wires
JavaScript module resolution to the existing
`hydronium_dom.server.vite_module` configuration and retains the lazy
`.meteorite` convenience API. Direct imports of
`hydronium_dom.server.meteorite` also remain available. Existing callers do not
need to migrate unless they want the smaller renderer dependency closure.

The site entrypoint passes its resolver through render options, including
streaming and `render_page` callbacks. It does not reconfigure the plain
renderer or mutate a caller's options. Both entrypoints share the renderer's
existing synchronous, non-reentrant render/page state contract.

## Optimization status

The Quaver fixture uses the complete supplied source inventory and ordinary
module files. Selecting the plain-renderer API reduces observed loaded framework
modules to 23, with 73,236 compacted Lua-source bytes including the page, or
72,118 bytes with independently mangled JSON/style helpers. These are fixture
source totals, not a deployed binary size or browser transfer claim.

Strict dependency discovery now reaches the renderer without entering Meteorite
or filesystem assets. Export verification stops at HTML's SVG lookup tables,
which are populated by module-initialization loops (`QV104`). Those loops do not
by themselves imply bad architecture, but Quaver cannot yet prove their export
stability. No purity flag or reflection exception bypasses that proof.
