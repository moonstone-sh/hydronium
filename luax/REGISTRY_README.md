# Hydronium LUAX

`hydronium/luax` is the `.luax` compiler, formatter, LuaLS plugin, and editor
integration package.

```sh
moon add hydronium/luax
```

It installs the `hydronium_luax` Lua namespace. Its Neovim plugin is shipped
under `nvim/` and exposes `require("luax").setup()`.

## Automatic require loading

Register the loader once in each server Lua VM before loading app modules:

```lua
require("hydronium_luax").loader.install()
local Card = require("components.Card")
```

The searcher derives `.luax` candidates from `package.path`, compiles them on
demand, and lets ordinary `require` cache their results. Existing Lua, preload
and native loaders retain precedence. No per-component `.lua` shim is needed.
Generated SSR projects register it at their server entry and isolated page
handler entry; browser modules arrive already compiled through the manifest.
