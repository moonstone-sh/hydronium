# `hydronium-ballad`: overall architecture and sequencing

**Scope:** package boundary, end-state deliverable definition, plugin/AssetSet contracts (the interface the Lua-minifier/bundle-splitter plan and the luax/CSS/assets plan must both honor), milestone sequencing, risks.
**Method:** written to this workspace's own standard (`/Users/extrordinaire/Workbench/user/CLAUDE.md`, "Trust issue in `docs/`"). Every claim below is either backed by a command actually run read-only in this working tree, or is explicitly labeled **[UNVERIFIED]**. The same rule was applied to ballad's own docs and README, not just hydronium's.
**Investigated:** 2026-09-08, against the live, uncommitted-at-the-time hydronium working tree (the ink work has since been committed, see `d093376`).
**Produced by:** an Opus 5 planning agent, as part of the "deploy a whole reactive webpage" long-horizon initiative. Companion docs: `docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md` (the `.luax` compile plugin, style normalization, static assets, export flow) and `docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md` (the `client` plugin: module resolution, amalgamation, minification, splitting).

**Corrections from the client bundler/minifier plan** (which actually ran code against real ballad/Lua-5.4 binaries where this doc only read source): (1) §3.3's `client.resolve` should be `cacheable = false`, not `true` — ballad's cache key never hashes `Asset.metadata`, and `resolve`'s join keys (`module_id`/`target`/`origin`) all live there, so a `target` flip on unchanged content would produce a silently stale cache hit; `bundle`/`minify` stay cacheable only once `resolve` also emits a `hy_module_graph` asset whose content captures the full resolution result. (2) §3.5's partiture sketch passing an array of node handles as a method's first argument (`luax.compile({ client_src, server_src }, {...})`) does not work against ballad's real `PluginProxy` argument dispatch — use `depends_on` for any multi-input method instead. (3) wasmoon is confirmed real Lua 5.4 (extracted and inspected its actual WASM binary), not LuaJIT as sometimes assumed elsewhere in this workspace — this resolves §5.2's/§6's "which dialect" open question in `client_plan`'s companion doc, not this one, but is recorded here since §0.2's table cited it as unverified. (4) the real client module count is 22, not the ~21 this doc's §2.2/§2.4 imply following `HYDRONIUM_CLIENT_MOUNT.md`'s own count. See the bundler plan's §0 verification ledger and §3/§7 for the full detail and evidence.

---

## 0. Ground truth established first (corrections to the original brief included)

**0.1 `ink` IS already a workspace member.** `hydronium/moonstone.toml` has four `[[orbits.member]]` entries — `core`, `luax`, `dom`, `ink` — and `git log` shows `d093376 feat(ink): add hydronium-ink...`. The ink packaging decision doc's sequencing was executed, not just decided. That strengthens its authority as a precedent for the decision below.

**0.2 There is already a real, working, non-stub EXTERNAL ballad plugin in this workspace — and it lives outside `ballad` itself.** `meteorite/src/ballad/init.lua` returns `{ name = "meteorite.ballad", version = "0.1.0", methods = { graph, check, zig, release } }` with real bodies emitting real `AssetSet`s and driving real `zig build`s. It is consumed as a plain dotted name:

```lua
-- meteorite/fixtures/apps/static-site/partiture.lua
local meteorite = p:use("meteorite.ballad")
local release = meteorite.release({ input = "src/main.lua", mode = "static", backend = "std_http", ... })
p.sink.directory(release, { out = "dist/release", file_graph = true, product = "release" })
```

This is the single most load-bearing finding here. **The "external ballad plugin owned by the package it builds" pattern is not speculative — it is already how the most complex build in this workspace works.** `hydronium-ballad` should be the second instance of it, not an invention.

**0.3 Other claims confirmed as stated:**

| Claim | Verified how | Result |
|---|---|---|
| `ballad.plugins.lua` is a stub | Read `ballad/src/ballad/plugins/lua.lua` — `compile`/`check` bodies are literally `error("...not yet implemented")` | **True.** Identical in the installed 0.3.7 copy |
| No amalgamation bundler exists | `find hydronium -name 'hydronium.lua'` → nothing; every `*/dist/` holds only `registry/{pkg}-0.1.0-source.tar.gz` | **True.** `docs/BUNDLING.md` is a spec; its own paths (`src/hydronium/core/...`) are pre-package-split and stale — further evidence it was never executed |
| `runtime.bundle` (ballad) already bundles Lua modules | Read it: `function runtime.bundle(...) return wrap_impl(...) end`, an alias of `runtime.wrap` | **It bundles a Lua *interpreter* into a distributable, not modules.** No module bundler exists anywhere in ballad |
| No CSS pipeline | `find hydronium -name '*.css'` → zero files. Only `dom/.../server/html.lua:serialize_style` (inline `style={...}` → CSS string) | **True** |
| No router | `grep -rniI "pushState\|popstate\|createRouter\|useRouter"` across `core/src dom/src luax/src` → empty | **True** |
| Meteorite↔hydronium is one-sided | `grep -rniI "hydronium" meteorite/ --exclude-dir=.git --exclude-dir=.moonstone \| wc -l` → **0** | **True.** `docs/METEORITE_HYDRONIUM_INTEGRATION_BRIEF.md` remains aspirational |
| Test baseline | `luajit tests/runner.lua` | 438 total, 437 passed. Sole failure: `tests/core/lazy_barrel_spec.lua` — `sh: lua: command not found`, the exact defect `HYDRONIUM_INK_PACKAGING_DECISION.md` flagged and still unfixed |

**0.4 The mechanism that makes everything else possible.** `.moonstone/env/share/lua/5.1/` is a flat, shared Lua module namespace both ballad's own modules and a project's dependencies materialize into side by side (verified: `hydronium`, `hydronium_dom`, `hydronium_luax`, `ballad`, `dkjson` all sit together in `examples/meteorite_ssr/.moonstone/env/share/lua/5.1/`). Ballad's launcher (`bin/ballad`) sets `LUA_PATH` by **prepending** its own paths and **preserving** the inherited one. So a partiture run via `moon exec ballad -- play partiture.lua` can `require("hydronium_luax")` for real, and `plugin_host.load_plugin`'s dotted-name resolution will resolve `p:use("hydronium_ballad.plugins.luax")` the same way.

**0.5 A materialization rule that constrains the manifest, derived from three real cases.** Comparing dependency `role`s against what actually lands in `.moonstone/env/`:

- `moonstone/ballad`, `dkjson`, `clingy` etc. — `role = "tool"`, store-resolved → land in both `libexec/` and `share/lua/5.1/`.
- `hydronium`, `hydronium-dom`, `hydronium-luax` — `role = "runtime"`, path-resolved, `kind = "lib"` → land in both.
- `moonstone/meteorite` — `role = "tool"`, path-resolved, `kind = "bin"` → lands **only** in `libexec/`, not on `share/lua/5.1`.

**Consequence: `hydronium-ballad` must be declared `kind = "lib"` and consumed with `role = "runtime"`** to be `p:use`-able through a path dependency. Slightly awkward for a build-only package — a wart, not a blocker. **[UNVERIFIED]**: whether the rule is `kind`-driven or resolver-driven wasn't confirmed by reading moonstone's sync source; the three data points are consistent with either — confirm before writing the manifest.

---

## 1. Package boundary decision

### 1.1 Recommendation

**Make `hydronium-ballad` a fifth `orbits` member of the `hydronium` repo, at `hydronium/ballad/`** (naming caution below), published `kind = "lib"`, package name `hydronium-ballad`, plugins under `hydronium_ballad.plugins.*`. Not a separate repo. Not inside `ballad` itself.

Confidence: ~85% on "not inside `ballad`." ~70% on "workspace member rather than separate repo" — this half is genuinely contestable; steelman below.

### 1.2 Why not inside `ballad`'s own namespace

1. **Dependency-direction inversion.** A `ballad.plugins.luax` inside `ballad/src/ballad/plugins/` would make the general-purpose Lua build tool depend on one specific UI framework's compiler, shipping `hydronium_luax` into every `moon add moonstone/ballad` consumer's env — the identical "dead weight in every consumer" argument `HYDRONIUM_INK_PACKAGING_DECISION.md` used against keeping Ink inside `core`.
2. **The precedent already went the other way.** `meteorite.ballad`, not `ballad.plugins.meteorite`. Following the same shape costs nothing and buys consistency.
3. **Release cadence.** `moonstone/ballad` is a published dependency of at least seven projects in this workspace; every luax-compiler bugfix would otherwise become a ballad version bump consumed by projects with no `.luax` in them.

The one thing that *should* go upstream into `ballad`: a real, generic `ballad.plugins.lua.compile`/`.check` (syntax-check / bytecode compile) — but that's opportunistic, not a dependency of any milestone here.

### 1.3 Why a workspace member rather than a separate repo

Applying the ink decision doc's own method (packaging boundary vs. repo boundary are different questions):

- **Packaging boundary is unambiguous now**: `hydronium-ballad` must be its own package (a tool dependency; bundling it into `hydronium-dom`'s runtime library would materialize compiler-driver code into every browser consumer's env).
- **Repo boundary fails the co-evolution/frozen-contract tests** the ink doc applied: `hydronium-ballad` will consume `hydronium_luax.compile`'s return shape and `hydronium_dom.server`'s `client_plan` shape (`{ version = "hydronium.client-plan.v1", islands = {}, scripts = {} }` — explicitly `v1` and SSR-only by its own comment), neither of which is a frozen public API. A plugin consuming two unfrozen internal contracts is exactly the thing you don't put behind a publish cycle.
- **The "prove it as a third party" benefit is obtainable without a repo split** — `p:use("hydronium_ballad.plugins.luax")` resolving from any external app project (e.g. one scaffolded by `hydronium/create`) already *is* the external-plugin proof.

**Counter-precedent, stated fairly**: `hydronium/create` **is** a separate repo despite being hydronium-family — but it has zero runtime dependency on `hydronium` (it writes template text; its deps are `alter`, `clingy`, `ballad`). `hydronium-ballad` depends on hydronium's code at internal-API depth — a different animal.

**Steelman for splitting anyway**: a build plugin benefits most from being an outsider forced to use only the real public API; in-tree, it will reach into compiler/server internals because it can, and the compile API will never be forced to become a real one. This is real, hence 70% not 90% confidence. **Mitigation**: a standing guard — as a fresh `moon exec` subprocess, not an in-process `package.loaded` check (that exact mistake is the cause of the one still-failing spec) — asserting `hydronium_ballad.*` requires nothing from `hydronium_luax` except `hydronium_luax.compile`/`.loader`, and nothing from `hydronium_dom` except its documented public server entry points.

**Revisit the repo split when**: (a) `hydronium_luax.compile`'s options/return shape is documented as a stable versioned API, and (b) `client_plan` graduates past `v1`. Not before.

### 1.4 Concrete shape

```
hydronium/ballad/
  moonstone.toml            # name = "hydronium-ballad", kind = "lib", luajit 2.1.0 / abi 5.1
                            # [[dependencies]] hydronium-luax  constraint = "path:../luax"  role = "runtime"
                            # [[dependencies]] hydronium-dom   constraint = "path:../dom"   role = "runtime"
                            # [[dependencies]] moonstone/ballad constraint = "^0.3.7"       role = "tool"
                            # [scripts] package = "moon exec ballad -- play partiture.lua"
  partiture.lua             # registry source_package, same shape as the other four members
  REGISTRY_README.md
  src/hydronium_ballad/
    init.lua                # barrel: returns { plugins = { luax = ..., client = ..., site = ... } }
    plugins/
      luax.lua               # name = "hydronium_ballad.plugins.luax"  (owned by the luax/CSS/assets plan)
      client.lua              # name = "hydronium_ballad.plugins.client" (owned by the minifier/splitter plan)
      site.lua                 # name = "hydronium_ballad.plugins.site"  (integration glue, owned here)
  tests/
```

Plus one `[[orbits.member]]` entry in `hydronium/moonstone.toml`, and one entry in the root `partiture.lua`'s `layout.directory` list, matching the existing four.

**Naming caution:** `hydronium/ballad/` sitting next to the sibling repo `ballad/` is a real readability hazard for humans and agents alike. Lean toward naming the on-disk directory `hydronium/build/` while keeping the package name `hydronium-ballad` — `[[orbits.member]] name`/`path` are independent of `[package] name`, so this costs nothing.

---

## 2. What "deploy a whole reactive webpage" means, concretely

### 2.1 The command

In a Hydronium **app** project (not the framework repo) — the kind `hydronium/create` scaffolds:

```bash
moon exec ballad -- play partiture.lua      # or: moon run package
```

exits 0 and leaves a `dist/` a static host or a Meteorite binary can serve with no further steps.

### 2.2 The artifact tree

```
dist/
  client/
    chunk-<hash>.lua            # amalgamated, minified Lua chunks (package.preload form)
    runtime-<hash>.lua          #   framework core+dom, shared across routes
    entry-<route>-<hash>.lua    #   per-route/per-island entry
    mount-<hash>.js             # hydronium_dom/client/{mount,dom_bridge,boundary_registry}.js, bundled
    chunk-manifest.json         # { route|island -> [chunk urls], integrity? }
  assets/
    app-<hash>.css              # processed, scoped CSS
    <name>-<hash>.<ext>         # hashed images/fonts referenced from .luax
    asset-manifest.json         # { source path -> hashed public url }
  server/
    views/*.lua                 # .luax compiled to plain Lua, for the SSR side
  file-graph.json                # ballad's own, via p.sink.directory(..., { file_graph = true })
```

### 2.3 Two supported serving modes

**Mode A — static export.** `dist/client` + `dist/assets` + prerendered `index.html`. Requires the amalgamation bundler and the CSS pipeline; requires **no** Meteorite. Cheapest path to a real, deployable, reactive webpage — target the early milestones here.

**Mode B — Meteorite SSR binary.** What already works, verified: `examples/meteorite_ssr` builds a real ~1.6 MB Zig binary serving real buffered and streaming SSR from `.luax` via `hydronium_dom.server.meteorite.render`. `meteorite.site(app, {assets = {...}})` serves static dirs, copying declared asset dirs into `dist/static/route_N/` at build time.

What's genuinely missing: Meteorite has **zero** hydronium awareness (grep count: 0). There is no `meteorite.hydronium(...)` and won't be unless someone writes it meteorite-side. **Mode B means `hydronium-ballad` emits `dist/`, and the app's own `src/main.lua` points `meteorite.site`'s `assets` at `dist/client`/`dist/assets` — a wiring convention, not an integration.** Say this plainly rather than implying a Meteorite plugin exists.

Chaining `hydronium_ballad.plugins.site` → `meteorite.ballad.release` in one partiture is architecturally clean but mechanically **blocked today** by §0.5: `moonstone/meteorite` is `kind = "bin"` + path-resolved, so it never reaches `share/lua/5.1` and `p:use("meteorite.ballad")` cannot resolve. **[UNVERIFIED]** whether a registry-resolved `moonstone/meteorite` would land in `share/lua` — plausible (its own partiture collects `src/**` with `prefix = "meteorite"`), but unconfirmed. **Treat single-command Mode B as an explicitly deferred milestone with an open external dependency.**

### 2.4 Definition of done for Milestone 1

One real `.luax` component, in a real app project outside the hydronium repo, compiled by `hydronium_ballad.plugins.luax`, amalgamated and minified into **one** Lua chunk, emitted to `dist/` by one `p.sink.directory`, served over a real socket, mounted via `mount.js`, proven in Chromium under Playwright to: (a) fetch **≤ 3** HTTP requests where the existing proof fetches 25, (b) render the correct initial prop, (c) update the DOM on a real click. Same shape as the existing `docs/HYDRONIUM_CLIENT_MOUNT.md` proof. The request-count delta is the objective, falsifiable success metric.

---

## 3. Plugins and the Asset/AssetSet contract

### 3.1 Facts about ballad's real contract that constrain the design

Verified by reading `plugin_host.lua`, `pipeline.lua`, `graph.lua`, `cache.lua`:

1. A plugin is a plain table `{ name, version, methods = { <m> = { inputs, outputs, cacheable, parallel_safe } }, <m> = function(ctx, inputs: AssetSet[], opts) -> AssetSet }`. `Host:handler` hard-errors if a method returns a non-`AssetSet`.
2. `Asset.kind` is **not validated anywhere** — `meteorite.ballad` already emits custom kinds (`"meteorite_graph"`, `"meteorite_check"`) in production. Custom kinds are legal and precedented.
3. Method contracts have undocumented-but-real extra fields `PluginProxy.new` reads: `role` (source/transform/sink/control, default transform), `label`, `effects`, `progress_weight`, `inputs_from_entries`, and a `<method>_prepare(opts) -> table` hook merged onto the returned `NodeHandle` at graph-construction time.
4. **Execution is a single sequential loop** over `Graph:topological_order()`. `parallel_safe` only gates flushing pending *native* tasks — **do not design for in-process parallelism; it does not exist.**
5. **Caching is real and content-based, and round-trips in-memory content.** `cache.compute_key` hashes `{cache_version, plugin, method, plugin_version, options, control_conditions, input_asset_hashes}`; `hash_asset` b3sums `source_path` content, else `asset.content`. `cache.store` persists `asset.content` into the entry JSON. `cacheable = true` is correct and safe for pure content transforms emitting only in-memory generated assets.
6. **Cache keys serialize `node.options`, and `serialize()` errors on any function value.** Any method declared `cacheable = true` must accept only plain data in `opts` — no callbacks. Hard constraint on every plugin's option shape.
7. `p.sink.directory` calls `fs.remove_tree(out_dir)` first. Two sinks writing the same `out` destroy each other — one sink for the whole site, or strictly disjoint `out` trees.
8. `write_asset_to_directory` places an asset at `out_dir/<virtual_path>` (falling back to `output_path`/`source_path`/`id`), writing `content` for generated assets, copying for `source_path` ones. **`virtual_path` is the public URL path** — the single most important field in the whole contract.
9. `p.source.files(patterns, {root})` emits `{ kind = "file", source_path, virtual_path = <relative to root>, metadata }` — the input shape every transform receives at the head of the graph.

### 3.2 Three plugins, not one

| Plugin | Responsibility |
|---|---|
| `hydronium_ballad.plugins.luax` | `.luax` → Lua source; style extraction; static-asset reference discovery (see `docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md`) |
| `hydronium_ballad.plugins.client` | module-graph resolution, amalgamation, chunk splitting, minification (see the Lua minifier/bundle-splitter plan) |
| `hydronium_ballad.plugins.site` | asset hashing, manifest emission, CSS merge, final layout (integration glue) |

Three, not one: genuinely different cache characteristics (per-file pure vs. whole-graph vs. layout-only), different failure modes, different owners. They compose through `AssetSet`s and never call each other directly.

### 3.3 Method contracts (concrete)

```lua
-- hydronium_ballad.plugins.luax
name = "hydronium_ballad.plugins.luax", version = "0.1.0",
methods = {
  compile = { inputs = {"asset_set"}, outputs = {"asset_set"}, cacheable = true,  parallel_safe = true },
  check   = { inputs = {"asset_set"}, outputs = {"asset_set"}, cacheable = true,  parallel_safe = true },
}
-- hydronium_ballad.plugins.client
name = "hydronium_ballad.plugins.client", version = "0.1.0",
methods = {
  resolve = { inputs = {"asset_set"}, outputs = {"asset_set"}, cacheable = true,  parallel_safe = true },
  bundle  = { inputs = {"asset_set"}, outputs = {"asset_set"}, cacheable = true,  parallel_safe = true },
  minify  = { inputs = {"asset_set"}, outputs = {"asset_set"}, cacheable = true,  parallel_safe = true },
}
-- hydronium_ballad.plugins.site
name = "hydronium_ballad.plugins.site", version = "0.1.0",
methods = {
  styles   = { inputs = {"asset_set"}, outputs = {"asset_set"}, cacheable = true,  parallel_safe = true },
  assets   = { inputs = {"asset_set"}, outputs = {"asset_set"}, cacheable = true,  parallel_safe = true },
  manifest = { inputs = {"asset_set"}, outputs = {"asset_set"}, cacheable = false, parallel_safe = true },
}
```

`manifest` is `cacheable = false` because it embeds a run-wide view and a stale hit there is a silent-wrong-output failure; the node is microseconds of work regardless.

### 3.4 The Asset contract between the plugins (the load-bearing interface)

**Namespaced metadata.** Every asset carries a single namespaced table `metadata.hydronium = { ... }`. Never write bare top-level metadata keys — `metadata` is copied verbatim into cache-entry JSON and `file-graph.json`, and a collision with ballad-core-meaningful keys (`layout`/`kind`/`executable`) is silent and painful.

**Kinds this package introduces** (legal per §3.1.2):

| `kind` | Produced by | Meaning |
|---|---|---|
| `hy_module` | `luax.compile` | one compiled Lua module, ready to be a `package.preload` entry |
| `hy_style` | `luax.compile` | extracted style/CSS fragment attributable to one component |
| `hy_asset_ref` | `luax.compile` | a *reference* to a static file a component names — not the file |
| `hy_chunk` | `client.bundle` / `client.minify` | one amalgamated (possibly minified) Lua chunk |
| `hy_manifest` | `site.manifest` | generated JSON |

**Contract 1 — `luax.compile` output** (consumed by `client.*`):

```lua
ctx.graph:add_asset({
  kind = "hy_module", generated = true,
  source_path = nil,                        -- MUST be nil: content is authoritative
  virtual_path = "views/App.lua",           -- source-relative, ".luax" -> ".lua"
  content = compiled.code,
  metadata = { hydronium = {
    module_id  = "views.App",               -- REQUIRED. the exact require() id. sole join key.
    origin     = "views/App.luax",          -- REQUIRED. real path, for diagnostics/HMR
    target     = "client" | "server" | "shared",   -- REQUIRED. set by the PARTITURE AUTHOR, never inferred
    sourcemap  = compiled.map_json,
    style_ids  = { "hy_s_1a2b", ... },
    asset_ids  = { "hy_a_9f3c", ... },
    diagnostics = { bare_tags_without_alias = compiled.bare_tags_without_alias },
  }},
})
```

Three load-bearing rules:
- **`module_id` is required and is the sole join key.** `mount.js` already does `package.preload["<module_id>"] = assert(load(src, "<module_id>"))`, and `gen_client_manifest.lua` already produces `{module_id -> relpath}` maps. Never re-derive an id from a path.
- **`target` is set by the partiture author** (via `p.source.files(..., { metadata = { hydronium = { target = "client" } } })`, which `source.files` copies onto every asset verbatim), never inferred by the compiler — it has no way to know what's client-reachable.
- **`content`, not `source_path`.** `write_asset_to_directory` prefers `content` for generated assets, and `hash_asset` b3sums `content` — setting both would hash the wrong thing.

**Contract 2 — CSS flows through the SAME pipeline, in a parallel branch that merges at the sink.** `luax.compile` emits `hy_style` assets in the same returned `AssetSet` as `hy_module`s (one node, one traversal per file, one cache entry). The partiture splits by kind (`AssetSet:filter`) and routes through different transforms, rejoining at the sink — one build graph, one cache domain, one `remove_tree`-safe sink.

**The scoping handshake** (both the CSS plan and the minifier plan must implement this identically): `scope_class` (e.g. `"hy-App-1a2b"`) is minted by `luax.compile` — the only step that sees the component — and emitted into the compiled Lua source as a literal, appended to the element's `class` prop. `site.styles` only rewrites the CSS side to match. **Neither the bundler nor the minifier may rewrite it — `scope_class` string literals must survive minification.** This restates `docs/BUNDLING.md`'s own "Table Key Protection" rule as a hard invariant.

**Contract 3 — static assets are referenced before they're resolved**: `hy_asset_ref` carries `asset_id` (the join key) and `specifier` (as written in the component); `site.assets` hashes the file and rewrites `virtual_path`. Compiled modules must not inline the final URL — they look it up via `asset_id` at runtime or through a manifest substitution.

**Contract 4 — `client.bundle` output** (produced for `site` to consume):

```lua
kind = "hy_chunk", generated = true,
virtual_path = "client/runtime-<b3-8>.lua",      -- assigned by client.bundle; this IS the URL
content = "<amalgamated package.preload source>",
metadata = { hydronium = {
  chunk_id   = "runtime",
  module_ids = { "hydronium.core.element", ... },   -- REQUIRED, exact contents
  entry      = "views.App" | nil,                   -- entry chunks only
  requires   = { "runtime" },                       -- chunk_ids that must load first
  minified   = true|false,
  format     = "package_preload_v1",                -- REQUIRED
}}
```

**`format = "package_preload_v1"` is defined as exactly the shape `mount.js` already synthesizes at runtime today**: a chunk that, when `load()`ed and called, installs `package.preload[<module_id>] = <loader>` for each of its `module_ids` and returns nothing. Deliberate: it means the browser loader change for Milestone 1 is "fetch one file and `doString` it" instead of "fetch 22 files and synthesize the preload table" — **`mount.js` gets simpler, not more complex**, preserving the already-verified mount path. It also matches `docs/BUNDLING.md` §3.1's template.

**Contract 5 — `site.manifest`** emits `chunk-manifest.json`/`asset-manifest.json`. This is the direct successor to today's hand-generated `client_manifest.json`. **`dom/tools/gen_client_manifest.lua` should not be deleted** — its tracing-`require` technique is the correct way to derive the real graph, and `client.resolve` should reuse that exact approach in-process rather than reimplementing module resolution (honoring this codebase's own stated rule: "never maintain manual source lists when the runtime/compiler already knows the require graph").

### 3.5 Sketch of the partiture an app project ends up with

```lua
local ballad = require("ballad")

return ballad.partiture(function(p)
  local luax   = p:use("hydronium_ballad.plugins.luax")
  local client = p:use("hydronium_ballad.plugins.client")
  local site   = p:use("hydronium_ballad.plugins.site")

  local client_src = p.source.files({ "**/*.luax", "**/*.lua" },
    { root = "src/client", metadata = { hydronium = { target = "client" } } })
  local server_src = p.source.files({ "**/*.luax" },
    { root = "views", metadata = { hydronium = { target = "server" } } })

  local compiled = luax.compile({ client_src, server_src }, { runtime = "hydronium" })

  local chunks = client.minify(
    client.bundle(client.resolve(compiled, { entries = { "app.client.root" } }), { split = "route" }),
    { level = "safe" })

  local styles = site.styles(compiled, { scope = "component" })
  local files  = site.assets(compiled, { hash = "b3", length = 8 })

  p.sink.directory(site.manifest({ chunks, styles, files, compiled }),
                   { out = "dist", file_graph = true, product = "site" })
end)
```

**[UNVERIFIED]**: whether multi-upstream methods should use `depends_on` or `inputs_from_entries` (`layout.directory` uses the latter). Resolve early — it shapes every method signature above. Tentative pick: `inputs_from_entries = true` for `site.manifest`.

---

## 4. Sequencing

### M0 — Groundwork (small, unblocks everything) — **items 1 and 3 DONE**

1. ~~Fix `tests/core/lazy_barrel_spec.lua`'s `sh: lua: command not found`~~ **DONE**: the spec shelled out to a bare `lua` binary, which isn't on PATH in this environment; switched to `luajit` (the one interpreter every environment running this suite already has — `tests/runner.lua` itself runs under it). Full suite is now **438/438**, the first fully-green run of this entire engagement.
2. Land the currently-uncommitted ballad-integration tree (the four `partiture.lua` + `[scripts] package` additions) so the ballad baseline is a committed fact. **Not done** — that tree is still actively churning under a different, concurrent process (confirmed: more files under modification on a later check than when this doc was first written) and is not this initiative's to commit.
3. ~~**Prove `p:use("hydronium_ballad.plugins.luax")` resolves at all**~~ **DONE, and it works.** Built the real package skeleton at `hydronium/build/` (package name `hydronium-ballad`, per §1.5's naming caution — directory named `build/` to avoid confusion with the sibling `ballad` repo), registered as a fifth `[[orbits.member]]` (`name = "ballad"`, `path = "build"`) in `hydronium/moonstone.toml` and `hydronium/partiture.lua`'s `layout.directory`. `src/hydronium_ballad/plugins/luax.lua` is a real, if minimal, plugin (`compile` returns an empty `AssetSet` — M1 will make it call `hydronium_luax.compile` for real). Proved external resolution from a genuinely separate scratch project (`moonstone.toml` with `hydronium-ballad` as a `path:` dependency, `role = "runtime"`, `kind = "lib"` — confirming §0.5's materialization-rule guess was right) running `moon exec -- ballad play partiture.lua`: `p:use(require("hydronium_ballad").plugins.luax)` resolved, `luax.compile(...)` executed as a real graph node, and `p.sink.stdout` printed the expected empty result. **This is the single highest-value experiment in this whole plan, and it landed clean on the first real end-to-end attempt** (after one iteration fixing the probe script's own misunderstanding of ballad's lazy graph API — plugin methods return deferred `NodeHandle`s, not immediate `AssetSet`s, until the pipeline actually executes).

### M1 — DONE, verified live in a real Chromium browser

Implemented `hydronium_ballad.plugins.luax.compile` for real (calls
`hydronium_luax.compile`, emits `hy_module` assets per the Contract 1
shape above) and `hydronium_ballad.plugins.client.resolve`/`.bundle`
(static require-graph walk, `package_preload_v1` amalgamation via the
Form B long-bracket-string encoding). Wired `dom/src/hydronium_dom/client/mount.js`
with a new `chunkUrls` option (fetch + `load()` each real chunk, no
manifest/per-module fetches needed) alongside the existing unbundled path,
kept for backward compatibility rather than deleted outright as originally
sketched — see the real regression this caught, below.

**Two real bugs found and fixed while proving this, both the kind only a
real run catches:**
1. `client.resolve`'s entry-walk only followed requires reachable from the
   app's own root component — but `mount.js`'s own final bootstrap script
   requires `hydronium_dom.host.dom` directly, independent of anything the
   app itself requires. A real Playwright run produced a bundle silently
   missing that module, failing at runtime with `module
   'hydronium_dom.host.dom' not found`. Fixed by always including
   `mount.js`'s own fixed bootstrap module set (`hydronium`,
   `hydronium.core.element`, `hydronium_dom`, `hydronium_dom.host.dom`,
   `hydronium.core.reconciler`) as entries alongside the app's own, so a
   partiture author never needs to know mount.js's internals to get a
   working bundle.
2. The "hydronium" luax compile target unconditionally emits `H.h(...)`
   for every element (H being the createElement factory reference,
   independent of bare vs. lexical tag choice) — mount.js's shared final
   block needed `H = require("hydronium")` as a real global for any
   `.luax`-compiled entry to work at all. Setting this unconditionally
   **broke the existing, already-verified unbundled `client_mount_demo`**
   (its hand-written `app.lua` never requires the "hydronium" barrel
   directly, so it was never in that demo's own module set) — caught
   immediately by re-running that demo's own Playwright proof after the
   change, not assumed safe. Fixed by wrapping it in `pcall`, so it's set
   opportunistically without hard-failing apps that never need it.

**Verified live, Playwright + real Chromium, both proofs passing after
the fixes above:**
- **New bundled proof** (a `<d.div>`/`<d.p>`/`<d.button>` counter
  component, compiled → resolved → bundled → served): correct initial
  render (`Count: 0`), two real clicks driving state to `Count: 2` through
  the real reconciler, and **3 runtime/wasm-related requests** (the
  wasmoon ESM import, the wasm glue binary, and exactly ONE chunk) —
  beating the ≤3 target against the existing proof's 25.
- **Existing unbundled `client_mount_demo` re-run unchanged, 5/5 checks
  still passing** — confirms the new bundled code path is additive, not a
  breaking change to the already-shipped API.
- `luajit tests/runner.lua`: 438/438 (the `lazy_barrel_spec` fix from M0
  is holding; this really is a fully green suite now, not just "the same
  lone failure as always").

### M1 — original plan text (superseded by the above; kept for context)

Deliberately one component, one chunk, no splitting, no CSS, no assets, no SSR.
- `luax.compile` for real (source → `hy_module` via `hydronium_luax.compile`).
- `client.resolve` + `client.bundle`: reuse `gen_client_manifest.lua`'s tracing-`require` for the real graph; emit **one** `hy_chunk` in `package_preload_v1` format.
- `p.sink.directory(..., { out = "dist" })`.
- Teach `mount.js` a `chunkUrls` option: fetch the chunk(s), `doString` each, then proceed exactly as today.
- **Proof**: the §2.4 definition of done, driven by Playwright, using the same fetch-count wrapper the existing proof already uses. Target ≤ 3 requests vs. today's 25.

Explicitly not in M1: minification, splitting, CSS, static assets, hydration, routing, Meteorite.

### M2 — Minification — DONE, verified live

Implemented `hydronium_ballad.plugins.client.minify(level="safe")`: a real
lexer-based minifier reusing `hydronium_luax.lexer.tokenize(src, name,
{include_whitespace=true})` (LuaJIT's own compiler front end, not a new
dependency) -- strips comments and collapses whitespace runs to their
real newline count (`preserve_lines = true` by default, so every
module's own line numbers, and therefore its `map_json` sourcemap, stay
exactly valid), and NEVER touches a token that isn't whitespace/comment
trivia -- since `read_string`'s stored token value is the raw source
text, this makes the "never alter a string literal" hard invariant hold
by construction, not by configuration. Runs on the `hy_module` AssetSet
BETWEEN `resolve()` and `bundle()` (per-module, before amalgamation), not
on the already-concatenated chunk -- so the mandatory unconditional
per-module `load()` gate (fail the build naming the exact module, not a
runtime browser surprise) can actually point at which one module broke,
if any ever does. `bundle()` now also reads the `minified` flag through
from its input modules into the emitted chunk's own metadata instead of
hardcoding `false`.

**Verified live**, same rigor as M1, both on the direct plugin-call
harness and through a real `ballad play` run + Playwright/Chromium:
- 152,461 -> 93,073 bytes on the 30-module resolved graph (**39.0%
  reduction**), consistent with the bundler plan's own independent
  measurement on a different module set (~41.7% raw).
- Every one of the 30 real modules passed the per-module `load()` gate
  with zero failures.
- The real emitted chunk (94,697 bytes minified vs. 143,381 unminified)
  loaded and ran correctly in a genuinely fresh, isolated process
  (`package.path`/`package.cpath` wiped) -- same technique as M1.
- **Re-ran the full M1 Playwright browser proof against the minified
  bundle**: correct initial render, two real clicks driving state to
  `Count: 2`, same 3 runtime/wasm requests -- byte-for-byte behaviorally
  identical to the unminified version, in real Chromium against real
  wasmoon (confirmed Lua 5.4, per the bundler plan's own finding).
- `luajit tests/runner.lua`: still 438/438 after adding the minifier.

**Not done, explicitly out of scope, permanently per the bundler plan's
own §4.3** (not just "not yet"): string-literal rewriting, table-key
renaming, any identifier renaming (local or global), constant folding,
dead-code elimination, and tree shaking (unsound here -- this codebase's
own HMR machinery manipulates `package.loaded`/`_G.require` at runtime).
A full whole-repo-test-suite-through-the-bundle equivalence gate (the
bundler plan's own G1/G2, exercising all 438 specs through
`package.preload` substitution the way that plan's own author did) was
**not** run this session -- what was verified is the real client-relevant
subgraph (core+dom, 30 modules) via a dedicated fixture app, not the
whole repository including luax's native/tree-sitter tooling (which
likely isn't even bundleable as pure Lua text, being partly FFI/.so
-backed) or ink. Setting up G1/G2 as real, standing CI gates in
`build/tests/` remains open future work, not done here.

### M3 — Splitting: DONE (the mechanical half). CSS + assets: not started.

**Splitting implemented and verified live.** `d.lua.mount(vnode, opts)`
gained an optional `opts.module` (plus `mode`/`hydrate`) parameter --
the one real prerequisite gap the bundler plan's §5.1 found (`raw_props.module`
was already read unconditionally server-side; `lua_mount` was the only
call site with no way to supply it). `client.bundle` gained
`split = "entry"`: given MULTIPLE separate `resolve()` outputs (one per
real entry point, fed in via `depends_on` -- resolve() itself has no way
to recover per-entry reachability once merged, so the caller must supply
it this way), a module reachable from ≥2 entries or matching a
`shared_roots` prefix (default `hydronium.`/`hydronium_dom.`) goes into
one shared `runtime` chunk; a module reachable from exactly one entry
goes into that entry's own tiny chunk, with `requires = {"runtime"}`.

**Verified live** with two real, independent `.luax` apps (`App1`: a
counter; `App2`: an idle/clicked label) sharing the same 29-module
framework graph, through a real `ballad play` run:
- Real output: `runtime-<hash>.lua` (94,477 bytes, all 29 shared
  framework modules, `requires: []`), `entry-App1-<hash>.lua` (875 bytes,
  `module_ids: ["App1"]`, `requires: ["runtime"]`), `entry-App2-<hash>.lua`
  (872 bytes, same shape for App2).
- **Real per-page code exclusion, not just claimed**: loading
  `runtime`+`entry-App1` in a fresh isolated process and trying
  `require("App2")` fails with `module 'App2' not found` -- App2's code
  is genuinely absent from a page that never asked for it. Loading
  `runtime`+`entry-App2` on its own works correctly.
- **Real browser proof, Playwright/Chromium**: `mount({chunkUrls:
  ["runtime.lua", "entry.lua"], appModuleId: "App1"})` fetched exactly the
  2 chunks named, in order, and rendered/updated correctly (`App1 Count: 0`
  -> click -> `App1 Count: 1`).
- 3 new regression specs added to `tests/server/islands_suspense_spec.lua`
  for the `d.lua.mount` `module` option and its `client_plan` round trip.
  `luajit tests/runner.lua`: 440/440.

**What "anchor on `client_plan`" concretely means, and what's still
open**: the algorithm above is real and works given a real list of entry
module ids -- what's NOT done is having `hydronium_ballad` itself
derive that entry list FROM a real `client_plan` (`{version =
"hydronium.client-plan.v1", islands = {}, scripts = {}}`, returned by
`server.render_to_string`) automatically, filtering to
`interpreter == "lua"` islands and reading each one's now-real `module`
field. That wiring -- and the coupling risk it inherits (a `v1`,
SSR-only structure, so a pure static-export build has no `client_plan`
at all unless it prerenders, exactly as the bundler plan's §5.3 flagged)
-- is real, separate future work, not done this pass. This session
proved the mechanism with hand-supplied entry lists, which is a
legitimate, real usage mode on its own (any partiture author who already
knows their own entry points can use `split="entry"` today, `client_plan`
automation or not).

**CSS + static assets (docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md): not started
this session.** Still open: `hydronium_ballad.plugins.style`/`.plugins.assets`,
`hydronium_dom.css`/`hydronium_dom.assets`, the FNV-1a scoped-class
hasher, `reset.css`, generated `.d.lua` class types, and the manifest
merge node.

### M4 — SSR → hydrate round trip — DONE. Found and fixed a real bug that had silently defeated hydration for every real page.

Drove `mount.js`'s `hydrate: true` against real SSR output for the first time, via a real Playwright/Chromium run: an app SSR-rendered through `hydronium_dom.server.render_to_string(dom.d.lua.mount(H.h(App, props)))` (the real, only documented root-mount API), served as real HTML, then hydrated client-side against the exact same bundled chunk `hydronium_ballad.plugins.client` produces (reusing the M1-M3 pipeline directly, not a separate hand-wired proof).

**First run failed, and it failed in a way that had been invisible until now**: the page still *worked* (correct initial text, clicks still updated it) — but the DOM node was **not** the same node before and after `mount()`, and the browser console logged real hydration mismatches (`element_mismatch` + two `extra_root_child`). `Reconciler:hydrateRoot` had silently fallen back to a full remount, throwing away and rebuilding the entire SSR-rendered subtree, for every single real page — because `hydronium_dom.server`'s island rendering *always* wraps content in real HTML comment markers (`<!--hy:i:ID:lua-->...<!--hy:/i:ID-->`, including for a plain `d.lua.mount()` root, which is a root-sized island), and `Reconciler:hydrate`'s DOM walk had no way to tell "this is a discovery-only marker, skip it" from "this is a real, unexpected node" — so the very first hydrate attempt saw the opening comment where it expected the app's own root element, reported a mismatch, and remounted.

This was invisible before because the *page itself* still rendered and behaved correctly either way (a full remount produces the same final DOM as a real hydration would) — only DOM node identity and the mismatch log reveal the difference, neither of which any prior test or demo had ever checked. `docs/HYDRONIUM_CLIENT_MOUNT.md`'s own "What this is NOT" section had flagged the round trip as literally unexercised; this is why.

**The real fix** (`core/src/hydronium/core/reconciler.lua`'s `Reconciler:hydrate`, the `FRAGMENT`/transparent-Lua-island branch): skip over comment-node siblings — both before matching the first real child and after the last one — via a new optional `host.isCommentNode` capability (mirrors the existing optional `host.hydrationMismatch` pattern, so a host that never provides it just keeps the old, still-broken-for-comment-wrapped-output behavior rather than erroring). Implemented for the real DOM host: `dom/src/hydronium_dom/host/dom.lua` wires it to a new `bridge.is_comment`, and `dom/src/hydronium_dom/client/dom_bridge.js` implements it for real (`node.nodeType === 8`).

**Verified twice**: a real Playwright re-run after the fix — same node identity preserved (`true`), zero mismatches, correct `Count: 10` → two clicks → `Count: 12` — and a new native regression test (`tests/host/dom_spec.lua`, using a fake bridge extended with a real comment-node kind, building the exact SSR marker shape by hand) that **fails without the fix and passes with it** (confirmed by literally reverting the reconciler change and re-running it). Full suite: 454/454.

**Scope note**: only the root-mount (`FRAGMENT`/transparent-Lua-island) branch was touched — deliberately, since that's exactly where the bug reproduces and where the fix was verified. Partial (non-root) island hydration inside a larger page, and JS-island hydration (a structurally different code path), were not exercised by this pass and may have their own unverified edge cases; the `cursor ~= boundaryNode` guard in the fix is a defensive measure for the bounded case, not a claim that case was tested.

### M5 — Meteorite wiring (Mode B) — DONE for real, against a genuinely compiled binary. This is the full loop closing.

Added a real `partiture.lua` to `examples/meteorite_ssr` (a NEW, permanent part of that example, not a scratch probe): resolves+minifies+bundles a real `hydrate_demo/app.lua` component plus the full `hydronium`/`hydronium_dom` framework into one chunk under `dist/client/`, exactly the same `hydronium_ballad.plugins.client` pipeline M1-M3 already proved. Added one line to `meteorite.site`'s `assets` map (`/dist/client/:path*` -> `dist/client`) and one new route, `/hydrate-demo`, in `src/main.lua`: SSR-renders `hydrate_demo/app.lua` via `dom.d.lua.mount(...)` + `server.render_to_string(..., {suppress_client_plan_script=true})` directly (not through `meteorite_adapter.render`'s shared-page-shell path, which has no room for this route's own `<script type="module">` -- a real, legitimate second way to use `hydronium_dom.server`, alongside every other route in this file that DOES use the shared-shell adapter), then emits a `<script>` calling `mount({chunkUrls: [...], hydrate: true, ...})` against the real, separately-built, content-hashed chunk (found via `io.popen("ls dist/client/*.lua")` at request time, the same live-content-per-request technique this file's own route 9 already established for exactly this "the real build hash changes" reason).

**One real bug found and fixed while wiring this** (not assumed from `meteorite_adapter.render`'s own code): that adapter defensively checks `if type(c.html) == "function"` before calling `c:html(...)`, implying a `c:html` context method might exist -- it does not, on this real compiled binary. Found live: the first real run of `/hydrate-demo` returned `internal server error` / `attempt to call a nil value (method 'html')`. Every real route actually needs to return a plain response table (`{status, content_type, headers, body}`) instead -- the `c:html` branch in `meteorite_adapter.render` is dead code in practice, never actually exercised by any of this file's own EXISTING routes either (they all fall through to that same table-return path without anyone having previously noticed `c:html` doesn't work).

**Verified live, against `dist/server` -- a real ~1.7MB `zig build -Dmode=release-hybrid -Dbackend=std_http` binary, not a Node.js stand-in server**:
- `curl http://127.0.0.1:8080/hydrate-demo` returns the real SSR HTML (`Count: 10`, real island comment markers, a real `<script type="module">` referencing the real content-hashed chunk URL).
- `curl -I http://127.0.0.1:8080/dist/client/runtime-<hash>.lua` returns `200`, the correct `content-length` (95,258 bytes), and a real ETag -- the bundle is genuinely servable as a static asset from the compiled binary.
- **A full Playwright run against the real running binary**: SSR pre-hydrate text `Count: 10`, hydration completes with no error, the DOM node is confirmed the SAME node object before and after (`true` -- the M4 fix holding up against a real server, not just the earlier synthetic Node.js-server proof), and two real clicks correctly drive `Count: 10` -> `Count: 12` through the real reconciler. Exactly one chunk request observed, matching the one `dist/client/*.lua` file the build produced.
- Full suite: 454/454 (example-only changes; confirmed the native suite is unaffected regardless).

This is the complete, real, end-to-end proof this whole initiative was aimed at: `hydronium-ballad` builds a real bundle -> a real compiled Meteorite binary serves both the SSR page and that bundle as a static asset -> a real browser hydrates against it with zero DOM churn and working interactivity.

**Not done, explicitly**: `hydronium/create` template updates (scaffolding a fresh project with this wiring built in) and chaining `hydronium_ballad.plugins.client`/`.site` directly into `meteorite.ballad.release` in one partiture (still blocked by §2.3's `moonstone/meteorite` materialization finding -- this session's wiring uses the "two separate build steps, `ballad play` then `zig build`" convention instead, which is real and works, just not a single command).

### Explicitly deferred

- **A router** — zero client-side navigation exists anywhere in this codebase; building one alongside an unproven build system would couple two unproven things. It's a `hydronium-dom` feature the bundler later learns to split around, not a bundler feature.
- **Upstreaming a real `ballad.plugins.lua.compile`** — nice, unrelated to the critical path.
- **The `hydronium-ballad` repo split** — revisit per §1.3's two conditions.
- **HMR through the bundler** — the existing HMR path works *because* nothing is bundled; wire `ballad.plugins.watcher` in only after M2.

---

## 5. Risks

### 5.1 Ballad's immaturity — real, but narrower than it looks

`ballad.plugins.lua` being a stub is a real signal, but the parts `hydronium-ballad` actually depends on are not stubs: the graph/topological executor, `Host:resolve`'s dotted-name external-plugin path, the content-addressed cache (including in-memory `content` round-trip), `p.source.files`, `p.sink.directory`, `write_asset_to_directory`'s `virtual_path` placement — all verified real. `meteorite.ballad` is a working existence proof a substantial external plugin can be built on this seam.

Real, specific ballad risks: (a) single-threaded execution, no parallel compile without native tasks; (b) `serialize()` rejects function-valued options on any cacheable node, constraining every plugin's public option shape; (c) `sink.directory`'s `remove_tree` makes multi-sink layouts a footgun; (d) `metadata` has no namespace discipline in ballad core, hence the mandatory `metadata.hydronium` namespacing above. All four are designed around.

### 5.2 The two-VM problem — the genuinely open question, not to be hand-waved

**(a) Which Lua dialect does the browser actually run?** `mount.js` imports `wasmoon@1.16.0`. One `hydronium-create` template comment claims wasmoon is "LuaJIT compiled to WASM" — **this is very likely wrong** (wasmoon is Lua 5.4 compiled to WASM), but was **[UNVERIFIED]** without network access. This is a blocking input to the minifier/bundler plan: every hydronium package declares `abi = "5.1"`/`luajit 2.1.0`, so if the browser is 5.4, the client already runs 5.1-targeted source on a 5.4 VM, working today only via file-level compat shims (`local unpack = table.unpack or unpack` appears at the top of ≥10 core modules). **Resolve empirically in M0** (`lua.doString("return _VERSION")` in the existing proof page) before designing a minifier.

**(b) Those shims are a minifier hazard.** `local unpack = table.unpack or unpack` is a file-scoped local shadowing a same-named global. Amalgamating into `package.preload` closures preserves that scoping (each module keeps its own function scope) — another reason `format = "package_preload_v1"` is right rather than naive concatenation. A renaming minifier that merges scopes, or treats `unpack` as a known global, will silently break on 5.4. This needs an explicit test case.

**(c) JS bundling intuitions likely don't transfer.** Minification's value is unclear — the dominant browser-side cost is booting a ~MB WASM VM and `load()`ing Lua source, not parsing 200 KB of text; measure before optimizing (M1's metric is deliberately *request count*, not bytes). Tree-shaking is likely unsound given this codebase's dynamic `require`/`package.preload` manipulation (HMR's `family_loader`) — assume none; scope minification to whitespace/comment/local-rename only. Lazy chunk loading has no `import()` analogue in wasmoon (loading another chunk is JS fetching text and calling `lua.doString`) — splitting is a JS-side orchestration problem, which is exactly why M3 anchors splitting on `client_plan`'s island boundaries (where JS already owns the transition) rather than an arbitrary graph cut. Source maps: `hydronium_luax.compile` already returns `map_json` — preserve it through the pipeline (cheap), but don't promise a browser-devtools debugging experience without checking whether anything can consume a Lua source map there.

### 5.3 The unproven SSR→hydrate round trip is a hard prerequisite for "a real webpage"

`docs/HYDRONIUM_CLIENT_MOUNT.md` states plainly, under "What this is NOT," that `mount()`'s `hydrate: true` calls the real `Reconciler:hydrateRoot` but nothing has driven it end-to-end against real server-rendered markup — the live Playwright proof used `hydrate: false`. This is a blocking prerequisite specifically for the Mode-B/"real webpage" milestone, of an unusual kind: the build system could be finished, correct, and fully proven at M3, and "deploy a whole reactive webpage with SSR" would still not work, because the failure would be in `Reconciler:hydrateRoot` against real markup — not `hydronium-ballad`'s code, and not fixable there.

Consequences: M1 targets client-only mount, not hydration (why static export is the early target — a real, deployable, reactive webpage that doesn't depend on hydration working). M4 is gated on a hydration proof that is a hydronium-core task, sequenced before bundler work assumes it. And whoever proves hydration should prove it **against the bundled loader**, not the current one, since a chunked loader changes VM-ready-vs-markup-present timing and a proof against the old loader won't transfer.

### 5.4 Two smaller risks

- **`client_plan` is `v1` and SSR-only by its own comment.** Building the splitting strategy on it (M3) couples to an explicitly provisional structure — acceptable (it's the only real source of route/island truth) but argues for the in-tree workspace-member boundary and for a guard asserting the shape.
- **Bare vs. lexical tags.** Every real example still uses bare tags despite lexical being canonical (per this repo's own `CLAUDE.md`), and `compile` already returns `bare_tags_without_alias`. Surface this as a build warning (M1, via `metadata.hydronium.diagnostics`) — but don't make it an error; that would fail the build on every existing example in the repo.

---

## 6. Open questions not resolved read-only

1. **Does `p:use("hydronium_ballad.plugins.luax")` actually resolve?** Mechanism verified (§0.4–0.5); execution not attempted. M0 item 3 — highest-value single experiment in this plan.
2. **Is the share/lua materialization rule `kind`-driven or resolver-driven?** Determines the `hydronium-ballad` manifest.
3. **Is the browser VM Lua 5.4?** Blocking input to the minifier/bundler design.
4. **Would a registry-resolved `moonstone/meteorite` reach `share/lua/5.1`**, enabling `p:use("meteorite.ballad")` chaining? Determines whether single-command Mode B is reachable at all.
5. **Multi-input plugin methods**: `depends_on` vs. `inputs_from_entries`. Shapes every method signature.
6. **`hydronium/create`'s ownership.** A separate repo whose ~1456 lines of template hardcode today's un-bundled wiring in prose and code. Every milestone here invalidates part of it; nothing here schedules that work. It needs an owner.
7. Not run: `moon exec ballad -- play partiture.lua`, `moon sync`, a push to the local registry, or Playwright. Everything about build *behavior* above is derived from reading ballad's real source plus artifacts already on disk, not from an actual run.

---

## Critical files for implementation

- `ballad/src/ballad/pipeline.lua` — `PluginProxy`/`PipelineContext`/`Pipeline:execute`; the real plugin invocation, sink, and source semantics every contract above is derived from
- `meteorite/src/ballad/init.lua` — the only working external ballad plugin in this workspace; the structural template for all three `hydronium_ballad` plugins
- `hydronium/luax/src/hydronium_luax/compiler/init.lua` — `compiler.compile(source, opts) -> { code, sourcemap, map_json, bare_tags_without_alias }`; the exact API the luax plugin drives
- `hydronium/dom/src/hydronium_dom/client/mount.js` (lines 119–177) — the `package.preload` shape the bundler must emit, and the file M1 modifies
- `hydronium/dom/src/hydronium_dom/server/init.lua` — `client_plan` and its return from `renderToString`; the real route/island split signal for M3
- `hydronium/moonstone.toml` + `hydronium/partiture.lua` — the four-member orbit and its `layout.directory` composition, which the fifth member joins
