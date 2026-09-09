# Hydronium × Ballad: `.luax` compile, CSS, and static-asset pipeline

**Companion doc**: `docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md` (overall package-boundary decision, milestone sequencing, and the plugin/AssetSet contract this plan implements one branch of). Also see `docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md` for the `hydronium_ballad.plugins.client` side this hands compiled modules to.
**Produced by:** an Opus 5 planning agent, as part of the "deploy a whole reactive webpage" long-horizon initiative. Investigated 2026-09-08, read-only, against the live hydronium working tree.

---

## Implementation status (2026-09-09)

**Section 2 (Styles) — implemented and verified live, real CSS in, real scoped CSS out.**

- `dom/src/hydronium_dom/css/init.lua` (`hydronium_dom.css`): `scope_class(path, class)` and `sheet(path)`, exactly as designed in section 2.2/2.3 below, with one real deviation worth flagging: the scoping hash is **not** FNV-1a as originally specified, but a DJB2-style pure `+`/`*`/`%` polynomial hash. Reason, found while implementing: this module is required both server-side (LuaJIT/PUC 5.1-5.4) and client-side (real Lua 5.4 inside wasmoon, confirmed in `docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md`'s own investigation) — Lua 5.4 has *native* bitwise-operator syntax that is a parse error on 5.1/LuaJIT, and LuaJIT's `bit` library doesn't exist on plain PUC 5.4, so there is no bitwise-XOR expression parseable on every target this codebase's own compatibility matrix requires. A pure-arithmetic hash sidesteps this entirely; collision resistance needs are "don't collide within one file's own class list," not cryptographic.
- `dom/src/hydronium_dom/css/reset.css`: a real, hand-written ~40-line reset (not vendored normalize.css, per the zero-dependency invariant).
- `build/src/hydronium_ballad/plugins/style.lua` (`hydronium_ballad.plugins.style.bundle`): a real single-pass CSS class-selector rewriter (comments/strings/`:global(...)` all correctly protected, verified with a fixture exercising every one of those cases at once) using the *exact same* `scope_class` function as the runtime module, so build-time and runtime scoping provably agree with zero coordination beyond both requiring `hydronium_dom.css`. Locates its sibling `reset.css` via `package.searchpath("hydronium_dom.css", package.path)` rather than a relative-path guess, since hydronium-ballad and hydronium-dom aren't guaranteed to be siblings on disk.
- **Verified live**: a real fixture stylesheet (reused class across 3 selectors, a pseudo-class, a comment containing a fake class name, a quoted string containing a fake class name, an attribute selector with a quoted `.`, and a `:global(...)` escape) run through `style.bundle` both via direct plugin calls AND through a real `ballad play` pipeline — every case handled correctly: consistent scoping across repeated selectors, `:global()` unwrapped to unscoped output, comments and strings byte-for-byte untouched, reset.css correctly prepended. `dom/src/hydronium_dom/css`'s own runtime `sheet()` output independently confirmed to match the build-time rewrite for the same file+class. 8 new regression specs in `tests/host/css_spec.lua`. Full suite: 448/448.

**Section 3 (static assets) and section 4 (manifest merge) — also implemented and verified live.**

- `build/src/hydronium_ballad/plugins/assets.lua` (`hydronium_ballad.plugins.assets.hash`): real content-hashing (`ballad.process.b3sum`, hashing the FILE directly, never reading it into a Lua string) into `assets/<stem>.<digest10>.<ext>`, `source_path` preserved so the real sink takes the `fs.copy_file` branch. Verified with a real binary-like fixture file: emitted output is **byte-for-byte identical** to the source (`diff` confirmed), and hashing is deterministic across separate runs.
- `dom/src/hydronium_dom/assets.lua` (`hydronium_dom.assets`): `configure(manifest_path)` / `url(source_path)` / `reset()`. Same "pure call, zero new syntax" authoring model as `hydronium_dom.css`, but — unlike CSS scoping — this genuinely needs a real manifest lookup (a content hash can't be computed without the file's own bytes), with an explicit one-time `configure()` rather than any automatic path discovery. 5 new regression specs in `tests/host/assets_spec.lua`, covering the pre-configure dev fallback, a real configured manifest, an unknown path within a configured manifest, a nonexistent manifest path degrading gracefully (not erroring), and `reset()`.
- `build/src/hydronium_ballad/plugins/site.lua` (`hydronium_ballad.plugins.site.manifest`): the real merge node section 4 describes. Passes every input asset through unchanged (additive, not exclusive) and emits `hydronium-manifest.json` (via `dkjson`, a real ballad-provided dependency) and `hydronium-manifest.lua` (a hand-rolled Lua-table-literal serializer, matching `dom/tools/gen_client_manifest.lua`'s own established zero-dependency reasoning) side by side.
- **Verified live**, both via direct plugin calls and a real `ballad play` run: a real (fake-content) PNG plus a real stylesheet, hashed/bundled/merged into one manifest, sunk to a real `dist/` directory. The emitted `assets/logo.<hash>.png` is byte-identical to the source (`diff` confirmed against the real sink output, not just the in-memory `Asset`). `hydronium_dom.assets.configure()` pointed at the real emitted `hydronium-manifest.lua` resolves the exact same URL the build produced. Full suite: 453/453.

**Still not implemented, explicitly**: the `css.Styles` component (section 2.5/2.6 — an app currently has to write its own `<link href={...}>` using the manifest's `styles.url` field directly, which works today but isn't the ergonomic helper the plan describes), the generated `.d.lua` LuaCATS class types (section 2.4), and merging compiled-module/require-graph info into this manifest (deliberately deferred — `hydronium_ballad.plugins.client` already has its own real per-chunk manifest concept from the bundler plan's "Contract 5," and reconciling the two shapes needs a real design pass, not a guess made here).

---

## 0. What was verified (and where the brief was wrong)

**Confirmed true:**

- **Zero styling system.** Zero `.css` files anywhere in `hydronium` (`find . -name "*.css"` → empty). `examples/showcase/Header.luax` and `App.luax` write `class="hero-title"`, `class="nav-link active"`, `class="showcase-header"` with **no stylesheet anywhere defining them** — the showcase renders as unstyled HTML with dangling class names. `examples/meteorite_ssr/views/App.luax` inlines ~25 CSS rules as a Lua long string inside `<style>{[[ ... ]]}</style>`. Inline `style={{...}}` prop tables appear in `App.luax:22-26` and `InteractiveIsland.luax:14,23,35`.
- **Zero asset-import mechanism.** No hashed filenames, no manifest, no URL resolution. The only static serving is `meteorite.site` in `examples/meteorite_ssr/src/main.lua` pointed at raw source directories.
- **Zero client-side style handling.** `grep -n "style\|link\|css" dom/src/hydronium_dom/client/*.js` → no hits at all across `bootstrap.js`, `mount.js`, `dom_bridge.js`, `boundary_registry.js`, `dev_reload.js`, `dev_transport.js`.
- **Ballad has no working transform plugin.** `src/ballad/plugins/lua.lua` is 26 lines; both method bodies are `error("... not yet implemented")`.
- All four hydronium partitures do registry packaging only, all via `p.sink.artifact(artifact, { out = "dist/registry", product = "package" })`.

**Corrections to the original brief:**

1. **`hydronium_luax.compile` has no `sourcemap` option.** Real signature (`luax/src/hydronium_luax/compiler/init.lua:766`): `compile(source_or_ast, options)` where options include `filename`, `runtime` (`"hydronium"|"starship"|"direct"|"universal"|"custom"`), `development`, `inline_sourcemap`, `output_filename`, `env`, `pragma`/`jsxFactory`, `jsxFragment`, `jsxSpread`, `h`, `fragment`, `bare_tag_alias`, `virtual_luals`. It always returns `{ code, sourcemap, map_json, bare_tags_without_alias }`. `inline_sourcemap` only appends `map:to_comment()`, which is a raw (non-base64, non-URI-encoded) `--# sourceMappingURL=data:application/json;charset=utf-8,{...}` line (`sourcemap.lua:244`).
2. **`luax/src/hydronium_luax/plugin.lua` is not a compiler extension point** despite the name — it is the LuaLS `OnSetText`/`ResolveRequire` plugin.
3. **There is already a shared serve-time loader**: `luax/src/hydronium_luax/loader.lua` (`hydronium_luax.load_luax`), mtime-cached, whose doc comment explicitly says it generalizes the ad-hoc `load_luax` in `examples/meteorite_ssr/src/views/App.lua` and that "every hydronium app should require THIS." The SSR example has not migrated to it. This materially changes the dev/prod framing (§2).
4. **`CLAUDE.md` itself is stale** on hydronium's layout — it documents `src/hydronium/luax/`, but the real layout is the four sibling packages. Consistent with its own warning about self-certifying docs; `docs/BUNDLING.md` is likewise stale (documents a `dist/hydronium.lua` amalgamation and a `src/hydronium/init.lua` entry that don't exist) and contains zero mentions of css/asset/manifest, so there is no prior spec to conflict with.

**Ballad facts verified by reading the real installed source** (`~/.local/share/moonstone/store/v0/.../ballad-0.3.7/files/libexec/ballad`):

| Fact | Evidence |
|---|---|
| A plugin may be a **plain table passed to `p:use(...)`**, registered under its `.name`; it does not have to live inside `ballad/plugins/`. | `plugin_host.lua` `Host:resolve` — table branch |
| `ballad play --lua-path <dir>` exists ("Prepend a pure-Lua module root before loading the partiture (repeatable)") | `ballad --help`; `cli.lua:164,296,326` |
| Under `moon exec`, path deps materialize onto `LUA_PATH`. **Verified live**: `moon exec -- luajit -e 'print(pcall(require,"hydronium"))'` in `ink/` → `true` | direct run |
| `sink.directory` calls **`fs.remove_tree(out_dir)` first** | `pipeline.lua` `core_handler` directory branch |
| `p.sink.directory(input, opts)` accepts **exactly one** node handle and **ignores `depends_on`** — only `PluginProxy`-dispatched methods honor `depends_on`, appending handles to `node.inputs` | `pipeline.lua:381`, `647-680`, `236-250` |
| `input_results` is an array of AssetSets in `node.inputs` order; `collect_input_assets` flattens all, skipping `kind == "files"` markers and bare `kind == "project"` assets | `Pipeline:execute`, `collect_input_assets` |
| `Pipeline:plan()` **errors** on any transform leaf that doesn't reach a sink ("dangling transform leaf node(s)") | `pipeline.lua:1574-1580` |
| Cache keys hash input file content via `b3sum` and include `node.options` + `contract.version`. Generated content-only assets round-trip through the cache | `cache.lua` `hash_asset`, `cache.store`, `cache.outputs_valid` |
| `process.b3sum_string` **writes a temp file and forks `b3sum` per call** | `process.lua:190-201`. `b3sum` present at `/opt/homebrew/bin/b3sum` |
| `--report` output lists only the *sink summary* asset per sink — **not** an asset manifest | `cli.lua:71-125` |
| `p.sink.directory(input, { file_graph = true })` writes a real per-file `file-graph.json` including each asset's `metadata` | `core_handler` directory branch + `file_graph_for` |
| Three **mutually inconsistent** glob implementations exist: `pipeline.lua:1275` (`*`→`[^/]*`), `cache.lua:120` (`*`→`[^/]+`), `conventions.lua:66` (`*`→`[^/]*`, `**`→`.*`). In `pipeline`'s, `"**/*.luax"` does **not** match a top-level `App.luax` | direct read |
| `conventions.tree(...)` is only consumed by `conventions.source_package` for registry `collect` entries — not a general file-collection source. Real primitives are `p.source.files(patterns, {root})` / `p.source.directory(path)` | `conventions.lua` `expand_collect` reachable only from `source_package` |

**Package-boundary assumption**: per the companion architecture doc, a new sibling package `hydronium/ballad/` (`hydronium-ballad`), modules under `src/hydronium_ballad/`, plugins at `hydronium_ballad.plugins.{luax,style,assets,manifest}`. Only the `require` path in partitures changes if that decision differs — ballad resolves plugins by table identity + `.name`, and both `--lua-path` and a normal path-dependency get the module onto ballad's `LUA_PATH`.

---

## 1. The `.luax`-compile ballad plugin

### 1.1 Contract

```
name    = "hydronium.luax"          -- stable; node.plugin stores this string
version = "0.1.0+" .. require("hydronium_luax")._VERSION
methods = {
  compile = { inputs = {"asset_set"}, outputs = {"asset_set"},
              cacheable = true, parallel_safe = true },
}
```

- `parallel_safe` does **not** mean ballad forks — nodes run strictly serially; `parallel_safe = false` only forces a `flush_pending_tasks()` (pending native subprocess tasks) before the node. Pure in-process Lua compilation is safely `true`.
- `cacheable = true` genuinely works: keys hash each input's `source_path` content. **But it's a footgun**: `contract.version` is the only thing that invalidates on a *compiler* change, and deriving it from `hydronium_luax._VERSION` is necessary but insufficient (that string is hand-maintained, `"0.1.0"` today). Give the plugin a `cache_salt` option CI/local dev can bump; recommend compiler-development runs use `cacheable = false` via the per-node `options.cacheable` override (verified: `PluginProxy` reads `options.cacheable` and overrides the contract default).

### 1.2 Behavior

Input: AssetSet of `kind = "file"` assets, `virtual_path` ending `.luax`. Per asset:

1. Read `asset.source_path`.
2. `pcall(luax.compile, source, opts)` with `opts = { filename = asset.source_path, runtime = "hydronium", development = false, output_filename = <out>.lua }` merged over `node.options.compile`. On failure → `ctx.fail(...)`.
3. If `result.bare_tags_without_alias` is non-empty → `ctx.warn(...)` naming the file and tags — a real existing compiler output nothing currently consumes at build time, directly serving the bare→lexical tag migration `CLAUDE.md` calls out as still open. Make it an opt-in error via `opts.strict_tags = true`.
4. Emit the compiled asset (shape matches Contract 1 in the architecture doc):

```lua
ctx.graph:add_asset{
  kind = "generated", generated = true,
  content       = result.code,
  virtual_path  = asset.virtual_path:gsub("%.luax$", ".lua"),
  metadata = { hydronium = {
    kind    = "lua_module", origin = "luax", source = asset.source_path,
    module_id = <virtual_path minus .lua, "/"→".">,
    requires  = <static AST scan, see 1.4>,
    styles    = <css.sheet("...") literals found>,
    assets    = <assets.url("...") literals found>,
    sourcemap = <sibling map virtual_path or nil>,
  }},
}
```

5. Sourcemaps — `opts.sourcemap ∈ {"none","inline","external"}` (default `"external"` for `dist`, `"none"` for registry packaging):
   - `inline` → pass `inline_sourcemap = true` to `luax.compile`.
   - `external` → emit a second generated asset `<name>.lua.map` with `content = result.map_json`, and append `"\n--# sourceMappingURL=" .. basename .. ".lua.map\n"` to the code asset. **Do not** use `sourcemap:to_comment()` for this — it inlines a raw, un-URI-encoded data URI, fine for a dev one-off, wrong for a dist artifact.

### 1.3 The dev-vs-build fork — real, and resolved

The tension is real and today's compile-on-request behavior is deliberate and load-bearing:

- `examples/meteorite_ssr/src/views/App.lua` recompiles `views/App.luax` on every request. `src/main.lua`'s route-8 comment states this explicitly: *"views/App.luax is compiled fresh by src/views/App.lua's load_luax on every require, and Meteorite's hybrid runtime creates a fresh Lua state per request"* — and the `/__hydronium/watch` SSE endpoint watches `views/App.luax` by name to drive live reload. Making the ballad plugin the only compile path breaks that loop.
- `hydronium_luax.loader` (mtime-cached) already exists as the intended generalization; the example just hasn't migrated.

**Resolution: keep both paths, and remove the fork from application code entirely via a module-id convention plus a `package.searchers` shim.**

- **Convention**: `src/views/App.luax` ⇒ module id `views.App` ⇒ built output `dist/views/App.lua`. One rule, used by the compile plugin (`virtual_path` → `module_id`) and the dev searcher (`module_id` → candidate `.luax` path).
- **New, ~15 lines**, in `luax/src/hydronium_luax/loader.lua`: `loader.install(opts)` appends a searcher to `package.loaders`/`package.searchers` mapping `views.App` → `views/App.luax` under configured roots and returning `loader.load(path)`'s result (already mtime-cached compile+`load`+run).
- **Application code says `require("views.App")` in both modes.** Dev: no `.lua` exists, searcher fires, compile-on-demand, live editing works, `/__hydronium/watch` keeps working unchanged. Prod: `ballad play` emitted a real `dist/views/App.lua`, ordinary `package.path` finds it first, the searcher never fires, `hydronium_luax` isn't required at runtime at all.
- Meteorite caveat (already documented in `src/main.lua`'s header): hybrid mode lifts each inline handler into a fresh state, so `loader.install()` must be called from a module the handler `require`s (e.g. a tiny `src/dev.lua`), never a `main.lua` top-level local — the same constraint that forced `views/App.lua` to exist in the first place.
- **Non-divergence guard**: both paths must call `hydronium_luax.compiler.compile` with identical options (`{ runtime = "hydronium", development = false }`). Add a test asserting the plugin's output for a fixture `.luax` file is byte-identical to `loader`'s.

Mirror-image fork on the serving side, which corroborates the design: route 9's comment in `src/main.lua` records a verified-live finding that `meteorite.site` bakes file content at graph/build time — editing a static asset after a build doesn't change what's served until a rebuild. Exactly right for content-hashed immutable production assets, exactly wrong for dev. Same fork, same reason.

### 1.4 What the compile step hands off (for the minifier/bundler plan)

**In-memory `content` on a `kind = "generated"` asset. No temp files, no real paths.** `write_asset_to_directory` branches on `asset.generated and asset.content` **before** `source_path`, so content-only assets materialize correctly at the sink; `cache.store` persists `content` into the cache entry JSON, surviving cache hits. A minifier is therefore a pure `AssetSet → AssetSet` transform inserted between compile and sink, reading `asset.content` and returning assets with the same `virtual_path` — zero file IO on either side.

**Require-graph handoff**: `metadata.hydronium.requires`, a string array of module ids, derived from the AST the compile plugin already built — no second parse, no execution. The precedent, `dom/tools/gen_client_manifest.lua`, derives its graph the opposite way (monkeypatches `_G.require`, actually loads entry modules) — exact for that execution but requires running application code, which a build plugin must not do. So: **static AST scan of `require("<string literal>")` call expressions**, which misses computed requires — and this codebase has them (`server/init.lua:697` lazy-loads the meteorite adapter through an `__index` metamethod to break a cycle).

Make that gap testable rather than hand-waved: keep `gen_client_manifest.lua` as the **verification oracle** — a test running it for the client entry modules and asserting the static manifest is a superset of the dynamic one, failing loudly on any module the scanner missed.

### 1.5 Partiture shape

```lua
local ballad = require("ballad")
local hb     = require("hydronium_ballad")

return ballad.partiture(function(p)
  local luax = p:use(hb.plugins.luax)
  local src  = p.source.files({ "*.luax", "**/*.luax" }, { root = "src" })
  local compiled = luax.compile(src, { sourcemap = "external", strict_tags = false })
  ...
end)
```

**Both `"*.luax"` and `"**/*.luax"` are required** — `pipeline.lua`'s `glob_to_pattern` renders `**/` as `.-/`, so `"**/*.luax"` alone silently skips every top-level `.luax`. Easy to miss; costs an hour if it is.

---

## 2. Styles: a real CSS system for `.luax`

### 2.1 Syntax feasibility — checked, not assumed

- `luax/src/hydronium_luax/lexer.lua:30` holds a **fixed** `KEYWORDS` table of exactly the 22 Lua keywords. No registry, hook, or plugin table exists in the lexer, parser, or compiler for new statement forms.
- `parser.lua:655 parse_statement` is a full Lua statement dispatcher on keyword tokens. Adding `import` means: a new `KEYWORDS` entry (**silently breaks every existing file using `import` as an identifier**), a new AST node, a new parse function, a new emit branch, a new `formatter/printer.lua` case (must preserve the stated `format(format(x)) == format(x)` idempotence invariant), a `tree-sitter-luax` grammar rule + recompiled `parser/luax.so` + `queries/luax/*.scm`, a TextMate scope, and —
- — the killer — a new case in `luals/virtual_source.lua`, which rewrites `.luax` into virtual Lua **in place, byte-for-byte, line-for-line** (`pad_to_length`, per-byte `bytes[]` array, explicit newline preservation). Any new syntax must be replaceable by valid Lua of no greater byte length. `import "./Header.css" as styles` has no shorter valid-Lua equivalent and `import` isn't a Lua keyword, so LuaLS would flag it unless the rewrite is byte-exact. `docs/LUAX_DX_CURRENT_STATE.md` documents how fragile this layer already is.

**Decision: add zero new syntax.** Everything below is ordinary Lua call expressions, which the compiler already emits verbatim, `virtual_source.transform` already leaves untouched (it only rewrites JSX markup byte ranges), and LuaLS already types with no virtual-source work.

### 2.2 Authoring model

Sibling `.css` files, referenced through a plain function call:

```lua
local css = require("hydronium_dom.css")
---@type Header_css                       -- generated; see 2.4
local s = css.sheet("src/views/Header.css")

return <header class={s.showcase_header}>
         <h1 class={s.logo_text}>{title}</h1>
       </header>
```

`css.sheet(path)` returns a class-name table: keys are source class names with `-`→`_` (plus the raw hyphenated name also present, for `s["nav-link"]`), values are scoped names.

**Rejected alternative, tradeoff stated**: a Lua-table DSL (`css.create{ hero = { color = "#fff", marginTop = 16 } }`). It would get real LuaLS completion on *property* names for free (a `CSSProperties` LuaCATS class, the pattern `types/dom/init.d.lua` already uses for the DOM catalog) and reuse the existing, working `serialize_style` + unitless-property map in `dom/src/hydronium_dom/server/html.lua:134-147`. But it cannot express media queries, pseudo-classes, keyframes, or descendant/sibling selectors without invented nested-key conventions, and every author already knows CSS. Ship `.css` files first; keep `css.create{}` as a documented v2 for computed/theme values, where Lua-expression interpolation is the actual differentiator.

### 2.3 Normalization — two separate things, both concrete

**(a) Scoping (collision avoidance).** CSS-Modules-style hashed class names:

```
scoped = <css basename> .. "_" .. <class with - → _> .. "_" .. hash8
hash8  = FNV-1a 32-bit of (project-relative css path .. "\0" .. class name), 8 lowercase hex
```

Two decisions that matter:
- **Hash the source path, not the rule content.** Class names stay stable across edits to a rule body, so HTML and CSS don't have to regenerate in lockstep during dev.
- **Use one pure-Lua hash (FNV-1a) living in `hydronium_dom.css`, required by the ballad plugin — do not use `b3sum` here.** The runtime resolver must work inside a Meteorite hybrid handler and eventually inside wasmoon, where forking `b3sum` isn't available; `process.b3sum_string` forks per call, so hashing every class in every stylesheet would be hundreds of forks. One implementation, two callers, zero drift. `b3sum` stays where ballad already uses it — content-hashing asset *filenames* (§3), where it runs once per file and correctness demands a real cryptographic digest.
- `:global(.foo)` escape hatch: classes inside it are emitted unscoped — required for third-party markup and the `<html>`/`<body>` element selectors the SSR example already relies on.

**(b) Reset baseline.** Ship a hand-written ~30-line `dom/src/hydronium_dom/css/reset.css` (border-box inheritance, margin zeroing, `img,svg,video { display:block; max-width:100% }`, form-control font inheritance, `line-height` normalization). **Do not vendor normalize.css** — a 2KB+ third-party file with its own license/version churn, against the explicit zero-external-dependency invariant in `docs/BUNDLING.md` §1.1. Opt-in per build via `style.bundle(..., { reset = true })`, defaulting **true** for DOM targets and always **false** for `ink` (the terminal host has no CSS at all).

**Bundle order specified, not incidental**: reset first, then stylesheets sorted by project-relative source path — matching how ballad's own sinks sort (`file_graph_for` sorts by `virtual_path`). Deterministic output is a prerequisite for content-hashing the bundle.

### 2.4 Typing story (honest)

`s.showcase_header` is, to LuaLS, a field of a plain `table<string,string>` — no completion, no typo detection. Fix that doesn't touch the lexer: the style plugin also emits, per stylesheet, a LuaCATS declaration `types/styles/Header_css.d.lua` with `---@class Header_css` plus one `---@field` per class (both `_` and hyphenated forms) — the same generated-types pattern already used for the DOM/SVG catalog. The author writes one `---@type Header_css` annotation on the local.

**Open item, not resolved**: whether LuaLS can infer the per-file class automatically from `css.sheet("Header.css")` — a literal-argument-dependent return type. Likely not without a `@overload` per stylesheet (itself generated, polluting `hydronium_dom.css`'s signature). Honest v1: the one-line `---@type` annotation. Worth a live experiment against the real installed lua-language-server before committing.

### 2.5 Reaching SSR

Looked for an existing head-injection/document-shell hook in `dom/src/hydronium_dom/server/init.lua` and `server/html.lua`. **There is none** — the only auto-emitted tags (`__HYDRONIUM_STATE__`, `__HYDRONIUM_CLIENT_PLAN__`) are appended at the **end** of output, not into `<head>`. Adding a `<head>` injector would require buffering/patching output, breaking the streaming path (`server.render` writes chunks as it walks the tree, proven live by `/stream`).

**Therefore the author places the tag themselves; no renderer change needed.**

```lua
local css = require("hydronium_dom.css")
...
<head>
  <meta charset="utf-8" />
  <css.Styles />          -- <link rel="stylesheet" href="/assets/app.<hash>.css" />
</head>
```

`css.Styles` renders `<link>` in `mode = "link"` (production default) or `<style>{bundle_text}</style>` in `mode = "inline"` (dev / critical CSS). **The inline path already works today, verified**: `server/init.lua:507-518` puts `<style>` into raw-text mode and runs its content through `html.escape_style_content` (the `</style>` breakout guard, `html.lua:244-247`) — exactly what `examples/meteorite_ssr/views/App.luax` does today with its literal long string. The migration path for that file is a one-line swap, exercising a code path that already has a security guard.

### 2.6 Reaching the client — CSS bypasses the Lua VM entirely

Argued, not assumed:
- The DOM host bridge (`dom/src/hydronium_dom/host/dom.lua`) is exactly 15 required functions, all at element/text/attribute granularity, with no concept of `document.head`. Injecting a stylesheet means bolting a 16th, head-scoped bridge function onto a contract whose doc comment carefully enumerates and justifies all 15.
- Nothing in `dom/src/hydronium_dom/client/*.js` touches styles today (zero grep hits).
- No upside: the browser fetches `<link>` from the SSR HTML **before** the WASM Lua VM boots, so styles land strictly earlier this way. Runtime injection guarantees FOUC, and would double-ship CSS as Lua string data into the WASM payload — the same argument `loader.lua`'s own doc comment makes for not shipping the compiler into the browser.

**The one real exception**, named with a concrete fallback: a lazily-loaded Lua island whose stylesheet wasn't in the SSR shell. Handle it by emitting a `<link>` in the SSR shell for **every** island's stylesheet — the island set is already enumerated at render time in `render_state.client_plan.islands`, so the shell can be complete with no runtime injection. Deferred, not hand-waved.

### 2.7 Style plugin contract

```
name = "hydronium.style", methods = {
  bundle = { inputs = {"asset_set"}, outputs = {"asset_set"},
             cacheable = true, parallel_safe = true },
}
```

Inputs: `.css` file assets (primary) + the hashed-asset AssetSet (via `depends_on`, so `url(...)` references inside CSS can be rewritten to hashed URLs). Outputs: one generated `assets/app.<contenthash>.css`, plus one generated `types/styles/<Name>_css.d.lua` per stylesheet, plus `kind="generated"` metadata carrying the full `source path → { class → scoped }` map for the manifest node.

**Ordering constraint**: `assets.hash` must run before `style.bundle`. Ballad has no `merge` primitive, and `PluginProxy` only ever pushes one handle into `inputs` — extra upstreams go through `options.depends_on`, which appends to `node.inputs` and arrives as additional entries in `input_results`, in declaration order. Non-obvious, and the single most likely thing to be implemented wrong:

```lua
local styles = style.bundle(cssSources, { reset = true, depends_on = { hashed } })
-- inside the plugin: inputs[1] = css sources, inputs[2] = hashed assets
```

---

## 3. Static assets (images, fonts, SVG, arbitrary files)

### 3.1 Authoring

```lua
local assets = require("hydronium_dom.assets")
<img src={assets.url("assets/logo.png")} alt="Hydronium" />
```

Again zero new syntax — a plain call the compiler emits verbatim.

**Argument is project-root-relative, not file-relative.** File-relative would be more ergonomic and achievable (`debug.getinfo(2,"S").source`, an idiom already used at `luax/src/hydronium_luax/plugin.lua:1-3` and `luals/init.lua:12-14`), but breaks after compilation: the built `.lua` module's chunk name is whatever `load` was given, so "the calling file" no longer identifies the original `.luax` location. Fixing that means threading a per-module base through the manifest and keying lookups by module id — real complexity for a small ergonomic win. Project-root-relative keeps the manifest a flat string→string map and the build-time AST scan a trivial string-literal read. Document file-relative as explicitly rejected and why.

`assets.url` behavior: prod reads the manifest (loaded once, memoized); dev, with no manifest present, returns `"/" .. path` unchanged and serves from the source tree. Same call site, no `if dev`.

### 3.2 Assets plugin contract

```
name = "hydronium.assets", methods = {
  hash = { inputs = {"asset_set"}, outputs = {"asset_set"},
           cacheable = true, parallel_safe = true },
}
```

Per input file asset:
- `digest = ballad.process.b3sum(asset.source_path)`, first 10 hex chars. Reuse `ballad.process` — don't reimplement; it already handles quoting and is what the cache layer trusts.
- Emit a new asset with `virtual_path = "assets/<stem>.<digest10><ext>"` and **`source_path` preserved** (so `write_asset_to_directory` takes the `fs.copy_file` branch — a 4 MB image never becomes a Lua string).
- `metadata.hydronium = { kind = "asset", source = <project-relative source>, url = "/" .. virtual_path, integrity = "b3:" .. digest }`.

Content-hash here (not path-hash, unlike class names): cache-busting and immutable far-future caching are the entire point.

### 3.3 Manifest

One node, `hydronium.manifest.emit`, taking the compiled Lua AssetSet as its primary input and the style + asset sets via `depends_on`, returning the union of all inputs plus the manifest assets it generates. Making the manifest node also the merge node means one node and one sink edge — required, since `p.sink.directory` accepts exactly one handle.

Schema (`hydronium-manifest.json`, version-stamped):

```json
{ "version": 1,
  "assets":  { "assets/logo.png": { "url": "/assets/logo.a1b2c3d4e5.png", "integrity": "b3:…" } },
  "styles":  { "src/views/Header.css": { "bundle": "app.css",
               "classes": { "showcase-header": "Header_showcase_header_1a2b3c4d" } } },
  "bundles": { "app.css": { "url": "/assets/app.9f8e7d6c5b.css" } },
  "modules": { "views.App": { "path": "views/App.lua", "requires": ["hydronium", "hydronium_dom.server.meteorite"] } } }
}
```

**Emit it twice**: `hydronium-manifest.json` (via `dkjson`, verified available on ballad's `LUA_PATH`) for external/JS consumers, **and** `hydronium-manifest.lua` (`return { ... }`, a plain Lua table literal) for the Lua runtime. Hydronium has zero runtime dependencies, and `dom/tools/gen_client_manifest.lua` hand-rolls its own JSON emitter with a comment saying exactly that. A `loadstring`-able table literal is free to produce and consume; a hand-rolled JSON *reader* is 40 lines of avoidable risk. Follow the precedent rather than fighting it.

**Do not use `ballad --report` as the manifest** — verified, it contains only one summary asset per sink. Enable `file_graph = true` on the sink additionally for a real per-file dump with metadata for debugging, but the SSR server should read *this* stable schema, not ballad's internal graph format.

---

## 4. Export flow through ballad

### 4.1 The real sink API

- `p.sink.directory(input, { out, file_graph })` — the one to use. Writes every input asset to `out/<virtual_path>`; generated+content assets are written, `source_path` assets are copied. **Calls `fs.remove_tree(out)` first** — exactly one `sink.directory` per output dir, never aimed at a directory containing anything to keep. (Existing partitures write to `dist/registry`; a new `dist/site` avoids collision.)
- `p.sink.artifact(input, { out, product })` — picks a single asset with a source/output path and copies it. What all four current partitures use for registry packaging. Wrong tool for a multi-file dist.
- `p.sink.file_graph`, `p.sink.stdout`, `p.sink.none` — diagnostics/no-op terminals.
- `Pipeline:plan()` errors on any dangling transform leaf — every branch must reach the sink.

### 4.2 Full app partiture

```lua
local ballad = require("ballad")
local hb     = require("hydronium_ballad")

return ballad.partiture(function(p)
  local luax     = p:use(hb.plugins.luax)
  local style    = p:use(hb.plugins.style)
  local assetsp  = p:use(hb.plugins.assets)
  local manifest = p:use(hb.plugins.manifest)

  local luaxSrc = p.source.files({ "*.luax", "**/*.luax" }, { root = "src" })
  local cssSrc  = p.source.files({ "*.css",  "**/*.css"  }, { root = "src" })
  local rawSrc  = p.source.files({ "*.png","**/*.png","*.svg","**/*.svg",
                                   "*.woff2","**/*.woff2" }, { root = "assets" })

  local compiled = luax.compile(luaxSrc, { sourcemap = "external" })
  local hashed   = assetsp.hash(rawSrc)
  local styles   = style.bundle(cssSrc, { reset = true, depends_on = { hashed } })
  local bundle   = manifest.emit(compiled, { depends_on = { styles, hashed } })

  p.sink.directory(bundle, { out = "dist/site", file_graph = true })
end)
```

Resulting `dist/site/`:

```
views/App.lua            views/App.lua.map
assets/app.9f8e7d.css    assets/logo.a1b2c3.png
hydronium-manifest.json  hydronium-manifest.lua
types/styles/Header_css.d.lua
file-graph.json
```

**Performance note worth acting on**: `cache.compute_key` hashes every input asset, and for generated content assets that means a `process.b3sum_string` temp-file+fork **per asset**. The `manifest.emit` node has the most inputs and does the least work — set it `cacheable = false` (already reflected in the architecture doc's contract). Keep total node count low for the same reason.

### 4.3 Connecting to serving

`meteorite.site` is the only real, verified precedent. Production wiring:

```lua
meteorite.site(app, { root = ".", assets = {
  ["/assets/:path*"] = { dir = "dist/site/assets", param = "path" },
}})
```

Three verified constraints from that file's own hard-won comments:
1. **`meteorite.site` bakes file content at graph/build time.** For content-hashed immutable assets this is exactly correct — the URL changes when content changes, so the baked copy is never stale. It also means a rebuilt `dist/` needs a `zig build` to take effect — fine for prod, unusable for dev, hence the §1.3 fork.
2. **Meteorite's static codegen rejects symlinks outright** — `write_asset_to_directory` uses `fs.copy_file`, producing real files. No "link dist into place" shortcut.
3. **`meteorite.site` only conflict-checks against routes declared before it** — a later `app:get` under a claimed prefix loses silently with no build-time error. Keep `/assets/` disjoint from every SSR route prefix and declare it early.

**Does the SSR server need its own manifest? Yes** — the classic bundler answer, unavoidable here. The server must render `<link href="/assets/app.9f8e7d.css">` and `<img src="/assets/logo.a1b2c3.png">`, and those hashes are only known post-build. `hydronium_dom.css`/`hydronium_dom.assets` load `dist/site/hydronium-manifest.lua` once (memoized) and resolve source path → hashed URL. `meteorite.site` serves the bytes; the manifest supplies the names. Neither replaces the other.

---

## 5. Sequencing

1. **`hydronium-ballad` package skeleton** + `plugins.luax.compile`, no sourcemaps, no CSS. Prove one real `.luax` → `dist/site/views/App.lua` through `ballad play`. This is plausibly ballad's first working transform plugin — budget time for discovering ballad bugs (`plugins/lua.lua` proves nobody has walked this path).
2. **`loader.install()` searcher** + migrate `examples/meteorite_ssr/src/views/App.lua` to `require("views.App")`. Verify `/__hydronium/watch` live reload still works over a real socket, and `/` still renders. Gate: byte-identical output test (plugin vs. loader).
3. **Sourcemaps** (external) + the `bare_tags_without_alias` warning. Cheap, high value.
4. **Static assets**: `plugins.assets.hash`, `hydronium_dom.assets`, manifest v1 (assets only), `sink.directory`, `meteorite.site` wiring. Ship before CSS — strictly simpler, proves the manifest round-trip end to end.
5. **CSS**: `hydronium_dom.css` (pure-Lua FNV-1a scoper, `sheet`, `Styles`), `plugins.style.bundle`, reset.css, manifest v2. Migrate `examples/meteorite_ssr/views/App.luax`'s inline `<style>` blob to a real `App.css` — the natural first customer and a real before/after proof.
6. **Generated `.d.lua` class types** + resolve the LuaLS open question in §2.4.
7. **Give `examples/showcase/` a real stylesheet.** Its class names have never resolved to anything — the most legible possible demonstration this work landed.

## 6. Open questions

- **LuaLS literal-dependent return types** (§2.4): needs a live experiment against the real installed lua-language-server.
- **Package boundary**: assumed `hydronium/ballad/` as a sibling package (§0). Deferred to the architecture doc; only require paths change if that's wrong.
- **Bundle granularity**: one `app.css` vs. per-route bundles. Depends on the require graph (§1.4) and the splitter's work. Start with one bundle — the manifest schema already has a `bundles` map, so this is additive.
- **Ink**: `hydronium-ink` has no CSS concept. `.luax` compile is genuinely host-agnostic (`__luax_component(expr, {props})` regardless of host, confirmed by reading the emitter), so `plugins.luax` serves ink unchanged; `plugins.style`/`plugins.assets` are DOM-only and must not be wired into `ink/partiture.lua`.
- **Three inconsistent glob implementations in ballad** (`pipeline`/`cache`/`conventions`) — worth reporting upstream; it will bite someone.

## Critical files for implementation

- `hydronium/luax/src/hydronium_luax/compiler/init.lua`
- `hydronium/luax/src/hydronium_luax/loader.lua`
- `ballad/src/ballad/pipeline.lua`
- `hydronium/dom/src/hydronium_dom/server/html.lua`
- `hydronium/examples/meteorite_ssr/src/main.lua`
