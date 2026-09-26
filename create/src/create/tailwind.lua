--[[
  Additive Tailwind CSS v4 wiring for the `ssr`, `islands`, and `spa`
  templates -- a pure `files -> files` transform (same contract writer.lua's
  callers already expect), applied AFTER `create.vite` has already run (see
  create.init's own `create.scaffold`). Everything Vite-generic (package.json,
  vite.config.js's skeleton, the stylesheet <link>, the .gitignore/README
  Vite sections, spa's postbuild link-injector and moonstone.toml build-script
  split) lives in create/vite.lua now and is applied unconditionally to every
  ssr/spa/islands scaffold -- this module ONLY adds what Tailwind itself
  needs on top of that already-real Vite build:
    - the `tailwindcss`/`@tailwindcss/vite` devDependencies in package.json
    - registering the `@tailwindcss/vite` plugin in vite.config.js
    - rewriting `src/styles.css` (already Vite's build entry, wired up by
      create/vite.lua) to `@import "tailwindcss";` plus an explicit
      `@source` for this template's `.luax`/`.lua` files
  Per this task's own stated direction ("the package manager is needed for
  vite, tailwind is an additive"): this module never creates package.json or
  vite.config.js, never touches the Document (create/vite.lua already links
  the stylesheet Tailwind's CSS compiles into), and never resolves a package
  manager -- create.scaffold does all of that for every Vite template
  regardless of whether Tailwind is on.

  Ground truth for the Tailwind v4 + Vite wiring itself:
  hydronium/js/examples/islands-tailwind/{vite.config.js,src/styles.css,
  package.json} -- a real, verified `vite build` there proves
  `@tailwindcss/vite` needs no separate PostCSS config, and that Tailwind's
  automatic content detection does NOT see `.luax`/`.lua` files (they get
  scanned only via an explicit `@source`, since Tailwind has no built-in
  knowledge of those extensions).

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

-- Per-template location of this template's `.luax`/`.lua` view sources,
-- relative to `src/styles.css` (create/vite.lua always places the
-- Vite-built stylesheet there) -- purely for the `@source` directive
-- Tailwind's automatic content scanner needs (see this file's own header
-- comment: Tailwind cannot see `.luax`/plain `.lua` on its own).
local SOURCE_GLOB = {
  ssr = "./views/**/*.luax",
  islands = "../views/**/*.luax",
  spa = "./app.lua",
}

M.supported_templates = { ssr = true, islands = true, spa = true }

-- vite.config.js anchors -- exact text create/vite.lua's own generated
-- file always contains. `islands` has its own real plugin-based shape now
-- (create.vite's `apply_islands`, STEP 2 of
-- docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md); `ssr`/`spa` are still the
-- CSS-only `plugins: []` shape. The `// hydronium-vite-plugin` marker
-- (emitted unconditionally by apply_islands, regardless of Tailwind) is
-- what makes the island-list-dependent `hydronium({ islands: [...] })`
-- call anchorable without hardcoding its contents here.
local VITE_IMPORT_ANCHOR = 'import { defineConfig } from "vite";'
local TAILWIND_IMPORT = '\nimport tailwindcss from "@tailwindcss/vite";'
local EMPTY_PLUGINS = "plugins: [],"
local TAILWIND_PLUGIN = "plugins: [tailwindcss()],"
local ISLANDS_PLUGIN_MARKER = "// hydronium-vite-plugin"
local ISLANDS_PLUGIN_MARKER_WITH_TAILWIND = "// hydronium-vite-plugin\n    tailwindcss(),"

-- package.json anchor -- exact text create/vite.lua's own generated file
-- ends its devDependencies block with. `islands` additionally vendors
-- @hydronium-js/vite (see create.vite's own header comment); `ssr`/`spa`
-- do not yet.
local BASE_DEV_DEPENDENCIES = [["devDependencies": {
    "vite": "^8.3.0"
  }]]
local TAILWIND_DEV_DEPENDENCIES = [["devDependencies": {
    "vite": "^8.3.0",
    "tailwindcss": "^4.3.3",
    "@tailwindcss/vite": "^4.3.3"
  }]]
local ISLANDS_BASE_DEV_DEPENDENCIES = [["devDependencies": {
    "vite": "^8.3.0",
    "@hydronium-js/vite": "file:./vendor/hydronium-js-vite"
  }]]
local ISLANDS_TAILWIND_DEV_DEPENDENCIES = [["devDependencies": {
    "vite": "^8.3.0",
    "@hydronium-js/vite": "file:./vendor/hydronium-js-vite",
    "tailwindcss": "^4.3.3",
    "@tailwindcss/vite": "^4.3.3"
  }]]

local function tailwind_styles_css(source_glob)
  return string.format([[@import "tailwindcss";

/* Tailwind v4's automatic content detection only scans files it recognizes
   by extension -- `.luax`/plain `.lua` are not among them, so classes used
   only inside a view/component file never reach the scanner without an
   explicit @source. Mirrors the verified pattern in
   hydronium/js/examples/islands-tailwind/src/styles.css. Add more
   `@source` lines here as this project grows more views. */
@source "%s";
]], source_glob)
end

--- Mutates `files` in place (and returns it) to layer Tailwind CSS v4 on
--- top of the Vite base `create.vite.apply` already wrote. Errors loudly
--- (does not return nil, err) on a template this module doesn't know how
--- to wire, or if an anchor it expects has drifted (i.e. `create.vite`
--- wasn't actually applied first, or its output shape changed) -- both are
--- programmer errors in `create.scaffold`'s call site, not user input
--- errors, which is why they use `error()` rather than the `nil, err`
--- convention the rest of this package uses for user-facing failures.
function M.apply(files, opts)
  opts = opts or {}
  if not M.supported_templates[opts.template] then
    error("create.tailwind: unsupported template '" .. tostring(opts.template) .. "' (expected ssr, islands, or spa)", 2)
  end

  if not files["vite.config.js"] or not files["package.json"] then
    error("create.tailwind: no vite.config.js/package.json in the file set yet (was create.vite applied first?)", 2)
  end

  files["src/styles.css"] = tailwind_styles_css(SOURCE_GLOB[opts.template])

  local vite_config, err = insert_after(files["vite.config.js"], VITE_IMPORT_ANCHOR, TAILWIND_IMPORT)
  if not vite_config then error("create.tailwind: " .. tostring(err) .. " in vite.config.js (was create.vite applied first?)", 2) end
  if opts.template == "islands" then
    -- `islands`' plugins array already has a real `hydronium({ islands:
    -- [...] })` call (island list varies with the template, so it cannot
    -- be a fixed anchor) -- register Tailwind alongside it via the
    -- content-independent marker comment `apply_islands` always emits.
    vite_config, err = replace_once(vite_config, ISLANDS_PLUGIN_MARKER, ISLANDS_PLUGIN_MARKER_WITH_TAILWIND)
  else
    vite_config, err = replace_once(vite_config, EMPTY_PLUGINS, TAILWIND_PLUGIN)
  end
  if not vite_config then error("create.tailwind: " .. tostring(err) .. " in vite.config.js (was create.vite applied first?)", 2) end
  files["vite.config.js"] = vite_config

  local base_deps = opts.template == "islands" and ISLANDS_BASE_DEV_DEPENDENCIES or BASE_DEV_DEPENDENCIES
  local tailwind_deps = opts.template == "islands" and ISLANDS_TAILWIND_DEV_DEPENDENCIES or TAILWIND_DEV_DEPENDENCIES
  local package_json, pkg_err = replace_once(files["package.json"], base_deps, tailwind_deps)
  if not package_json then error("create.tailwind: " .. tostring(pkg_err) .. " in package.json (was create.vite applied first?)", 2) end
  files["package.json"] = package_json

  files["README.md"] = (files["README.md"] or "") .. [[

Tailwind CSS v4 is layered on top of the Vite build above: `@tailwindcss/vite`
is registered in `vite.config.js`, and `src/styles.css` (Vite's own build
entry) starts with `@import "tailwindcss";` plus an explicit `@source` for
this project's views.
]]

  return files
end

return M
