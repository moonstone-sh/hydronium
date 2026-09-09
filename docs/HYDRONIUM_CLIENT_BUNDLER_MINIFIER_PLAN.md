# `hydronium_ballad.plugins.client` — module resolution, amalgamation, minification, splitting

**Companion docs**: `docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md` (overall package boundary, milestones, and the Asset contract this plan implements one branch of) and `docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md` (the `.luax` compile plugin this plan consumes output from). **This plan corrects several claims in the architecture doc — see the reconciliation note at the very end of that doc, and §3/§7 below.**

**Scope:** the `client` plugin only — `resolve`/`bundle`/`minify`, the `package_preload_v1` format, the minifier, the splitting algorithm, the `mount.js` loader change. Not `.luax` compilation, CSS, assets, or the manifest.

**Post-implementation adversarial review found and fixed one real bug**: `build_chunk_source`'s `long_bracket_level` (choosing how many `=` signs make a module's wrapping `[==[...]==]` long-bracket string safe) had two real defects — (1) it used `gmatch`, which does non-overlapping matches and can miss a longer bracket run starting inside an already-matched shorter one (e.g. `]]=]`), and (2) it scanned bare `content` instead of `content .. "]"`, missing that the closing delimiter's own leading `]` can combine with a `content` that itself ends in `]` (e.g. any module ending `return t["n"]` — real and reachable) to form a premature closer. Both were silent at build time: the chunk was written and only failed to `load()` in the browser, with no Lua devtools to explain why. Fixed with an overlapping `find`-with-advancing-`init` scan over `content .. "]"`, plus a new mandatory `assert_chunk_loads` gate (a real `load()` call on every emitted chunk before it's written, chunk-level counterpart to `minify`'s existing per-module gate) so a future regression here fails the build with a named chunk id instead of shipping silently broken. Verified: reproduced the OLD implementation's failure on the `return t["n"]` case directly (`load()` → `unexpected symbol near ']'`), confirmed the fix resolves it, and re-ran the full M1/M3 pipelines (single-chunk and `split="entry"`) end-to-end with the fix in place — all chunks still build and load correctly in a fresh isolated process. `luajit tests/runner.lua`: 454/454.

**Method note:** written to this workspace's `CLAUDE.md` "Trust issue in `docs/`" rule. Every claim below is either backed by a command actually run read-only in this tree, or labelled **[UNVERIFIED]**. The two companion plans' load-bearing claims were independently re-verified rather than inherited — and two of them turned out wrong (see §3, §7).

---

## 0. Verification ledger (what was actually run)

| Question | Method | Result |
|---|---|---|
| Is wasmoon LuaJIT or Lua 5.4? | Extracted the real `wasmoon@1.16.0` tarball from the npm cache, `strings` on `package/dist/glue.wasm` | **PUC Lua 5.4.** `Lua 5.4` adjacent to `_VERSION`/`lua_version`; 5.4-only C API symbols present (`lua_toclose`, `lua_closeslot`, `lua_resetthread`, `lua_setwarnf`, `lua_warning`, `luaL_addgsub`, `luaL_typeerror`); zero LuaJIT markers |
| Does the hydronium client graph run on real 5.4? | Found a real `lua-5.4.9` PUC binary in the moonstone store; ran the full 22-module client graph under it | **Yes**, unbundled and bundled. `unpack` global is `nil` there — the `table.unpack or unpack` shim is genuinely load-bearing |
| Does `package_preload_v1` actually work? | Built the real 22-module amalgamation in-process, wiped `package.loaded`, set `package.path=""`/`package.cpath=""`, `load()`ed it | **Yes.** 125,923 B bundle; `hydronium_dom`, `hydronium.core.element`, `hydronium.core.reconciler` all resolve from the bundle alone; a real element constructs. Reproduced identically on LuaJIT and Lua 5.4.9 |
| Is a static `require("literal")` scan sufficient vs. the tracing-`require` oracle? | Ran both over the real client entry set and diffed | **Identical, 22 modules each. Zero missed, zero over-included** |
| Does the graph match what ships today? | Compared against `examples/meteorite_ssr/client_mount_demo/client_manifest.json` | **Exactly 22 entries, same ids.** (`HYDRONIUM_CLIENT_MOUNT.md` says "21 runtime modules" — the real manifest has 22.) |
| Is the `.luax` lexer sound on plain `.lua`? | Tokenized all 62 `.lua` files in `core/dom/luax/ink`, compared reconstructed source to original | **62/62 byte-identical round-trip, 0 lexer errors**, plus 18 adversarial comparison-operator snippets |
| Does bundling break the test suite? | Built a bundle of all core+dom+luax modules into `package.preload`, ran `tests/runner.lua` | **438 total, 437 passed, 1 failed** — the same pre-existing `lazy_barrel_spec` failure. Zero bundling-induced regressions |
| Does minification break it? | Same, with every module passed through the safe minifier first | **438 / 437 / 1 — identical** |
| Safe-minification savings on the real client graph | Measured bytes and gzip -9 | raw 124,935 B / 33,042 gz → safe 72,843 B (−41.7%) / 15,026 gz (−54.5%) |
| Do `luasrcdiet`/`LuaMinify` support 5.4? | WebFetch/WebSearch | luasrcdiet: states "Lua 5.1–5.3," self-describes as experimental, asks users to do their own equivalence checking. LuaMinify is 5.1/Roblox-lineage. Neither is 5.4-verified |
| Not run | — | `moon exec ballad -- play partiture.lua`, Playwright, any actual wasmoon execution (not installed in this workspace) |

---

## 1. Resolved: the two-VM questions

### 1.1 The browser VM is Lua 5.4 — settled, not a risk

`dom/src/hydronium_dom/client/mount.js:41` pins `wasmoon@1.16.0`, whose `glue.wasm` is a PUC Lua 5.4 build. **Any doc claiming wasmoon is "LuaJIT compiled to WASM" is wrong** and should be corrected.

Consequence: every hydronium package declares `abi = "5.1"`/`luajit 2.1.0`, so the client already runs 5.1-targeted source on a real 5.4 VM today, working only via compat shims — confirmed `unpack` is `nil` under 5.4.9, and all 18 files using `local unpack = table.unpack or unpack` survive amalgamation because each module body remains its own chunk/function scope. **Hard invariant on the minifier: never merge module scopes, never treat any global name as known-resolvable** — a file-scope local shadowing a same-named global is correctness-critical here, not incidental style.

### 1.2 LuaJIT bytecode is not an option — source-level bundling, full stop

`luajit -b` bytecode targets a different VM/format than PUC 5.4 and will not load in wasmoon. PUC 5.4 `luac` bytecode is theoretically loadable there **[UNVERIFIED]**, but recommended against regardless — it destroys the minifier, destroys `map_json`, destroys stack traces, for a parse-time saving that's noise next to a ~MB WASM instantiation. **Decision: source-level only, permanently.**

### 1.3 The VM lives exactly one page load — lazy chunk loading has no trigger

Verified: every boot site does `new LuaFactory(); await factory.createEngine()` — one fresh VM per `mount()` call. `dom/src/hydronium_dom/client/dev_reload.js:16` handles reload via `location.reload()` — a full page reload, destroying the VM even on HMR. `grep` for router/navigation patterns across the whole codebase → zero hits.

**There is no event in this architecture that could trigger "load another chunk later."** A page load needs its complete chunk set upfront. This doesn't make splitting worthless — it changes what it's *for*: (1) cross-page HTTP cache reuse of an immutable, content-hashed shared runtime chunk (the real win — the framework runtime is ~90% of the bytes and changes only on a framework upgrade), and (2) not shipping island B's code to a page with only island A. It does **not** buy JS-style lazy `import()` — anyone writing that into a hydronium doc is wrong until a router exists. `hydrate = "load"|"visible"` deferral is a `mount.js` (WASM-instantiate-timing) concern, not a bundler concern — do not conflate them.

---

## 2. `format = "package_preload_v1"` — the exact spec

Two candidate shapes were tested. **Form A** (inline nested closures, module body pasted directly into `function(...) ... end`) destroys module identity and line numbers in every stack trace (`bundleA:44: kaboom` vs. real module+line). **Form B** (deferred `load()` of raw source held in a long-bracket string) preserves both exactly (`demo.mod:3: kaboom`) and keeps `map_json` valid with zero remapping. **Decision: Form B.**

```lua
local _load = loadstring or load
local _assert, _pairs, _require, _preload = assert, pairs, require, package.preload
local S, A = {}, {}

S["hydronium.core.element"] = [==[
<verbatim module source, byte-for-byte>]==]
-- one entry per module_id, sorted order

A["hydronium_dom.dom.init"] = "hydronium_dom.dom"   -- init-path aliases, see 2.4

for id, src in _pairs(S) do
  _preload[id] = function(...) return _assert(_load(src, "@" .. id))(...) end
end
for a, id in _pairs(A) do
  _preload[a] = function() return _require(id) end
end
```

Five details, each hit for real during verification:

1. **`local _load = loadstring or load`** — same compat-guardrail pattern as `unpack`; the bundle must run on both 5.1/LuaJIT SSR and Lua 5.4 browser.
2. **Every global the loaders need is captured as a local, before any user code runs.** A first attempt crashed with `attempt to call global 'assert' (a table value)` once a global `assert` was shadowed — not test-only: `core/src/hydronium/core/family_loader.lua` replaces `_G.require` for HMR. Capture `assert`/`pairs`/`require`/`package.preload`/`load`.
3. **`"@" .. id` as the chunkname** — renders errors as `hydronium.core.element:87:` rather than `[string "hydronium.core.element"]:87:`. `mount.js` today omits the `@`; the bundler adds it.
4. **The long-bracket level is computed per module**, `1 + max{n : body contains "]"..("="):rep(n).."]"}`, with a leading `\n` after the opening bracket (Lua discards it, so the body's line 1 stays line 1).
5. **`load()` is deferred into the loader closure** — a module carried by a chunk but never `require`d is never parsed. The only real "lazy" in this architecture, and it's free.

### 2.3 The `mount.js` change

```js
for (const url of chunkUrls) {           // manifest order; `requires` is already topological
  const src = await (await fetch(url)).text();
  lua.global.set("__hy_chunk_src", src);
  await lua.doString('assert(load(__hy_chunk_src, "@' + chunkName + '"))()');
}
```

**Do not interpolate chunk source into a JS template literal** — it contains `]==]`, backticks, `${` sequences. Pass as a global string, `load()` it Lua-side — the same pattern `mount.js` already uses for props, for the same documented reason (the automatic marshaller isn't trusted). Request count for M1: **2 counted fetches (1 chunk + 1 wasm)** vs. today's 25 — meets the ≤3 target with margin.

### 2.4 Two amalgamation hazards, both must be encoded in `resolve`

**Hazard 1 — no `?.lua`/`?/init.lua` equivalence in `package.preload`.** `dom/src/hydronium_dom/init.lua` is `return require("hydronium_dom.dom.init")`; `package.path` resolves both `hydronium_dom.dom` and `hydronium_dom.dom.init` to the same file, `package.preload` does not (confirmed: the shipped manifest uses `hydronium_dom.dom.init`). **`resolve` must emit alias entries for every `init.lua` module, registering both ids**, with the alias loader deduplicating via `require(id)` rather than re-executing (noting the on-disk behavior today actually double-instantiates these — a latent hydronium bug worth its own look, not this plugin's to fix).

**Hazard 2 — modules that self-locate via `debug.getinfo(1,"S").source` cannot be amalgamated** (chunkname changes from `@dom/src/.../x.lua` to `@hydronium_dom.x`). Three real modules do this (`ink/src/hydronium_ink/yoga_ffi.lua`, `luax/src/hydronium_luax/plugin.lua`, `luax/src/hydronium_luax/luals/init.lua`); none is client-reachable today, but this must be an **enforced deny-list with a build diagnostic**, not a runtime browser surprise. `resolve` scans candidate modules for `debug.getinfo` and refuses to bundle them by name.

---

## 3. Method contracts — refined, with one deliberate deviation from the architecture doc

```lua
name    = "hydronium_ballad.plugins.client",
version = "0.1.0",
methods = {
  resolve = { inputs={"asset_set"}, outputs={"asset_set"}, cacheable=false, parallel_safe=true },
  bundle  = { inputs={"asset_set"}, outputs={"asset_set"}, cacheable=true,  parallel_safe=true },
  minify  = { inputs={"asset_set"}, outputs={"asset_set"}, cacheable=true,  parallel_safe=true },
}
```

**`resolve` is `cacheable = false` — a deliberate, verified correction to the architecture doc's `cacheable = true` sketch.** Reading `ballad/src/ballad/cache.lua`: `cache.compute_key` hashes `{cache_version, plugin, method, plugin_version, options, controls, input_hashes}`, and `hash_asset` hashes `source_path` or `content` — **`asset.metadata` is never hashed.** Every join key `resolve` depends on (`module_id`, `target`, `origin`) lives in metadata. Flip a partiture's `target` from `"server"` to `"client"` on unchanged content, and `resolve`'s cache key is unchanged — a **silently stale module set**, a wrong-output failure, not a slow one. `resolve` is also cheap (well under a second for 22 modules), so paying for it every run is obviously correct.

`bundle`/`minify` stay `cacheable = true` and are sound — **conditional on a new requirement**: `resolve` must emit an additional `kind = "hy_module_graph"` asset whose `content` is a canonical JSON serialization of the whole resolution result (sorted module ids, content hashes, edges, entries, aliases, chunk assignment). With that asset in the set, `bundle`'s cache key transitively covers everything that determines its output, since the graph asset's *content* changes whenever any join key does.

**Other verified cache facts constraining the design**: `serialize()` errors on any function-valued option — no callbacks, ever, in any option to any of these three methods, only plain data (string enums, lists). Input order affects the cache key with no sort applied by ballad — `bundle` must sort module ids itself before emitting, or the hash in `virtual_path` is unstable across machines. `process.b3sum_string` shells out to a real `b3sum` binary via a temp file, and `process.capture` returns `""` on `popen` failure — **on a machine without `b3sum`, every asset hashes to the empty string and every cache key collapses, a catastrophic silent-wrong-cache-hit landmine in ballad core, not just here.** This plugin should assert `b3sum` availability at method entry and fail loudly otherwise, and use `ballad.process.b3sum_string` for its own chunk-hashing too (one hash implementation, not two). `source.files` assigns the **same metadata table reference** to every asset it produces — never mutate an input asset's metadata in place; always build new assets via `ctx.graph:add_asset`.

`parallel_safe = true` is correct but means little: `Pipeline:execute` is a single sequential loop over topological order; `parallel_safe` only gates flushing pending *native subprocess* tasks. There is no in-process parallelism to design for.

**Bonus finding — resolves the architecture doc's open question #5 (`depends_on` vs. `inputs_from_entries`), and finds its own partiture sketch broken.** Reading `PluginProxy.new`'s argument dispatch: passing an *array* of NodeHandles as a method's first argument does **not** work as the architecture doc's §3.5 sketch (`luax.compile({ client_src, server_src }, {...})`) assumes — with two args it inserts the raw table where a node id is expected; with one arg it's treated as the options table. **`depends_on` does work** (appends handle ids to `node.inputs`, and `execute` builds `input_results` from those in order). **Recommendation: use `depends_on` everywhere a method needs multiple upstream AssetSets** — a correction for whoever implements `site.manifest` and any other multi-input method in this system.

### 3.1 Option shapes (plain data only)

```lua
client.resolve(compiled, {
  entries      = { "app.client.root" },   -- required; module ids, not paths
  include      = { "client", "shared" },  -- metadata.hydronium.target values to consider
  deny_getinfo = true,                    -- refuse to bundle chunkname-dependent modules
})

client.bundle(resolved, {
  split           = "none" | "entry",     -- "none" for M1
  shared_chunk_id = "runtime",
  hash_length     = 8,
  chunk_prefix    = "client/",            -- virtual_path prefix; this IS the URL prefix
})

client.minify(chunks, {
  level          = "none" | "safe",       -- "safe" is the only level that ships
  preserve_lines = true,                  -- default true; see §4.3
})
```

---

## 4. The minifier

### 4.1 Hard invariant

**The minifier must never alter, rename, re-quote, re-encode, or otherwise touch the contents of any string literal — not just table keys, any string literal, full stop.** `luax.compile` mints CSS scope classes (e.g. `"hy-App-1a2b"`) as literal string constants in compiled Lua; rewriting string contents silently detaches a component from its stylesheet, and the failure mode ("the page renders unstyled") isn't caught at compile time. This subsumes `BUNDLING.md`'s narrower "Table Key Protection" caveat — a minifier that never touches string literals or renames non-local identifiers cannot rename a table key, since a public property name is either a string literal or a field-access identifier.

### 4.2 Recommendation: build on this codebase's own lexer — do not adopt luasrcdiet or LuaMinify

1. **The lexer is a lossless, raw-text-preserving tokenizer, verified on this exact corpus.** `Lexer:read_string`/`read_comment` store the raw source text including delimiters — emitting `tok.value` verbatim satisfies the string-literal invariant *by construction*, a stronger guarantee than "we configured a third-party tool with string preservation on." 62/62 real `.lua` files round-trip byte-identically; the one theoretical concern (a modal lexer mistaking a `<` comparison for a JSX tag) provably cannot occur, since `can_start_jsx` only returns true after tokens that can't end an expression, and `<` is strictly infix in valid Lua. Confirmed with 18 adversarial snippets.
2. **luasrcdiet is 5.1–5.3 only and self-describes as experimental**, explicitly asking users to do their own equivalence checking. Disqualifying on its own given the 5.4 target.
3. **A new dependency for a saving already achievable without one.** The codebase has zero non-stdlib Lua dependencies anywhere by design.
4. **Measurement makes local-variable renaming a bad trade.** Whitespace/comments alone: −41.7% raw, −54.5% gzipped (hydronium is heavily commented — the comments *are* the bytes). Renaming needs a full scope-resolving parser, risks breaking shadowing shims, and chases a small residual. **Ship `level="safe"` and stop**; revisit only with a measurement showing the remaining bytes matter next to a ~MB WASM download.

### 4.3 `level = "safe"`, precisely

Tokenize with whitespace/comments included, emit every non-trivia token's raw value, replace each trivia run with a minimal separator. Two variants measured on the real 22-module client graph:

| variant | rule | bytes | gzip -9 | compile failures | line drift |
|---|---|---:|---:|---:|---|
| raw | — | 124,935 | 33,042 | — | — |
| collapse | trivia run → one `\n` | 72,843 (−41.7%) | 15,026 (−54.5%) | 0/22 | total |
| **line-preserving** | trivia run → same `\n` count, or one space if none | **74,084 (−40.7%)** | **15,536 (−53.0%)** | **0/22** | **none** |

**Decision: line-preserving is the default (`preserve_lines = true`)** — costs 1.7%/3.4% extra bytes in exchange for `map_json` staying valid with zero remapping and every stack-trace line number staying accurate, an obviously good trade for a framework whose only browser debugging instrument is a stack trace.

**Mandatory per-module gate**: after minifying, `load(minified, "@" .. id)` must succeed, or the build fails naming the module and the parser error. Not theatre — this caught 21/22 modules instantly during a debugging session for a subtly-wrong first implementation. Unconditional, not opt-in.

**Explicitly and permanently out of scope for `level="safe"`**: string-literal rewriting, table-key renaming, global identifier renaming, local-variable renaming, constant folding, dead-code elimination, and **tree shaking** (unsound here — `family_loader` manipulates `package.loaded`/wraps `_G.require` at runtime, and `server/init.lua` reaches a module through an `__index` metamethod; assume zero tree shaking, forever).

---

## 5. Splitting (M3), and a blocking gap in `client_plan`

### 5.1 The gap: `client_plan` v1 does not carry a Lua module id

`render_state.client_plan` (`dom/src/hydronium_dom/server/init.lua`) is the real, already-computed per-page island enumeration, returned as `renderToString`'s second value. Island entries include `module` — but `d.lua.mount(vnode)` passes no `module` prop at all (confirmed: `dom/src/hydronium_dom/dom/init.lua`'s `createElement(lua_island, {root=true}, vnode)` call has no such field, and the existing suspense/islands test only asserts `module` for the **js** island, nothing for the lua one).

**`client_plan` enumerates which islands a page has, but not which Lua module each one is** — the one field splitting needs is missing.

**Prerequisite for M3, a `hydronium-dom` change, not a bundler change**: teach `d.lua.island`/`d.lua.mount` to accept a `module` prop recorded verbatim into the plan entry, symmetric with the js path. (Rejected alternative: deriving the id from `debug.getinfo` on the component function — breaks precisely when bundling is on, since chunknames change under amalgamation.)

### 5.2 The algorithm

Build-time, no SSR execution needed: for each entry module `e` (from `opts.entries` in M1/M2, or from a `hy_client_plan` asset's Lua islands in M3), compute the reachable set `R(e)` via the static `require("literal")` scan; a module reachable from ≥2 entries, or matching a `shared_roots` prefix (`hydronium.`, `hydronium_dom.`), goes into a shared `"runtime"` chunk; a module reachable from exactly one entry goes into that entry's own chunk (`requires = {"runtime"}`). Sort module ids within each chunk, content-hash it, assign `virtual_path`. The `shared_roots` prefix rule matters more than the refcount rule — it pins the framework runtime into one immutable, cacheable chunk even on a single-entry site, which is where the real cache win lives. Emit chunks in `requires`-topological order in the manifest.

### 5.3 The coupling risk

Anchoring on `client_plan` inherits: a `v1` version string that will change; the missing `module` field (§5.1, must land first); and a structure only produced during a real SSR render — meaning a static-export build (Mode A, the *earliest* target per the architecture doc) has no `client_plan` at all unless it prerenders. **The milestone that most wants splitting is the one least able to produce the input splitting is anchored on.** Mitigation: `bundle` accepts either an explicit `opts.entries` list or a `hy_client_plan` asset as the same internal shape, and asserts `plan.version == "hydronium.client-plan.v1"`, failing loudly rather than silently mis-splitting on drift. This is also the strongest argument in the whole initiative for `hydronium-ballad` staying an in-tree workspace member rather than a published external package — it consumes two unfrozen internal contracts.

---

## 6. Correctness verification strategy — designed and already demonstrated

**Technique**: substitute the bundle for the filesystem underneath the real, unmodified test suite. `package.preload` is searcher #1 in both 5.1 and 5.4, winning over `package.path` unconditionally — so building the `hy_chunk` set, `load()`ing/running each chunk to populate `package.preload`, then handing control to `tests/runner.lua` unmodified makes every `require("hydronium.*")`/`require("hydronium_dom.*")` in all 438 specs resolve through the bundle, no spec modified, no mock introduced.

**Result, run for real**: baseline 438/437/1 (the known `lazy_barrel_spec` failure) → bundled: 438/437/1, same failure → bundled+minified: 438/437/1, same failure. **Zero regressions from bundling or minification.**

Becomes three CI gates: **G1** (bundle equivalence — identical pass/fail *set*, comparing sets so the known PATH issue doesn't mask a real regression), **G2** (minify equivalence, plus the unconditional per-module `load()` gate), **G3** (keep `gen_client_manifest.lua` as a verification oracle — assert the static scan is a superset of the dynamic trace; exact match confirmed for the client entry set, 22=22, though the codebase does contain one computed `require` behind an `__index` metamethod, server-side and outside the client graph today — G3 is what keeps that true as code moves). Two more require Playwright: **G4** (the real-browser M1 proof, ≤3 requests) and **G5** (a Lua 5.4 dialect gate — run G1/G2 under real PUC `lua-5.4.9`, which also fixes the long-standing `lazy_barrel_spec` PATH failure for free, since it needs exactly the same binary).

---

## 7. Milestones

**M1** — `resolve` (filter `target ∈ {client, shared}`, key exclusively on `module_id`, read `content` never `source_path`, static `require` scan, enforce the `debug.getinfo` deny-list, emit the `hy_module_graph` asset, `cacheable=false`) + `bundle` (one `hy_chunk`, `package_preload_v1`, sorted module ids, pass `sourcemap` through untouched) + the `mount.js` change (delete the old 22-fetch preload-synthesis loop). Gates: G1, G3, G4. **Success metric: 2 counted requests vs. today's 25.**

**M2** — `minify` (`level="safe"`, line-preserving, lexer-based, per-module `load()` gate). Gates: G2, G4 re-run with minification on. Ship nothing more aggressive.

**M3** — `client_plan`-anchored splitting. Prerequisite: the `module` prop on `d.lua.island` (a hydronium-dom change, not this plugin's). Then `bundle` gains `split="entry"` per §5.2, asserts `plan.version`, documents plainly that this buys cache reuse and per-page exclusion, not lazy loading.

---

## 8. Risks and open items

**Verified-real risks**: `b3sum` absence silently collapses ballad's entire cache (a ballad-core landmine, assert-and-fail here); ballad's cache never hashes `metadata` (root cause of the `resolve` cacheable=false decision — anyone adding a fourth method must re-derive this, not copy a sibling's `cacheable=true`); `source.files` shares one metadata table across all its assets (never mutate in place); `sink.directory` does `remove_tree` first (one sink per output tree); `client_plan` is v1/SSR-only and missing the field M3 needs; `debug.getinfo` self-location is fundamentally incompatible with amalgamation (three modules do it today, none client-reachable — luck, not design, until the deny-list ships); the architecture doc's §3.5 partiture sketch doesn't work as written (arrays of NodeHandles aren't valid multi-input — use `depends_on`); `HYDRONIUM_CLIENT_MOUNT.md`'s "21 runtime modules" is off by one (real count: 22).

**Could not verify**: wasmoon was never actually run (not installed in this workspace) — the Lua-5.4 conclusion rests on strong static evidence (wasm binary strings/symbols) plus execution against a faithful but non-identical PUC 5.4.9 stand-in; wasmoon-specific `load`/`loadstring` quirks are genuinely unknown. The cheapest way to close this: `await lua.doString("return _VERSION")` in the existing proof page, plus loading a long-bracket-heavy chunk — do this in M0. Ballad itself was never run (no `moon exec ballad -- play partiture.lua`, no `moon sync`, no Playwright) — pipeline *behavior* claims are read from source, not observed. `p:use("hydronium_ballad.plugins.client")` resolving at all is unproven (gated on the architecture doc's M0 item 3). Whether PUC 5.4 `luac` bytecode would load in wasmoon, and whether luasrcdiet is resolvable via moonstone's LuaRocks bridge, were both left untested as moot given the decisions above.

---

## Critical files for implementation

- `dom/src/hydronium_dom/client/mount.js` (lines ~119–148 are deleted in M1) — the loader this replaces
- `luax/src/hydronium_luax/lexer.lua` — the minifier's entire front end (`read_string`/`read_comment` raw-text storage, `can_start_jsx`'s soundness on plain Lua)
- `dom/tools/gen_client_manifest.lua` — the tracing-`require` technique `resolve` reimplements statically, and gate G3's oracle; do not delete
- `dom/src/hydronium_dom/server/init.lua` — `client_plan` construction and the missing `module` field blocking M3
- `ballad/src/ballad/cache.lua` — `hash_asset` not hashing metadata, `serialize` rejecting functions: the two constraints shaping every method contract here
- `meteorite/src/ballad/init.lua` — structural template, and (via its own self-location pattern) a cautionary example of hazard 2 above

**External sources consulted**: [jirutka/luasrcdiet](https://github.com/jirutka/luasrcdiet), [LuaSrcDiet on LuaRocks](https://luarocks.org/modules/jirutka/luasrcdiet), [stravant/LuaMinify](https://github.com/stravant/LuaMinify)
