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

  NOT WIRED, having tried and verified why not: hydronium/cli's real,
  already-shipped `hydronium dev --vite` / `hydronium build --vite`
  (cli/src/main.lua) pair a `vite dev`/`vite build` (via `npx`, so
  `node_modules/.bin` resolves cwd-relatively) with Meteorite/Ballad. Tried
  both against this module's CSS-only Vite config (no HTML/JS entry of its
  own -- `rollupOptions.input` is a bare `.css` file) and found two real,
  verified problems, not hypothetical ones:
    1. `hydronium build --vite` runs `vite build` BEFORE the partiture
       (cli/src/main.lua's own `M.build`), and `hydronium_ballad.plugins.
       site`'s directory sink REMOVES its whole `out` tree before writing
       its own output -- so by the time that command returns, Vite's
       freshly-built asset has already been deleted by Ballad's own sink.
       Verified live: ran a full `spa` (`router = "meteorite"`) build with
       this wired in, `dist/assets/` only ever contained Ballad's own
       scoped CSS, never Vite's.
    2. `hydronium dev --vite`'s dual dev server is real value only when
       Vite owns the page's own HTML/JS module graph; these templates'
       pages are Meteorite's/Ballad's own static shell, and this Vite
       config has no HTML entry at all -- pairing a `vite dev` server here
       would start a real process that serves nothing the actual page ever
       requests.
  So the build here stays a plain, separate `vite build`/`vite build
  --watch`, run by the user's own package manager, which -- unlike `moon
  exec` or `hydronium build`/`dev` -- puts a project's own
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
]]

local M = {}

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

-- Per-template Document location for the document-based templates (ssr,
-- islands) -- where to insert the second stylesheet link. `spa` has no
-- editable Document source at all (see this file's own header comment),
-- so it is handled entirely separately by `apply_spa` below.
local DOCUMENT_KEY = {
  ssr = "src/views/Document.luax",
  islands = "views/Document.luax",
}

local STYLESHEET_LINK_ANCHOR = '<link rel="stylesheet" href="/public/style.css" />'
local VITE_LINK = '\n        <link rel="stylesheet" href="/public/dist/styles.css" />'

-- Placeholder content for the Vite-built stylesheet when Tailwind is off.
-- `create/tailwind.lua` OVERWRITES this file wholesale when Tailwind is
-- turned on (see that module's own header comment) -- this is only ever
-- what a plain, Tailwind-less Vite template starts with.
local BASE_STYLES_CSS = [[/* Built by Vite (see vite.config.js) into public/dist/styles.css, linked
   from the Document right after public/style.css. Add your own
   Vite-processed CSS/asset imports here. */
]]

local function apply_document_based(files, opts)
  local document_key = DOCUMENT_KEY[opts.template]
  local document = files[document_key]
  if not document then
    error("create.vite: template '" .. opts.template .. "' has no file at " .. document_key, 2)
  end
  local patched, err = insert_after(document, STYLESHEET_LINK_ANCHOR, VITE_LINK)
  if not patched then
    error("create.vite: " .. tostring(err) .. " in " .. document_key, 2)
  end
  files[document_key] = patched

  files["src/styles.css"] = BASE_STYLES_CSS

  files["package.json"] = string.format([[{
  "name": "%s-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "description": "Vite build for this project's browser-side CSS/assets -- run alongside its Lua build/dev server, not instead of it.",
  "scripts": {
    "dev": "vite build --watch",
    "build": "vite build"
  },
  "devDependencies": {
    "vite": "^8.3.0"
  }
}
]], opts.name)

  files["vite.config.js"] = [[import { defineConfig } from "vite";

// This build is deliberately CSS-only: there is no JS entry module in this
// project to hang a normal Vite <script> graph off of, so `src/styles.css`
// is the sole Rollup input, and the compiled result is emitted as a fixed,
// unhashed asset the Document links to directly -- no manifest lookup
// needed at request time.
export default defineConfig({
  plugins: [],
  // `publicDir: false` -- this project's `public/` is Meteorite's static
  // root, not Vite's: Vite's default behavior is to copy `publicDir`
  // wholesale into `build.outDir` on every build, which here would nest a
  // second copy of the whole `public/` tree under `public/dist/` (verified
  // with a real `vite build` -- confirmed by both the resulting file tree
  // and Vite's own "public directory feature may not work correctly"
  // warning once `outDir` sits inside `publicDir`, which it does here by
  // design so Meteorite can serve the compiled CSS with no extra route).
  publicDir: false,
  build: {
    outDir: "public/dist",
    emptyOutDir: true,
    cssCodeSplit: true,
    rollupOptions: {
      input: "src/styles.css",
      output: { assetFileNames: "styles.css" },
    },
  },
});
]]

  files[".gitignore"] = (files[".gitignore"] or "") .. "node_modules/\npublic/dist/\n"

  files["README.md"] = (files["README.md"] or "") .. [[

## Vite

A separate, plain `vite build` compiles `src/styles.css` into
`public/dist/styles.css`, linked from the Document right after
`public/style.css` -- deliberately independent of `moon run dev`/`moon run
build` (see create/vite.lua's own header comment for why `hydronium dev/
build --vite` is not wired in here):

```bash
npm install
npm run build   # or: npm run dev, to rebuild on change (vite build --watch)
```
]]
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
  else
    apply_document_based(files, opts)
  end

  return files
end

return M
