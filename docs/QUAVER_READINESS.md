# Quaver readiness

What stands between Hydronium and a bundler / tree-shaker / minifier such as
Quaver (`../quaver`), what this branch fixed, what remains, and what Quaver
itself would need. Status as of 2026-10-15, against Quaver's
`tree_shaker`, `ast`, `specialize`, `flavors`, `bundle` and `ballad` modules,
and the "Quaver implementation status" section of
`quaver/docs/MOONSTONE_FLAVORS.md`.

## Focused compatibility capabilities

`hydronium.compat` is now a backwards-compatible facade over
`hydronium.compat.primitives`, `.loader`, and `.diagnostics`. Framework internals
import only the capability they use. Primitives contain `unpack` and integer
conversion without `load`, environment mutation, or debug access. Compiler and
diagnostic facilities preserve their existing behavior and error messages.

The Quaver SSR experiment passes on Lua 5.4 and LuaJIT with identical rendered
HTML, JSON behavior, and style serialization. Its narrow-import compacted source
measurement drops from 81,947 to 80,795 bytes after the capability split and
removal of legacy sink inference; with independently mangled JSON and style
helpers it drops from 80,829 to 79,677 bytes. These are observed loaded
Lua-source bytes for the fixture, not browser or native-server sizes. The
complete source inventory remains emitted.

The primitive module independently passes Strict mangling (623 to 261 bytes).
Development warning emission now has no diagnostics dependency. Optional
`hydronium.core.dev_diagnostics.install()` supplies source locations only to a
development entrypoint; normal warnings still report component names and causes.
SSR sinks also use their explicit protocol without debug introspection.

With Quaver's member-name scanner fix, narrow SSR now reaches the lazy Meteorite
adapter before Strict analysis stops: that adapter reads `_G` for the build mode.
The root facade still reaches the dynamic compilation capability via HMR/forms.
Neither boundary is waived or called pure.

The historical measurements below describe the earlier consolidation into one
compat module; its reflection-owner entry is now the two explicit capabilities.

## How this was measured

- **Browser closure**: `hydronium_dom.dev.client_manifest.build` seeded with
  `hydronium`, `hydronium_router`, `hydronium_query`, `hydronium_virtual` and
  `hydronium_table`, minus the four modules Hydronium's own bundle stubs
  (`hydronium_ballad.BROWSER_STUBS`). That is 65 modules. This is the code a
  browser bundle ships, so it is where shaking and minifying pay off.
- **Quaver's rules**: the same token checks as `quaver.tree_shaker`. A
  reachable module may not name `_G`, `_ENV`, `debug`, `load`, `loadstring`,
  `loadfile`, `dofile`, `getfenv` or `setfenv`, and every `require` must take
  one string literal.
- **Parsing**: `quaver.ast.parse` over every `*/src/**/*.lua` file, 189 files
  at the 5.4 grammar and 187 at LuaJIT/5.1 (the `@lua54` files excluded).
  There were 0 failures.
- **Module-top effects**: top-level call statements, global writes and
  control flow, from Quaver's AST. In the browser closure they only touch
  module-local tables (`setmetatable(M, …)`, loops filling `d`), apart from
  compat's flavor `if`, which Quaver folds.

| browser closure, Quaver token rules | before | after |
|---|---|---|
| modules naming `load`/`loadstring`/`setfenv`/`debug` | 4 (component, dev, form, hmr) | 1 (`hydronium.compat`; its `@lua54` file names only `load` and `debug`) |
| modules naming `_G` | 8 | 1 (`module_graph`, HMR; the bridge reads became host capabilities) |
| non-literal `require` | 1 (`module_graph`, HMR) | 1 (same, audited) |

`tests/build/quaver_readiness_spec.lua` keeps the reflective-name and
literal-require columns from regressing.

### Every `dom` and `ink` module

The browser closure doesn't reach the server half of `dom` or any of `ink`,
so the same spec also scans every module of those two packages (44 modules;
all parse at both the LuaJIT and 5.4 grammars). The exceptions it accepts are
listed in the spec with their reasons, and an exception that stops occurring
fails the test, so the list below stays current:

| module | uses | why it stays |
|---|---|---|
| `hydronium_dom.assets`, `.server.client_boot`, `.server.meteorite_routes`, `.dev.source_registry` | `loadfile` | reads a generated manifest at runtime on the server: data, not code; a bundler treats it as an external file |
| `hydronium_dom.server.island` | non-literal `require` | island ids are dynamic entry points (Q5) |
| `hydronium_dom.server.meteorite` | `rawget(_G, …)` | read-only `METEORITE_BUILD_MODE` (Q3) |
| `hydronium_dom.dev.watch` | `_G` | dev-only sleep hook from Meteorite |
| `hydronium_ink.yoga_ffi` | `debug` | third and last attempt to load Yoga, after the OS loader and `MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK`: a library beside its own source, for running from a checkout. In a bundle it fails harmlessly; a bundled ink app needs the library on the loader path or that variable set |

The DOM host and the virtual host no longer read globals at all: the
`__dom_*` bridge globals were removed outright (see
`docs/HOST_CAPABILITIES.md`). `ffi` is accepted only in `ink` (LuaJIT-only by design); `dom` must stay
portable. `pcall(require, "literal")` counts as a static, optional
dependency (Q2). `hydronium_dom.server.sink` used to call `debug.getinfo`
to count a write function's parameters. That legacy inference has been removed: table sinks must implement `sink:write(chunk)`, while standalone
function sinks receive the chunk directly.

`d.<tag>` element descriptors are created on demand from the tag name by one
module (`hydronium_dom.dom`), which also prebuilds the standard tags when it
loads. There is nothing per element to shake: a bundle carries that one
module whatever tags it uses.

## Fixed on this branch

- **Dialect checks consolidated** (`a76be72`): `hydronium.compat` and
  `hydronium_luax.compat` own `unpack`, text-only `load` with an environment,
  `tointeger`, `utf8_char` and `function_location`. 19 core modules, the CLI,
  the LUAX lexer, markdown parser and loader, DOM CSS scoping and the DOM Lab
  route through them. The fallbacks fold to one branch per flavor with
  Quaver's current `specialize` (`assume_runtime_globals = true`, checked for
  `luajit-*`, `lua51-*` and `lua54-*`). See `docs/LUA_FLAVORS.md` for the
  variant policy.
- **Forms bridge sandbox**: `literal()` used `setfenv` when present. On 5.2+,
  including the browser, payloads ran against `_G`. They now run in `{}`
  everywhere through `compat.load`.
- **Dead `debug.getinfo(fn, "n")`** in `component.lua` was removed. It never
  yields a name for a function value. `dev.lua`'s definition-site lookup moved
  to `compat.function_location`.
- **Hidden global edge** (`ac6514b`): compiled LUAX spreads called a
  `__luax` global that only exists once `hydronium_luax.runtime` has been
  required, which a browser VM never does. Client components with
  `{...props}` failed at runtime, and no bundler could see the dependency. The
  hydronium target now emits `(H.spread or __luax.spread)(…)`, and core
  exports `spread`. That also fixed the pragma form
  `X.spread or __luax.spread(…)`, which returned the function instead of
  calling it.
- **False positives removed** (`f27114b`): locals named `load` in
  `hydronium_table.remote` and `require_scan` were renamed.
- **Self-location**: `hydronium_meteorite.lab_host` prefers
  `MOONSTONE_PACKAGE_ROOT_HYDRONIUM_METEORITE`. The `debug.getinfo` fallback is
  now lazy instead of running at module top.
- **Dynamic entry points marked** in code: `hydronium_dom.server.island`
  (`require(module_id)`; ids come from `hydronium.sources.lua` `islands`,
  which the client bundle walks as entries; server-side only), the Lab-CLI
  host adapter (`pcall(require, descriptor.module)`), and the Lab
  `config.document` override. The last two are development tools.
- **Flavor-aware browser collection**: `plugins.client.resolve`,
  `client_manifest` and `dom_lab` pick `@lua54` variants and drop the others
  (`hydronium.core.flavor_files`).

## Remaining in Hydronium (deliberately left)

- ~~`_G.<name>` bridge reads~~ **Done.** Every host bridge (router
  history, hash history and HTTP, forms, dev warnings, router page state)
  is now a `hydronium.runtime.hosts` capability and the globals are gone
  (`docs/HOST_CAPABILITIES.md`). The readiness spec now fails if any browser
  module names `_G`/`_ENV`, apart from `module_graph` below.
- **`hydronium.core.module_graph`** wraps `_G.require` to observe module
  instantiation for HMR. It is dev-only, and in a Quaver bundle it would
  observe nothing, because the bundle's private `require` is a local.
  Production bundles don't need it.
- **Optional requires** `pcall(require, "<literal>")`: `hydronium_luax.runtime`
  (`hydronium`, which ships in the Ink Lab bundle), `hydronium_ink.render` and
  `cli/dev_log` (`hydronium_ink.clock`), `lab-cli` (`lfs`), and
  `hydronium_ballad.plugins.lab`. They are optional by design. See request Q2.
- **Self-locating tool code**: `hydronium_luax.plugin` and `luals/init.lua`
  (run by LuaLS from a path, never bundled), `cli/main.lua` (an executable
  entry), and `hydronium_ink.yoga_ffi` (tries `ffi.load` and
  `MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK` first, then `debug.getinfo`).
- **Runtime `.luax` loading in Lab packages**: `hydronium_lab.components`,
  `.controls` and `.workbench`, and `hydronium_ink_lab.components`, find a
  sibling `.luax` via `package.searchpath` and compile it at require time.
  They are development tools. Bundling them would need precompiled output.
- **Eager barrels**: `hydronium/init.lua` and `hydronium/core/init.lua` are
  `local x = require(...)` plus a `return { k = x.f, … }` table. Quaver's
  facade grammar (`local v = {}; v.k = require(...)…; return v`) does not
  accept that shape, so Quaver cannot drop unused barrel exports. Changing the
  public barrels would be API churn, so see request Q4. Apps that require
  `hydronium.signals`, `hydronium_router.*` and similar directly already shake
  at module level.

## `.luax`, `.md`, `.mdx` and `hydronium_luax.loader`

`loader.install()` adds a package searcher that compiles `.luax`, `.md` and
`.mdx` at `require` time. A bundler must never see those sources. It must take
compiled Lua:

- **Browser**: `hydronium_ballad.plugins.luax.compile` emits `hy_module`
  assets. Each has a `.lua` `virtual_path`, compiled `content`,
  `metadata.hydronium.module_id` (the topology's logical id, for example
  `ui.Button` for `src/components/Button.luax`, which need not equal the path),
  `target` (client/server/shared) and a Source Map v3 in
  `metadata.hydronium.sourcemap`.
- **Server**: `hydronium_ballad.server_modules` writes compiled modules to
  `.hydronium/server/`.
- Compiled LUAX is line-aligned with its source, and `require`s it adds are
  literal: `hydronium`, `hydronium_dom`, and for `.md`/`.mdx` `hydronium`.
  After `ac6514b` it needs no hidden global in the hydronium target. The
  `universal`/`direct` targets still reference `__luax.*` by design (they are
  runtime-agnostic, and the host supplies `__luax`).
- A `.md`/`.mdx` module returns a callable table `{ meta, toc }` with
  `__call`. Shaking must keep it whole.
- Flavor variants also apply to compiled files: `Foo@lua54.luax` compiles to
  module id `Foo@lua54`. `plugins.client.resolve` folds it into `Foo` for the
  browser. Quaver's variant selection must run on these compiled ids or paths
  too.

## Requests for Quaver

These are aligned with what Quaver already implements: variant selection via
`moonstone.variants`, AST-based `moonstone.target` folding, `_VERSION`/`jit`
folding with `assume_runtime_globals`, a private module registry, and
`externals`.

- **Q1. Explicit runtime boundaries.** Compilation and debug introspection live
  in `hydronium.compat.loader` and `.diagnostics`; HMR instrumentation stays in
  `hydronium.core.module_graph`. Preserve these capabilities under their runtime
  contracts. An allowlist must not become evidence of purity or authorize
  deleting their effects. Separately owned static regions can be optimized;
  arbitrary shared-graph partitioning still needs proof.
- **Q2. Optional edges.** Treat `pcall(require, "<literal>")` as an optional
  dependency: include it if resolvable, otherwise make it an external that
  fails at runtime as before. It is currently "dynamic/aliased require".
- **Q3. `_G.<literal>` reads and `rawget(_G, "<literal>")`** should be
  accepted as global reads. They don't defeat renaming, because Quaver
  renames neither globals nor fields. Keep rejecting `_G` as a value,
  `_G[expr]` and writes.
- **Q4. Table-constructor barrels.** Accept
  `local a = require("x") … return { k = a.f, k2 = a, … }` as a facade when
  the profile says `pure = true`. Hydronium's `hydronium` and
  `hydronium.core` barrels are this shape, and `hydronium.test`,
  `love_hmr`, `source_topology` and `source_inventory` are what they pull in
  eagerly.
- **Q5. Honor `metadata.hydronium.module_id`** (or a generic
  `metadata.module_id`) in the Ballad adapter. It currently derives ids from
  `virtual_path` minus `roots`, which differs from Hydronium's topology ids.
- **Q6. Chunk names and source maps.** `bundle` wraps each module in
  `function(...)` inside one chunk, so error positions and `debug` sources
  name the bundle. Hydronium's error overlay resolves frames through
  per-module chunk names (`@module_id`) and the LUAX source maps. Please offer
  a per-module `load(source, "@id")` form, which Hydronium's own
  `package_preload_v1` bundle uses, or compose source maps through
  minification.
- **Q7. Variant selection on compiled assets** (see above), and selection for
  `@lua54` when the target is a browser engine. The browser flavor has no
  os/arch, so a target like `lua54-wasm32-browser` or an explicit "language
  only" flavor would help. `moonstone.variants` has no `wasm32`/browser tags
  today.
- **Q8. Fold-friendly fallback confirmed.** Nothing is needed here. With
  `assume_runtime_globals = true`, both compat fallbacks already reduce to one
  branch per target with the current `specialize`. Please keep `_VERSION`
  equality, `jit ~= nil` and nested `if` arms in the supported fold set.

## Requests for Moonstone (blocking variants in published packages)

- **M1.** `moon artifact create` rejects `@` in artifact paths
  (`canonical_artifact.zig`, `isPortableNameByte`), on 0.5.11 and on
  `feat/lua-flavors`. A package with variant files therefore cannot be
  published. Hydronium excludes `*@*` from its core and luax artifacts until
  this is fixed.
- **M2.** Keep non-selected variants reachable for cross-flavor consumers:
  the browser bundler, LuaLS, and Quaver building for a non-host
  `MOONSTONE_TARGET`. Today `resolveModuleVariants` deletes them from the
  env, so a dependency's other flavors are only in the store (reachable via
  `MOONSTONE_PACKAGE_ROOT_*` under `moon exec`). Without this, Quaver cannot
  select a dependency's variant for a non-host flavor, and Hydronium cannot
  ship `@luajit`/`@lua51` variants safely.
