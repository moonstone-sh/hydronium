--[[
  Additive Tailwind CSS v4 (+ Vite) wiring for the `ssr`, `islands`, and
  `spa` templates. A pure `files -> files` transform (same contract
  writer.lua's callers already expect): never touches disk itself, only
  mutates the in-memory file table `create.scaffold` is about to hand to
  `writer.write_project`. That keeps `create.scaffold` a pure function of
  its options table.

  Ground truth for the Vite + Tailwind v4 wiring itself:
  hydronium/js/examples/islands-tailwind/{vite.config.js,src/styles.css,
  package.json} -- a real, verified `vite build` there proves
  `@tailwindcss/vite` needs no separate PostCSS config, and that Tailwind's
  automatic content detection does NOT see `.luax`/`.lua` files (they get
  scanned only via an explicit `@source`, since Tailwind has no built-in
  knowledge of those extensions).

  NOT WIRED, having tried and verified why not: hydronium/cli's real,
  already-shipped `hydronium dev --vite` / `hydronium build --vite`
  (cli/src/main.lua) pair a `vite dev`/`vite build` (via `npx`, so
  `node_modules/.bin` resolves cwd-relatively) with Meteorite/Ballad.
  Tried both against this template's CSS-only Vite config (no HTML/JS
  entry of its own -- `rollupOptions.input` is a bare `.css` file) and
  found two real, verified problems, not hypothetical ones:
    1. `hydronium build --vite` runs `vite build` BEFORE the partiture
       (cli/src/main.lua's own `M.build`), and `hydronium_ballad.plugins.
       site`'s directory sink REMOVES its whole `out` tree before writing
       its own output (its own doc comment: "p.sink.directory removes its
       out tree first") -- so by the time that command returns, Vite's
       freshly-built `dist/assets/tailwind.css` has already been deleted
       by Ballad's own sink. Verified live: ran the full `spa`
       (`router = "meteorite"`) build with this wired in, `dist/assets/`
       only ever contained Ballad's own scoped CSS, never Tailwind's.
    2. `hydronium dev --vite`'s dual dev server is real value only when
       Vite owns the page's own HTML/JS module graph (as in
       `js/examples/islands-tailwind`, where Vite serves `index.html`
       itself); this template's page is Meteorite's/Ballad's own static
       shell, and this Vite config has no HTML entry at all -- pairing a
       `vite dev` server here would start a real process that serves
       nothing the actual page ever requests.
  So Tailwind's build here stays what M1 originally verified: a plain,
  separate `vite build`/`vite build --watch`, run by `npm`, which -- unlike
  `moon exec` or `hydronium build`/`dev` -- puts a project's own
  `node_modules/.bin` on PATH itself.

  THE `spa` TEMPLATE NEEDS A DIFFERENT INTEGRATION STRATEGY than
  `ssr`/`islands`, because it has no editable "Document" source file --
  `hydronium_ballad.plugins.site`'s `site.manifest(...)` GENERATES
  `dist/index.html` itself at build time (see
  build/src/hydronium_ballad/plugins/site.lua's `render_index_html`), with
  exactly one `<link rel="stylesheet">` slot tied to its own
  `hb.plugins.style` output -- no "extra head content" option. Feeding
  Tailwind's compiled CSS through `hb.plugins.style` instead is not an
  option either: that plugin REWRITES every `.class-name` occurrence into
  a scoped hash (`hydronium_dom.css.scope_class`, see that file's own doc
  comment), which would mangle every one of Tailwind's plain utility class
  names the compiled markup actually uses. So for `spa`, Tailwind's CSS is
  built entirely separately (the same real `vite build` as ssr/islands)
  and linked into the ALREADY-BUILT `dist/index.html` with a small, real
  postbuild patch (`scripts/inject-tailwind-link.mjs`) that fails loudly,
  not silently, if `dist/index.html` does not exist yet (i.e. `moon run
  build`/`moon run dev` has not produced it).

  NOT independently verified end-to-end against a real `npm install &&
  npm run build` for every combination this module produces -- see
  create/tests/create_spec.lua and this task's own final report for
  exactly which combinations WERE run for real (scaffold -> install ->
  build -> serve -> curl) versus checked only for syntactic validity.
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

-- Per-template knowledge of where the Document lives and where its
-- `.luax` view sources are, relative to `src/styles.css` (this module
-- always places the stylesheet at `src/styles.css`).
local DOCUMENT_TEMPLATE_INFO = {
  ssr = {
    document_key = "src/views/Document.luax",
    source_glob = "./views/**/*.luax",
  },
  islands = {
    document_key = "views/Document.luax",
    source_glob = "../views/**/*.luax",
  },
}

M.supported_templates = { ssr = true, islands = true, spa = true }

local STYLESHEET_LINK_ANCHOR = '<link rel="stylesheet" href="/public/style.css" />'
local TAILWIND_LINK = '\n        <link rel="stylesheet" href="/public/dist/styles.css" />'

local function apply_document_based(files, opts, project_name)
  local info = DOCUMENT_TEMPLATE_INFO[opts.template]
  local document = files[info.document_key]
  if not document then
    error("create.tailwind: template '" .. opts.template .. "' has no file at " .. info.document_key, 2)
  end
  local patched, err = insert_after(document, STYLESHEET_LINK_ANCHOR, TAILWIND_LINK)
  if not patched then
    error("create.tailwind: " .. tostring(err) .. " in " .. info.document_key, 2)
  end
  files[info.document_key] = patched

  -- `ssr`'s and `islands`'s own dev/build scripts (`hydronium dev
  -- --meteorite-args=...` / `meteorite build ...`) are left untouched --
  -- see this file's own header comment for why `hydronium dev/build
  -- --vite` was tried and is NOT wired in here. Tailwind's production CSS
  -- is `npm run build` (a plain `vite build`), a separate, documented
  -- step -- verified for real (`npm install && npm run build` against a
  -- real scaffolded ssr+tailwind project).

  files["src/styles.css"] = string.format([[@import "tailwindcss";

/* Tailwind v4's automatic content detection only scans files it recognizes
   by extension -- `.luax` is not one of them, so classes used only inside
   a `.luax` view never reach the scanner without an explicit @source.
   Mirrors the verified pattern in
   hydronium/js/examples/islands-tailwind/src/styles.css. Add more
   `@source` lines here as this project grows more `.luax` views. */
@source "%s";
]], info.source_glob)

  files[".gitignore"] = (files[".gitignore"] or "") .. "node_modules/\npublic/dist/\n"
end

-- The base "meteorite" spa variant's single combined
-- `build = "... ballad play partiture.lua && meteorite build ..."` line
-- (templates/spa.lua) -- split apart when --tailwind is on, so
-- `meteorite build` (a real, separate `moon run package` step) can run
-- LAST, after Tailwind's stylesheet and postbuild link patch exist.
local SPA_METEORITE_COMBINED_BUILD = 'build = "moon exec --dev -- ballad play partiture.lua '
  .. '&& meteorite build --mode release-hybrid --backend fast_http"'
local SPA_METEORITE_BUILD_SPLIT = 'build = "moon exec --dev -- ballad play partiture.lua"\n'
  .. 'package = "moon exec --dev -- meteorite build --mode release-hybrid --backend fast_http"'

local function apply_spa(files, opts, project_name)
  local router = opts.router or "hydronium"

  -- Both router variants' `moon run dev` scripts are left untouched (no
  -- `hydronium dev --vite` wiring -- see this file's own header comment
  -- for why: this Vite config has no HTML/JS entry for `vite dev` to
  -- usefully serve). Tailwind's CSS is a plain, separate `vite build`
  -- (see package.json's own "build" script below).
  --
  -- The "meteorite" variant's `build` script DOES need splitting, and
  -- this is a real, verified fix, not a hypothetical one: `meteorite
  -- build --mode release-hybrid` bakes its static file inputs (including
  -- dist/index.html and dist/assets/*) into the compiled server binary AT
  -- BUILD TIME (verified live -- running `meteorite build` before `npm
  -- run build` produced a server that 404'd on /assets/tailwind.css
  -- despite the file existing on disk; re-running `meteorite build` alone
  -- afterward fixed it with no other change). So `meteorite build` must
  -- run LAST, as its own `moon run package` step, after both Ballad and
  -- Vite/the postbuild patch have produced their final bytes.
  if router == "meteorite" then
    local toml, err = replace_once(files["moonstone.toml"], SPA_METEORITE_COMBINED_BUILD, SPA_METEORITE_BUILD_SPLIT)
    if not toml then error("create.tailwind: " .. tostring(err) .. " (spa meteorite build script anchor)", 2) end
    files["moonstone.toml"] = toml
  end

  -- Verified for real, both router variants: scaffold -> moon sync ->
  -- moon run build (Ballad) -> npm install && npm run build (vite build +
  -- the postbuild patch) -> (meteorite variant only) moon run package
  -- (meteorite build, LAST) -> served/ran the result -> curl'd
  -- index.html, the Tailwind stylesheet, the compiled Lua chunk, and
  -- mount.js, all 200. Also verified live that @source "./app.lua" really
  -- scans a plain .lua file: a class added to app.lua appeared in the
  -- built Tailwind CSS, and an unused one did not.

  files["src/styles.css"] = [[@import "tailwindcss";

/* Tailwind v4's automatic content detection only scans files it
   recognizes by extension -- plain `.lua` is not one of them (this
   template has no `.luax`/HTML at all), so classes used only inside
   app.lua's `d.<tag>({ class = "..." }, ...)` calls never reach the
   scanner without an explicit @source. Add more `@source` lines here as
   this project grows more `.lua` view files. */
@source "./app.lua";
]]

  -- `hb.plugins.site`'s generated dist/index.html has exactly one
  -- <link rel="stylesheet"> slot, tied to its own hb.plugins.style
  -- output -- see this file's own header comment for why Tailwind's CSS
  -- cannot go through that plugin instead, and must be linked into the
  -- ALREADY-BUILT dist/index.html by a small, real postbuild step.
  files["scripts/inject-tailwind-link.mjs"] = [[// Links this project's separately-built Tailwind stylesheet into
// dist/index.html, which hydronium_ballad's `hb.plugins.site` generates
// at `moon run build`/`moon run dev` time (see create/tailwind.lua's own
// header comment for why Tailwind's CSS cannot go through that plugin's
// own single <link> slot instead). Run AFTER both a Ballad build (which
// must exist already) and `vite build` -- this npm "build" script runs it
// last, in that order.
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const INDEX_HTML = "dist/index.html";
const LINK_TAG = '<link rel="stylesheet" href="/assets/tailwind.css">';

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
  console.error(`${INDEX_HTML} has no </head> to inject the Tailwind stylesheet link before.`);
  process.exit(1);
}
writeFileSync(INDEX_HTML, html.replace("</head>", `${LINK_TAG}\n</head>`));
]]

  files[".gitignore"] = (files[".gitignore"] or "") .. "node_modules/\n"

  files["README.md"] = (files["README.md"] or "") .. [[

## Tailwind CSS v4

Built separately from the Lua/Ballad bundle -- order matters:
]] .. (router == "meteorite" and [[
`meteorite build` bakes its static file inputs into the compiled server
binary, so it must run LAST, after Tailwind's stylesheet exists:

```bash
moon run build           # hydronium_ballad: produces dist/index.html
npm install
npm run build             # vite build, then links dist/assets/tailwind.css in
moon run package          # meteorite build, LAST -- serves the final bytes
```
]] or [[
the Tailwind stylesheet gets linked into dist/index.html AFTER Ballad has
generated it:

```bash
moon run build            # hydronium_ballad: produces dist/index.html
npm install
npm run build              # vite build, then links dist/assets/tailwind.css in
```
]])
end

--- Mutates `files` in place (and returns it) to add a Tailwind v4 + Vite
--- build alongside an `ssr`, `islands`, or `spa` scaffold. Errors loudly
--- (does not return nil, err) on a template this module doesn't know how
--- to wire, or if an anchor it expects has drifted -- both are
--- programmer errors in `create.scaffold`'s call site, not user input
--- errors, which is why they use `error()` rather than the `nil, err`
--- convention the rest of this package uses for user-facing failures.
function M.apply(files, opts)
  opts = opts or {}
  if not M.supported_templates[opts.template] then
    error("create.tailwind: unsupported template '" .. tostring(opts.template) .. "' (expected ssr, islands, or spa)", 2)
  end
  local project_name = opts.name or "my-hydronium-app"

  if opts.template == "spa" then
    apply_spa(files, opts, project_name)
  else
    apply_document_based(files, opts, project_name)
  end

  files["package.json"] = string.format([[{
  "name": "%s-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "description": "Tailwind CSS v4 build for this project -- run alongside its Lua build/dev server, not instead of it.",
  "scripts": {
    "dev": "vite build --watch",
    "build": "%s"
  },
  "devDependencies": {
    "vite": "^8.3.0",
    "tailwindcss": "^4.3.3",
    "@tailwindcss/vite": "^4.3.3"
  }
}
]], project_name, opts.template == "spa" and "vite build && node scripts/inject-tailwind-link.mjs" or "vite build")

  files["vite.config.js"] = string.format([[import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";

// Tailwind v4 via its own Vite plugin -- no separate PostCSS config file
// needed (see @tailwindcss/vite). This build is deliberately CSS-only:
// there is no JS entry module in this project to hang a normal Vite
// <script> graph off of, so `src/styles.css` is the sole Rollup input,
// and the compiled result is emitted as a fixed, unhashed asset the
// generated project links to directly -- no manifest lookup needed at
// request time.
export default defineConfig({
  plugins: [tailwindcss()],
%s});
]], opts.template == "spa" and [[  build: {
    outDir: "dist/assets",
    emptyOutDir: false,
    cssCodeSplit: true,
    rollupOptions: {
      input: "src/styles.css",
      output: { assetFileNames: "tailwind.css" },
    },
  },
]] or [[  // `publicDir: false` -- this project's `public/` is Meteorite's static
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
]])

  return files
end

return M
