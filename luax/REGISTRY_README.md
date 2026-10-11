# Hydronium LUAX

`hydronium/luax` is the `.luax` compiler, formatter, LuaLS plugin, and editor
integration package.

```sh
moon add hydronium/luax
```

It installs the `hydronium_luax` Lua namespace. Its Neovim plugin is shipped
under `nvim/` and exposes `require("luax").setup()`.

## Load a LUAX component

In an empty directory:

```sh
moon init . --name demo --interpreter luajit@2.1
moon add hydronium/luax hydronium/dom
```

Save Card.luax:

```luax
local H = require("hydronium")
local d = require("hydronium_dom").d
return function(props)
  return <d.article><d.h1>{props.title}</d.h1></d.article>
end
```

Save demo.lua:

```lua
local H = require("hydronium")
local server = require("hydronium_dom.server")
require("hydronium_luax").loader.install()
local Card = require("Card")
print((server.renderToString(H.h(Card, { title = "Hello, LUAX" }))))
```

```sh
moon exec -- luajit demo.lua
```

Expected output: <article><h1>Hello, LUAX</h1></article>. The searcher derives
.luax candidates from package.path, compiles on demand and uses ordinary
require caching. Existing Lua, preload and native loaders retain precedence.
Install once at each Lua VM entry before loading application modules; do not
repeat it inside every view. If require cannot find Card, run from its directory
or add that source root to package.path before loading it.

Generated SSR projects register the loader at server/isolated handler entries.
Browser modules arrive already compiled through the manifest. Installing the
searcher does not itself watch files or enable HMR.

## Editor integration

Add the package's types and LuaLS plugin paths to .luarc.json, or scaffold with
hydronium/create to generate that setup. The Neovim plugin is shipped under
nvim/ and exposes require("luax").setup().

## Highlight LUAX in other editors

The package ships the canonical TextMate grammars under
`.moonstone/env/libexec/hydronium/luax/syntaxes/`. Load
`luax.tmLanguage.json` into Shiki with `name: "luax"`, or use its
`source.luax` scope with Monaco's TextMate integration. This is the same grammar
used by the editor integration; it provides highlighting, not semantic Lua
completion or diagnostics. Those need LuaLS and the LUAX virtual-source plugin.

For workspace development, new source files need an environment refresh:
`moon sync --locked --offline`. Existing file links follow edits, but a new
module has no link until Moonstone rematerializes the package. Do not add those
links by hand. After packaging, run `bash tests/test_luax_artifact.sh` from the
Hydronium repository to compare the artifact's source closure and import it
without workspace fallbacks.
