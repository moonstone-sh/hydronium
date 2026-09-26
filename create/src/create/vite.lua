--[[
  Vite BASE wiring for the `ssr`, `spa`, and `islands` templates -- the
  three templates that actually have a client/browser surface (a
  server-rendered Document, or a Ballad-bundled client app). ALWAYS applied
  by `create.scaffold` for these three templates, regardless of whether
  Tailwind is on: per this task's own requirement ("the version that has
  vite either for SSR or SPA should use vite"), Vite is not a Tailwind
  side-effect, it is the base -- Tailwind (create/tailwind.lua) is a purely
  additive layer on TOP of what this module sets up. A pure `files ->
  files` transform (same contract writer.lua's callers already expect):
  never touches disk itself, only mutates the in-memory file table
  `create.scaffold` is about to hand to `writer.write_project`.

  WHY there is something real for Vite to build even with Tailwind off:
  `ssr`'s and `islands`' own `public/style.css` stays exactly what it was
  (a plain, hand-written stylesheet, served as-is by Meteorite, never
  touched by this module) -- this module adds a SECOND, Vite-built
  stylesheet at `src/styles.css` -> `public/dist/styles.css`, linked right
  after the first one in the Document. With Tailwind off it starts as a
  placeholder a project can grow into ordinary Vite-processed CSS (or, once
  Tailwind is switched on later, exactly the file `create/tailwind.lua`
  rewrites in place -- see that module's own header comment). This keeps
  "always applied" honest: `npm install && npm run build` really compiles
  something, not a build script with nothing to build, and gives every Vite
  template a real anchor to add plain JS/CSS assets to before ever touching
  Tailwind.

  `spa` needs a different integration, for the same reason
  create/tailwind.lua's own header comment used to explain before this
  module existed: `hydronium_ballad.plugins.site`'s `site.manifest(...)`
  GENERATES `dist/index.html` itself at build time
  (build/src/hydronium_ballad/plugins/site.lua's `render_index_html`), with
  exactly one `<link rel="stylesheet">` slot tied to its own
  `hb.plugins.style` output -- no "extra head content" option, and that
  plugin REWRITES every `.class-name` occurrence into a scoped hash
  (`hydronium_dom.css.scope_class`), which would mangle Tailwind's utility
  classes if fed through it later. So for `spa`, this module's CSS is built
  entirely separately (a real `vite build`, CSS-only) and linked into the
  ALREADY-BUILT `dist/index.html` with a small, real postbuild patch
  (`scripts/inject-vite-link.mjs`) that fails loudly, not silently, if
  `dist/index.html` does not exist yet. This module does NOT touch or
  replace `spa`'s own Lua/Ballad client bundle (`app.lua`/`partiture.lua`,
  bundled by `hydronium_ballad`'s real client bundler) -- Vite here only
  ever owns a second, independent static-asset build alongside it, exactly
  the "serve/build the static shell + assets, not replace Ballad's Lua
  bundling" split this task calls for.

  STILL TRUE for `ssr` and `spa` below (not yet migrated -- see
  docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md's STEP 2 status): hydronium/cli's
  `hydronium dev --vite` / `hydronium build --vite` (cli/src/main.lua) pair
  a `vite dev`/`vite build` (via `npx`, so `node_modules/.bin` resolves
  cwd-relatively) with Meteorite/Ballad. Tried both against the OLD
  CSS-only Vite config (no HTML/JS entry of its own -- `rollupOptions.input`
  was a bare `.css` file) and found two real, verified problems, not
  hypothetical ones:
    1. `hydronium build --vite` runs `vite build` BEFORE the partiture
       (cli/src/main.lua's own `M.build`), and `hydronium_ballad.plugins.
       site`'s directory sink REMOVES its whole `out` tree before writing
       its own output -- so by the time that command returns, Vite's
       freshly-built asset has already been deleted by Ballad's own sink.
       Verified live: ran a full `spa` (`router = "meteorite"`) build with
       this wired in, `dist/assets/` only ever contained Ballad's own
       scoped CSS, never Vite's. STILL APPLIES to `spa` (its client bundle
       genuinely goes through `hydronium_ballad`); does NOT apply to
       `islands`/`ssr`, which have no partiture.lua/Ballad build at all --
       `apply_islands` below uses a real dual-dev-server script instead
       (see its own comment).
    2. `hydronium dev --vite`'s dual dev server (js/packages/vite/bin/
       dual-dev.mjs) is spawned via a path computed relative to
       cli/src/main.lua's OWN location (`repo_root = this_dir .. "/../.."`,
       then `repo_root .. "/js/packages/vite/bin/dual-dev.mjs"`) -- this
       resolves correctly only when `hydronium` is run FROM INSIDE the
       hydronium monorepo checkout. A real consumer's materialized
       `hydronium/cli` package (moonstone exports exactly `src/**` from
       cli/'s own directory -- see the root partiture.lua's
       `package_orbit` helper) has no sibling `js/` directory at all, so
       this path does not exist for any real scaffolded project. VERIFIED
       BY READING cli/src/main.lua's `M.dual_dev_argv`/top-of-file
       `repo_root` computation this session (2026-09-25), not by running
       it broken -- a real framework bug, out of scope for this template
       work to fix. `apply_islands` below sidesteps it entirely: it
       vendors `@hydronium-js/vite` itself (see vite_vendor.lua) and calls
       its `runDualDevServer` directly from a project-local
       `scripts/dev.mjs`, which needs no path back into this monorepo.
  So `ssr`/`spa`'s build below stays a plain, separate `vite build`/`vite
  build --watch`, run by the user's own package manager, which -- unlike
  `moon exec` or `hydronium build`/`dev` -- puts a project's own
  `node_modules/.bin` on PATH itself.

  Package manager: `create.scaffold` resolves and reports a
  `package_manager` for every Vite-based template (this module's
  `M.supported_templates`), independent of whether Tailwind is on --
  Tailwind never gates it. Scaffolding never refuses for lack of one (like
  `npm create vite` itself, files are written regardless); only the actual
  "install dependencies now" step (create.wizard_tasks' `js_install` task)
  needs the resolved manager to really exist on PATH, and fails with a
  clear, actionable message rather than a generic shell error when it
  doesn't.

  DISTRIBUTING `@hydronium-js/vite` (decided 2026-09-25, STEP 2 of
  docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md). It is not published to npm yet
  (js/packages/vite/package.json's own `publishConfig` describes intent,
  not reality). Considered three options: (a) a `file:` dependency
  pointing back into a sibling hydronium checkout -- rejected, breaks for
  any real user who does not happen to have this monorepo cloned next to
  their project, the exact fragility the Lua side's own README explicitly
  calls out as a LOCAL-DEV-ONLY convenience, not the real story; (b)
  declare a real registry semver range now and document a manual interim
  -- rejected, it makes `npm install` fail today, which fails this
  template's own build gate, not just a hypothetical future user's; (c)
  VENDOR THE BUILT PACKAGE, chosen: `create/src/create/vite_vendor.lua`
  (generated by `js/scripts/sync-vite-vendor.mjs` from a real `pnpm build`
  of js/packages/vite, checked for staleness by
  `js/scripts/check-vite-vendor-drift.mjs`) embeds `dist/*.js`,
  `dist/*.d.ts`, `dist/supervisor.mjs`, and a trimmed `package.json` as
  literal Lua strings -- the same reasoning `templates/islands.lua` already
  uses for `public/js/bootstrap/*.js` (a scaffolded project's files come
  from an in-memory table, not disk, so "ship real bytes" means "embed
  them in Lua source", not "read them from a path that may not exist at
  runtime"). `apply_islands` writes those bytes into the new project's own
  `vendor/hydronium-js-vite/`, and its `package.json` depends on
  `"@hydronium-js/vite": "file:./vendor/hydronium-js-vite"` -- a real,
  resolvable local npm directory dependency, self-contained inside the
  generated project, no sibling checkout required. Once the package is
  actually published, this becomes a real semver range and the vendoring
  goes away; the provider CONTRACT (`hydronium_dom.assets`) does not
  change either way.
]]

local M = {}
local vite_vendor = require("create.vite_vendor")

local function insert_after(haystack, anchor, insertion)
  local s, e = haystack:find(anchor, 1, true)
  if not s then return nil, "anchor not found" end
  return haystack:sub(1, e) .. insertion .. haystack:sub(e + 1)
end

local function replace_once(haystack, old, new)
  local s, e = haystack:find(old, 1, true)
  if not s then return nil, "anchor not found" end
  return haystack:sub(1, s - 1) .. new .. haystack:sub(e + 1)
end

M.supported_templates = { ssr = true, islands = true, spa = true }

-- Shared by apply_islands and apply_ssr below (`spa` has no editable
-- Document source at all -- see this file's own header comment -- so it
-- is handled entirely separately by `apply_spa`).
local STYLESHEET_LINK_ANCHOR = '<link rel="stylesheet" href="/public/style.css" />'

-- Placeholder content for the Vite-built stylesheet when Tailwind is off.
-- `create/tailwind.lua` OVERWRITES this file wholesale when Tailwind is
-- turned on (see that module's own header comment) -- this is only ever
-- what a plain, Tailwind-less Vite template starts with.
local BASE_STYLES_CSS = [[/* Built by Vite (see vite.config.js) into public/dist/, referenced from
   the Document via hydronium_dom.assets.tags("src/styles.css"). Add your
   own Vite-processed CSS/asset imports here. */
]]

--------------------------------------------------------------------------------
-- islands: the REAL adapter integration (STEP 2 of
-- docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md), not the CSS-only side-build
-- above. Document uses `hydronium_dom.assets.tags(...)` (no hardcoded
-- `/public/dist/...` path in application Lua); the JS island's `module`
-- becomes a plain Vite entry specifier, resolved dev/prod by
-- `hydronium_dom.server.vite_module` -- already wired into
-- `hydronium_dom.server.init`'s ISLAND branch for every `interpreter =
-- "js"` island, so the component itself needs no explicit `hy_asset_ref`
-- call; `vite.config.js` registers the real `@hydronium-js/vite` plugin
-- with both the island and the CSS entry declared, so Vite actually
-- bundles/minifies/hashes them (previously: raw, unbundled files served
-- verbatim from `public/js/island/`). `islands`/`ssr` have no
-- partiture.lua/Ballad client bundle at all, so Vite's build output can
-- live inside `public/` (Meteorite's own static root) with no sink-order
-- hazard -- unlike `spa`, see this file's own header comment.
--------------------------------------------------------------------------------

local ISLAND_MODULE_ATTR = 'module="/js/island/counter.js"'
local ISLAND_MODULE_SPECIFIER = 'module="src/islands/counter.js"'
local H_REQUIRE_LINE = 'local H = require("hydronium")'
local ASSETS_REQUIRE_INSERT = '\nlocal assets = require("hydronium_dom.assets")'
local ISLAND_ASSET_ROUTE_LINE = '\n    ["/js/island/:path*"] = { dir = "public/js/island", param = "path" },'
local DEV_WATCH_ISLAND_LINE = '\n    "public/js/island/counter.js",'
local MOONSTONE_DEV_SCRIPT_OLD = [[dev = "moon exec --dev -- hydronium dev --meteorite-args='--mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit'"]]
local MOONSTONE_DEV_SCRIPT_NEW = 'dev = "npm run dev"'

-- The opening of whichever function actually renders the Document, for
-- each router variant: `src/main.lua`'s inline "/" handler
-- (`--router meteorite`, the default), or `src/app/page_handler.lua`'s
-- `render` callback (`--router hydronium` -- router_mode.apply_islands,
-- which runs BEFORE this module, moves rendering there; `src/main.lua`
-- has no inline Document render left in that mode at all).
local INLINE_HANDLER_OPEN = 'app:get("/", function(c)\n'
local PAGE_HANDLER_RENDER_OPEN = 'render = function(c, page, opts)\n'

--- Provider bootstrap, INLINED directly into whichever function actually
--- calls `require("views.Document")` and renders it -- not factored into a
--- shared top-level local function, and not configured at this file's own
--- top level either. Both were tried and both are real, verified bugs, not
--- style preferences:
---
---  1. A shared `local function configure_vite() ... end` called FROM the
---     inline "/" handler fails `moon run build` outright: "hybrid inline
---     handlers must be source-liftable ... move requires and mutable
---     values inside the handler body" -- Meteorite's hybrid build
---     compiles an inline route handler as a fully self-contained chunk
---     with NO upvalues over any other local/function in the file, not
---     even one defined earlier in the same file.
---  2. Configuring providers at this file's own TOP LEVEL (outside any
---     handler) builds and runs with no error, but SILENTLY has no effect:
---     each lifted handler is its own independently-loaded chunk with a
---     fresh module cache, so `require("hydronium_dom.assets")` INSIDE the
---     handler returns a DIFFERENT table than the one configured back at
---     the file's top level. Verified live: the served page kept every
---     asset URL at its raw, unconfigured fallback (`/src/styles.css`,
---     the bare island specifier) until this block moved to literally
---     where its sibling `require("views.Document")` call already lives.
---
--- Detects dev vs. prod by whether Vite's dev plugin has published its
--- bound origin -- see js/packages/vite/src/plugin.ts's `devOriginFile`
--- (default ".hydronium/vite-dev.json") -- rather than an env var: the
--- file only exists while `vite dev` is actually running, so this can
--- never point at a stale/dead port the way a hand-set env var surviving
--- past its dev session could.
local VITE_PROVIDER_BOOTSTRAP = [=[
  local assets = require("hydronium_dom.assets")
  local vite_module = require("hydronium_dom.server.vite_module")
  local vite_json = require("hydronium_dom.server.json")

  local vite_dev_origin = nil
  local vite_dev_file = io.open(".hydronium/vite-dev.json", "r")
  if vite_dev_file then
    local vite_dev_raw = vite_dev_file:read("*a")
    vite_dev_file:close()
    local vite_dev_ok, vite_dev_decoded = pcall(vite_json.decode, vite_dev_raw)
    if vite_dev_ok and type(vite_dev_decoded) == "table" and type(vite_dev_decoded.origin) == "string" then
      vite_dev_origin = vite_dev_decoded.origin
    end
  end

  if vite_dev_origin then
    vite_module.configure({ mode = "dev", vite_origin = vite_dev_origin })
    assets.configure_provider({ provider = "vite-dev", vite_origin = vite_dev_origin })
  else
    vite_module.configure({ mode = "prod" })
    -- `base = "/public/dist"`: Vite's own manifest `file` paths are
    -- relative to its `outDir` (public/dist), but the URL a browser
    -- fetches must be relative to Meteorite's `/public/:path*` static
    -- route -- i.e. site-root-relative, "/public/dist/<file>", not
    -- "/<file>". Verified live: without this, every hashed asset URL
    -- 404'd (assets.lua's default base of "/" produced "/assets/..." with
    -- nothing registered to serve it).
    assets.configure_provider({ provider = "vite-manifest", manifest_path = "public/dist/.vite/manifest.json", base = "/public/dist" })
  end
]=]

--- Replaces the JS island's hardcoded static `module` path with a real
--- Vite entry specifier, wherever the island actually lives -- plain
--- `views/Document.luax`, or `views/Home.luax` when `--router hydronium`
--- (router_mode.apply_islands, which runs BEFORE this module, moves the
--- island there -- see that module's own generated content).
local function patch_island_module(files)
  for _, key in ipairs({ "views/Home.luax", "views/Document.luax" }) do
    if files[key] and files[key]:find(ISLAND_MODULE_ATTR, 1, true) then
      local patched, err = replace_once(files[key], ISLAND_MODULE_ATTR, ISLAND_MODULE_SPECIFIER)
      if not patched then error("create.vite: " .. tostring(err) .. " in " .. key, 2) end
      files[key] = patched
      return
    end
  end
  error("create.vite: could not find the JS island's " .. ISLAND_MODULE_ATTR
    .. " in views/Home.luax or views/Document.luax -- has templates/islands.lua or router_mode.lua drifted?", 2)
end

local function apply_islands(files, opts)
  -- The shared shell always has this file, in both router modes, and
  -- always contains the base stylesheet link -- see this module's own
  -- header comment on why `islands`' Vite build lives in `public/` with no
  -- sink-order hazard.
  local document = files["views/Document.luax"]
  if not document then
    error("create.vite: apply_islands expected views/Document.luax to exist", 2)
  end
  local patched, err = insert_after(document, STYLESHEET_LINK_ANCHOR, '\n        {assets.tags("src/styles.css")}')
  if not patched then error("create.vite: " .. tostring(err) .. " in views/Document.luax", 2) end
  patched, err = replace_once(patched, H_REQUIRE_LINE, H_REQUIRE_LINE .. ASSETS_REQUIRE_INSERT)
  if not patched then error("create.vite: " .. tostring(err) .. " in views/Document.luax (H require anchor)", 2) end
  files["views/Document.luax"] = patched

  patch_island_module(files)

  -- The island's JS source moves from a raw, unbundled static file under
  -- `public/js/island/` to a real Vite build entry under `src/`.
  files["src/islands/counter.js"] = files["public/js/island/counter.js"]
  files["public/js/island/counter.js"] = nil

  -- Placeholder CSS entry (BASE_STYLES_CSS, shared with apply_ssr): a
  -- real, empty-but-present Vite-processed stylesheet
  -- so `npm run build` compiles something even before Tailwind (or any
  -- hand-written CSS) is added, and create/tailwind.lua overwrites this in
  -- place when Tailwind is turned on.
  files["src/styles.css"] = BASE_STYLES_CSS

  local main, main_err = replace_once(files["src/main.lua"], ISLAND_ASSET_ROUTE_LINE, "")
  if not main then error("create.vite: " .. tostring(main_err) .. " in src/main.lua (island asset route)", 2) end
  files["src/main.lua"] = main

  -- Provider bootstrap goes wherever the Document actually gets rendered
  -- -- see VITE_PROVIDER_BOOTSTRAP's own comment for why it must be
  -- inlined exactly there (a real, verified Meteorite hybrid-build
  -- constraint), not at this file's top level or a shared function.
  if files["src/app/page_handler.lua"] then
    local handler, handler_err = insert_after(files["src/app/page_handler.lua"], PAGE_HANDLER_RENDER_OPEN, VITE_PROVIDER_BOOTSTRAP)
    if not handler then error("create.vite: " .. tostring(handler_err) .. " in src/app/page_handler.lua (render anchor)", 2) end
    files["src/app/page_handler.lua"] = handler
  else
    local patched_main, patched_main_err = insert_after(files["src/main.lua"], INLINE_HANDLER_OPEN, VITE_PROVIDER_BOOTSTRAP)
    if not patched_main then error("create.vite: " .. tostring(patched_main_err) .. " in src/main.lua (\"/\" handler anchor)", 2) end
    files["src/main.lua"] = patched_main
  end

  -- Vite now owns HMR for the island/CSS it builds (its own dev server,
  -- `import.meta.hot`) -- the Lua-side full-page-reload watcher must not
  -- also react to their edits, or the two would race. See
  -- docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md section 2.4, "two HMR systems,
  -- deliberately uncoordinated".
  if files["src/dev_watch.lua"] then
    local watch, watch_err = replace_once(files["src/dev_watch.lua"], DEV_WATCH_ISLAND_LINE, "")
    if not watch then error("create.vite: " .. tostring(watch_err) .. " in src/dev_watch.lua", 2) end
    files["src/dev_watch.lua"] = watch
  end

  -- `moon run dev` now runs the real dual dev-server (Meteorite + `vite
  -- dev` together, see scripts/dev.mjs below) instead of the old
  -- Vite-less `hydronium dev` -- without this, a fresh `moon run dev`
  -- would try to serve an island whose real bytes only exist once Vite has
  -- built or is serving them, and 404. STEP 4 territory in the plan, but
  -- correctness for THIS template requires it now: the island source
  -- moved out of `public/js/island/` above, so there is no static file
  -- left to fall back to.
  local moonstone, moonstone_err = replace_once(files["moonstone.toml"], MOONSTONE_DEV_SCRIPT_OLD, MOONSTONE_DEV_SCRIPT_NEW)
  if not moonstone then error("create.vite: " .. tostring(moonstone_err) .. " in moonstone.toml (dev script anchor)", 2) end
  files["moonstone.toml"] = moonstone

  -- Vendor @hydronium-js/vite -- see this file's own header comment
  -- ("DISTRIBUTING @hydronium-js/vite") for why this is a real, checked-in
  -- copy rather than an npm registry dependency.
  for rel_path, content in pairs(vite_vendor) do
    files["vendor/hydronium-js-vite/" .. rel_path] = content
  end

  files["package.json"] = string.format([[{
  "name": "%s-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "description": "Vite build for this project's JS island(s) and CSS -- bundled, minified, and content-hashed for production; served directly from Vite's dev server in development. Run alongside the Lua/Meteorite server, not instead of it.",
  "scripts": {
    "dev": "node scripts/dev.mjs",
    "build": "vite build"
  },
  "devDependencies": {
    "vite": "^8.3.0",
    "@hydronium-js/vite": "file:./vendor/hydronium-js-vite"
  }
}
]], opts.name)

  files["vite.config.js"] = [[import { defineConfig } from "vite";
import { hydronium } from "@hydronium-js/vite";

// Real Vite build: this project's JS island(s) (fetched at runtime by
// public/js/bootstrap/bootstrap.js -- nothing in Vite's own module graph
// imports them, so they must be declared as explicit build inputs, see the
// `hydronium` plugin's own `islands` option) plus its CSS entry, bundled,
// minified, and content-hashed. `publicDir: false` -- Meteorite's static
// root is this project's own `public/`, not Vite's: Vite's default
// behavior is to copy `publicDir` wholesale into `build.outDir` on every
// build, which here would nest a second copy of the whole `public/` tree
// under `public/dist/` (verified with a real `vite build` -- see this
// file's own header comment on the identical hazard for the CSS-only
// ssr/spa builds this template used to share).
export default defineConfig({
  plugins: [
    hydronium({ islands: ["src/islands/counter.js", "src/styles.css"] }), // hydronium-vite-plugin
  ],
  publicDir: false,
  build: {
    outDir: "public/dist",
    emptyOutDir: true,
  },
});
]]

  files["scripts/dev.mjs"] = [[// Dual dev-server launcher for this project: Meteorite's own dev server
// (SSR + API) and `vite dev` (this project's JS island(s) + CSS, with real
// HMR) run TOGETHER -- docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md section
// 2.5: Meteorite cannot serve websockets, so Vite's HMR socket (and every
// dev-time asset URL) must reach Vite's own origin directly.
//
// Uses @hydronium-js/vite's own runDualDevServer (vendor/hydronium-js-vite/
// -- see that directory's own package.json for why this isn't a normal npm
// dependency yet): signals forwarded to both children, output merged with
// a `[name]` prefix, and one child exiting brings the other down too (a
// half-alive dev session -- Vite up, Meteorite gone, or vice versa --
// would otherwise silently serve stale/broken pages instead of failing
// loudly).
import { runDualDevServer } from "@hydronium-js/vite";

const supervisor = runDualDevServer([
  {
    name: "meteorite",
    command: "moon",
    args: [
      "exec", "--dev", "--", "meteorite", "dev",
      "--mode", "hybrid_dev", "--backend", "fast_http",
      "--lua-root", ".moonstone/env/libexec/luajit",
    ],
  },
  // npx, not a bare `vite`: resolves node_modules/.bin relative to cwd,
  // so this works from a project that only declared vite as a local
  // devDependency (this one does).
  { name: "vite", command: "npx", args: ["vite"] },
]);

supervisor.exited.then((results) => {
  for (const r of results) {
    console.error(`dev: ${r.name} exited (code=${r.code ?? "null"} signal=${r.signal ?? "null"})`);
  }
  process.exit(results.every((r) => r.code === 0 && r.signal === null) ? 0 : 1);
});
]]

  files[".gitignore"] = (files[".gitignore"] or "") .. "node_modules/\npublic/dist/\n.hydronium/vite-dev.json\n"

  files["README.md"] = (files["README.md"] or "") .. [[

## Vite

This project's JS island(s) and CSS are built by a real Vite 8 pipeline
(`@hydronium-js/vite`, vendored into `vendor/hydronium-js-vite/` -- see
that directory's own `package.json` for why): bundled, minified, and
content-hashed in production; served with real HMR from Vite's own dev
server in development.

```bash
npm install
```

**Development** (both servers together -- note this replaces `hydronium
dev` for this template; see `scripts/dev.mjs`'s own header comment for
why the fancy TUI status view isn't part of this dual-server flow):

```bash
npm run dev
```

**Production:**

```bash
npm run build      # vite build -- public/dist/, hashed, with a manifest
moon sync
moon run build      # meteorite build -- bakes public/ into the server binary
./dist/server
```
]]

  return files
end

--------------------------------------------------------------------------------
-- ssr: the same real adapter integration as islands, minus everything
-- island-specific -- `ssr` has no JS island at all (its client
-- interactivity is `d.lua.mount`, a browser Lua VM, entirely
-- hydronium_ballad's own pipeline, never Vite's concern). The ONLY thing
-- Vite owns here is `src/styles.css`, but it goes through the exact same
-- real plugin/manifest/provider machinery as an island would -- `islands:
-- ["src/styles.css"]` is a perfectly ordinary Vite build input; nothing
-- about the plugin option name restricts it to JS.
--
-- `ssr` ALWAYS renders through `src/app/page_handler.lua`'s `render`
-- callback (its Document uses the `hydronium/router` site manifest
-- unconditionally, unlike `islands`, which only gets one under
-- `--router hydronium`) -- so, unlike apply_islands, there is exactly one
-- render site to patch, always.
--------------------------------------------------------------------------------

local function apply_ssr(files, opts)
  local document = files["src/views/Document.luax"]
  if not document then
    error("create.vite: apply_ssr expected src/views/Document.luax to exist", 2)
  end
  local patched, err = insert_after(document, STYLESHEET_LINK_ANCHOR, '\n        {assets.tags("src/styles.css")}')
  if not patched then error("create.vite: " .. tostring(err) .. " in src/views/Document.luax", 2) end
  patched, err = replace_once(patched, H_REQUIRE_LINE, H_REQUIRE_LINE .. ASSETS_REQUIRE_INSERT)
  if not patched then error("create.vite: " .. tostring(err) .. " in src/views/Document.luax (H require anchor)", 2) end
  files["src/views/Document.luax"] = patched

  files["src/styles.css"] = BASE_STYLES_CSS

  local handler, handler_err = insert_after(files["src/app/page_handler.lua"], PAGE_HANDLER_RENDER_OPEN, VITE_PROVIDER_BOOTSTRAP)
  if not handler then error("create.vite: " .. tostring(handler_err) .. " in src/app/page_handler.lua (render anchor)", 2) end
  files["src/app/page_handler.lua"] = handler

  local moonstone, moonstone_err = replace_once(files["moonstone.toml"], MOONSTONE_DEV_SCRIPT_OLD, MOONSTONE_DEV_SCRIPT_NEW)
  if not moonstone then error("create.vite: " .. tostring(moonstone_err) .. " in moonstone.toml (dev script anchor)", 2) end
  files["moonstone.toml"] = moonstone

  for rel_path, content in pairs(vite_vendor) do
    files["vendor/hydronium-js-vite/" .. rel_path] = content
  end

  files["package.json"] = string.format([[{
  "name": "%s-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "description": "Vite build for this project's CSS -- bundled, minified, and content-hashed for production; served directly from Vite's dev server in development. Run alongside the Lua/Meteorite server, not instead of it.",
  "scripts": {
    "dev": "node scripts/dev.mjs",
    "build": "vite build"
  },
  "devDependencies": {
    "vite": "^8.3.0",
    "@hydronium-js/vite": "file:./vendor/hydronium-js-vite"
  }
}
]], opts.name)

  files["vite.config.js"] = [[import { defineConfig } from "vite";
import { hydronium } from "@hydronium-js/vite";

// Real Vite build for this project's CSS entry, bundled, minified, and
// content-hashed (this template has no JS island of its own -- its
// client interactivity is `d.lua.mount`, a browser Lua VM, entirely
// hydronium_ballad's own separate pipeline). `publicDir: false` --
// Meteorite's static root is this project's own `public/`, not Vite's:
// Vite's default behavior is to copy `publicDir` wholesale into
// `build.outDir` on every build, which here would nest a second copy of
// the whole `public/` tree under `public/dist/`.
export default defineConfig({
  plugins: [
    hydronium({ islands: ["src/styles.css"] }), // hydronium-vite-plugin
  ],
  publicDir: false,
  build: {
    outDir: "public/dist",
    emptyOutDir: true,
  },
});
]]

  files["scripts/dev.mjs"] = [[// Dual dev-server launcher for this project: Meteorite's own dev server
// (SSR + the browser Lua VM's own HMR) and `vite dev` (this project's CSS,
// with real HMR) run TOGETHER -- docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md
// section 2.5: Meteorite cannot serve websockets, so Vite's HMR socket
// (and every dev-time asset URL) must reach Vite's own origin directly.
// The two HMR systems are deliberately uncoordinated (section 2.4): Vite
// never touches anything under src/views/ or src/app/, and Meteorite's
// own Lua-side HMR never touches src/styles.css.
//
// Uses @hydronium-js/vite's own runDualDevServer (vendor/hydronium-js-vite/
// -- see that directory's own package.json for why this isn't a normal npm
// dependency yet): signals forwarded to both children, output merged with
// a `[name]` prefix, and one child exiting brings the other down too (a
// half-alive dev session -- Vite up, Meteorite gone, or vice versa --
// would otherwise silently serve stale/broken pages instead of failing
// loudly).
import { runDualDevServer } from "@hydronium-js/vite";

const supervisor = runDualDevServer([
  {
    name: "meteorite",
    command: "moon",
    args: [
      "exec", "--dev", "--", "meteorite", "dev",
      "--mode", "hybrid_dev", "--backend", "fast_http",
      "--lua-root", ".moonstone/env/libexec/luajit",
    ],
  },
  // npx, not a bare `vite`: resolves node_modules/.bin relative to cwd,
  // so this works from a project that only declared vite as a local
  // devDependency (this one does).
  { name: "vite", command: "npx", args: ["vite"] },
]);

supervisor.exited.then((results) => {
  for (const r of results) {
    console.error(`dev: ${r.name} exited (code=${r.code ?? "null"} signal=${r.signal ?? "null"})`);
  }
  process.exit(results.every((r) => r.code === 0 && r.signal === null) ? 0 : 1);
});
]]

  files[".gitignore"] = (files[".gitignore"] or "") .. "node_modules/\npublic/dist/\n.hydronium/vite-dev.json\n"

  files["README.md"] = (files["README.md"] or "") .. [[

## Vite

This project's CSS is built by a real Vite 8 pipeline (`@hydronium-js/vite`,
vendored into `vendor/hydronium-js-vite/` -- see that directory's own
`package.json` for why): bundled, minified, and content-hashed in
production; served with real HMR from Vite's own dev server in
development. This is independent of the browser Lua VM's own HMR (Vite
never touches `src/views/`/`src/app/`, and editing those never touches
Vite's build).

```bash
npm install
```

**Development** (both servers together -- note this replaces `hydronium
dev` for this template; see `scripts/dev.mjs`'s own header comment):

```bash
npm run dev
```

**Production:**

```bash
npm run build      # vite build -- public/dist/, hashed, with a manifest
moon sync
moon run build      # meteorite build -- bakes public/ into the server binary
./dist/server
```
]]

  return files
end

-- The base "meteorite" spa variant's single combined
-- `build = "... ballad play partiture.lua && meteorite build ..."` line
-- (templates/spa.lua) -- split apart so `meteorite build` (a real, separate
-- `moon run package` step) can run LAST, after Vite's stylesheet and the
-- postbuild link patch exist. Needed regardless of Tailwind now that Vite
-- is always applied to this template -- see this file's own header comment
-- for the real, verified reason: `meteorite build --mode release-hybrid`
-- bakes its static file inputs (including dist/index.html and
-- dist/assets/*) into the compiled server binary AT BUILD TIME.
local SPA_METEORITE_COMBINED_BUILD = 'build = "moon exec --dev -- ballad play partiture.lua '
  .. '&& meteorite build --mode release-hybrid --backend fast_http"'
local SPA_METEORITE_BUILD_SPLIT = 'build = "moon exec --dev -- ballad play partiture.lua"\n'
  .. 'package = "moon exec --dev -- meteorite build --mode release-hybrid --backend fast_http"'

local INJECT_LINK_SCRIPT = [[// Links this project's separately-built Vite stylesheet into
// dist/index.html, which hydronium_ballad's `hb.plugins.site` generates at
// `moon run build`/`moon run dev` time (see create/vite.lua's own header
// comment for why this CSS cannot go through that plugin's own single
// <link> slot instead). Run AFTER both a Ballad build (which must exist
// already) and `vite build` -- this npm "build" script runs it last, in
// that order.
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const INDEX_HTML = "dist/index.html";
const LINK_TAG = '<link rel="stylesheet" href="/assets/site.css">';

if (!existsSync(INDEX_HTML)) {
  console.error(
    `${INDEX_HTML} does not exist yet -- run \`moon run build\` (or \`moon run dev\`) first, ` +
      "so hydronium_ballad has generated it, before running this script."
  );
  process.exit(1);
}

const html = readFileSync(INDEX_HTML, "utf8");
if (html.includes(LINK_TAG)) {
  // Idempotent: re-running `npm run build` without an intervening Ballad
  // rebuild must not duplicate the tag.
  process.exit(0);
}
if (!html.includes("</head>")) {
  console.error(`${INDEX_HTML} has no </head> to inject the stylesheet link before.`);
  process.exit(1);
}
writeFileSync(INDEX_HTML, html.replace("</head>", `${LINK_TAG}\n</head>`));
]]

local function apply_spa(files, opts)
  local router = opts.router or "hydronium"

  -- Both router variants' `moon run dev` scripts are left untouched (no
  -- `hydronium dev --vite` wiring -- see this file's own header comment for
  -- why). The "meteorite" variant's `build` script needs splitting so
  -- `meteorite build` runs LAST -- see SPA_METEORITE_BUILD_SPLIT's own
  -- comment above.
  if router == "meteorite" then
    local toml, err = replace_once(files["moonstone.toml"], SPA_METEORITE_COMBINED_BUILD, SPA_METEORITE_BUILD_SPLIT)
    if not toml then error("create.vite: " .. tostring(err) .. " (spa meteorite build script anchor)", 2) end
    files["moonstone.toml"] = toml
  end

  files["src/styles.css"] = BASE_STYLES_CSS

  files["scripts/inject-vite-link.mjs"] = INJECT_LINK_SCRIPT

  files["package.json"] = string.format([[{
  "name": "%s-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "description": "Vite build for this project's browser-side CSS/assets -- run alongside its Lua/Ballad client bundle, not instead of it.",
  "scripts": {
    "dev": "vite build --watch",
    "build": "vite build && node scripts/inject-vite-link.mjs"
  },
  "devDependencies": {
    "vite": "^8.3.0"
  }
}
]], opts.name)

  files["vite.config.js"] = [[import { defineConfig } from "vite";

// CSS-only, exactly like ssr/islands' own Vite config (see create/vite.lua's
// own header comment) -- this project's actual client application is
// bundled separately by hydronium_ballad's real client bundler
// (partiture.lua), which this build never touches or replaces.
export default defineConfig({
  plugins: [],
  build: {
    outDir: "dist/assets",
    emptyOutDir: false,
    cssCodeSplit: true,
    rollupOptions: {
      input: "src/styles.css",
      output: { assetFileNames: "site.css" },
    },
  },
});
]]

  files[".gitignore"] = (files[".gitignore"] or "") .. "node_modules/\n"

  files["README.md"] = (files["README.md"] or "") .. [[

## Vite

Built separately from the Lua/Ballad bundle -- order matters:
]] .. (router == "meteorite" and [[
`meteorite build` bakes its static file inputs into the compiled server
binary, so it must run LAST, after Vite's stylesheet exists:

```bash
moon run build             # hydronium_ballad: produces dist/index.html
npm install
npm run build               # vite build, then links dist/assets/site.css in
moon run package            # meteorite build, LAST -- serves the final bytes
```
]] or [[
the Vite stylesheet gets linked into dist/index.html AFTER Ballad has
generated it:

```bash
moon run build              # hydronium_ballad: produces dist/index.html
npm install
npm run build                # vite build, then links dist/assets/site.css in
```
]])
end

--- Mutates `files` in place (and returns it) to add the base Vite build
--- alongside an `ssr`, `spa`, or `islands` scaffold. Errors loudly (does
--- not return nil, err) on a template this module doesn't know how to wire,
--- or if an anchor it expects has drifted -- both are programmer errors in
--- `create.scaffold`'s call site, not user input errors.
function M.apply(files, opts)
  opts = opts or {}
  if not M.supported_templates[opts.template] then
    error("create.vite: unsupported template '" .. tostring(opts.template) .. "' (expected ssr, spa, or islands)", 2)
  end
  opts.name = opts.name or "my-hydronium-app"

  if opts.template == "spa" then
    apply_spa(files, opts)
  elseif opts.template == "islands" then
    apply_islands(files, opts)
  elseif opts.template == "ssr" then
    apply_ssr(files, opts)
  else
    -- Unreachable given M.supported_templates above lists exactly these
    -- three and each has its own branch -- a real error, not dead code,
    -- if a future template is added to M.supported_templates without a
    -- branch here.
    error("create.vite: '" .. tostring(opts.template) .. "' is declared supported but has no apply_* branch -- programmer error", 2)
  end

  return files
end

return M
