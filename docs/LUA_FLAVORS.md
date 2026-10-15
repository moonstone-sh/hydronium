# Lua flavors in Hydronium

Hydronium runs on LuaJIT and PUC Lua 5.1–5.4: on the server (the
environment's interpreter, usually LuaJIT), in the browser (lua-wasm and
Wasmoon, both Lua 5.4), inside LuaLS (embedded Lua 5.4, which loads
`hydronium_luax`), and in Neovim (LuaJIT, which loads `hydronium_luax` from
the package root).

## Where dialect differences live

| package | module | API |
|---|---|---|
| core | `hydronium.compat` | `unpack`, `load(source, chunkname?, env?)`, `tointeger`, `function_location` |
| luax | `hydronium_luax.compat` | `load(source, chunkname?, env?)`, `utf8_char` |

luax keeps its own module because it must not depend on core
(`tests/luax/no_core_coupling_spec.lua`). Every other package that needs a
shim depends on core and uses `hydronium.compat`. Add new dialect checks
there, not at call sites. `compat.load` compiles text only, and `env`
sandboxes the chunk on every dialect.

Each compat module has two files:

- `compat.lua`, the untagged fallback. It works on every supported Lua and
  picks a branch once, with plain `jit ~= nil` / `_VERSION == "Lua 5.x"`
  comparisons. Quaver's `specialize` (with `assume_runtime_globals`) folds
  each one to a single branch per flavor; this was checked against Quaver's
  current pass.
- `compat@lua54.lua`, a Moonstone flavor variant: the same API with the 5.4
  answers written out and no checks.

`tests/core/compat_spec.lua` loads every file the running interpreter can use
and checks it against the same expectations. Run it under both interpreters:

```sh
moon exec -- luajit tests/runner.lua tests/core/compat_spec.lua
moon exec -- lua    tests/runner.lua tests/core/compat_spec.lua   # PUC 5.4
```

## The variant policy: only `@lua54`, always with a fallback

`moon sync` (Moonstone flavors) projects one variant per module for the
**host** interpreter and deletes the others from the environment. But
Hydronium's files are also executed by other Luas out of that same
environment:

- the dev `/hydronium-src` route and `client_manifest` read core, dom and
  router through `package.path`;
- `hydronium_ballad.client_bundle` globs the framework directory on
  `package.path`;
- the DOM/Ink Lab bundle (`hydronium_meteorite.dom_lab`) ships core, dom,
  `hydronium_luax.runtime` and non-FFI ink modules;
- LuaLS loads `.moonstone/env/share/lua/5.1/hydronium_luax/luals/init.lua`.

All of those foreign hosts run Lua 5.4. A `@luajit` or `@lua51` file would be
projected on a LuaJIT host and then run on 5.4. So Hydronium ships only
`@lua54` variants, each beside an untagged fallback. Any host then gets either
the fallback, which works everywhere, or the 5.4 file, which matches the
browser and LuaLS too. `tests/core/compat_spec.lua` enforces this for every
package.

Browser collectors don't rely on the host's choice. `hydronium.core.flavor_files`
prefers `name@lua54.ext` over `name.ext` and drops every other variant. It is
used by `client_manifest`, by `plugins.client.resolve` (for framework and
project modules) and by `dom_lab`. It mirrors `moonstone.variants`' tag rules
without requiring it, so it works with older moon releases and outside
Moonstone. Hand-written browser module lists
(`examples/meteorite_ssr/client_mount_demo/client_manifest.json`,
`js/tests/canvas.browser.test.mjs`) point at `hydronium/compat@lua54.lua`.

`@luajit` / `@lua51` variants would become safe if Moonstone kept the
non-selected variants reachable, for example beside the projected file or
through `MOONSTONE_PACKAGE_ROOT_*`, so cross-flavor consumers could pick
their own. See the requests in `docs/QUAVER_READINESS.md`.

## Publishing

`moon artifact create` (0.5.11, and the `feat/lua-flavors` branch at
`ab59713`) rejects `@` in artifact paths. `isPortableNameByte` in
`src/core/archive/canonical_artifact.zig` allows only `[A-Za-z0-9._-]`. Until
that changes, `core/partiture.lua` and `luax/partiture.lua` exclude `*@*` from
both the source package and the `lua_modules` tree. Published packages carry
only the fallbacks. The workspace, live links and Hydronium's own browser
collectors still use the variants. Remove the two excludes once Moonstone
accepts variant names.

## Verified (2026-10-15)

- Installed moon (0.5.11), workspace: `luajit tests/runner.lua` 1565/1565.
  The core and luax packages build with the variants excluded.
- Flavors-branch moon, workspace copy (LuaJIT host): the env projects
  `compat.lua` as the fallback and drops the `@lua54` file. Suite 1559/1559 at
  commit `a76be72`.
- Flavors-branch moon, scratch workspace on Lua 5.4.9: `hydronium/compat.lua`
  and `hydronium_luax/compat.lua` link to their `@lua54` files, and
  `require("hydronium")` works.
- The SPA demo's client bundle contains the `@lua54` compat. The lua-wasm
  mount, events, canvas and form gates pass in Chromium, Firefox and WebKit.
