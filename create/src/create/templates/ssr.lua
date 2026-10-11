local ssr = {}

--[[
  Full-stack SSR template: real Meteorite + Hydronium API, verified live
  against a freshly scaffolded project (moon exec meteorite graph, zig
  build -Dmode=release-hybrid -Dbackend=std_http, ./dist/server, curl).

  Ground truth for every API shape below is
  hydronium/examples/quickstart/{src/main.lua, src/views/Document.lua,
  moonstone.toml} in the sibling hydronium checkout -- read those first if
  changing this file. Key facts that are NOT obvious from guessing at the
  API:

  - `meteorite.app({name, host, port})`, not `meteorite.create()`.
  - `meteorite.site(app, {root=..., assets={["/path/:p*"] = {dir=..., param="p"}}})`
    for static files -- there is no `meteorite.static` + `app:use(...)`.
  - `app:get(path, function(c) ... end)` -- ONE context arg, not (req, res).
  - Every `require(...)` a route handler needs must happen INSIDE the
    handler body. Meteorite's hybrid build "lifts" each inline Lua handler
    (extracts its own source text, reloads it standalone per request) --
    closing over an outer local fails the build with "inline Lua handler
    captures outer local". This is why views/Document.lua exists as its own
    requirable module instead of a `main.lua` upvalue.
  - Rendering goes through `require("hydronium_dom.server.meteorite").render(c,
    Document, {status=200, props={...}})` -- takes the COMPONENT (not a
    pre-built vnode) plus an options table with `props`; there is no
    `hydronium.render_to_string(...)` + `res:header()`/`res:send()` (that
    response API doesn't exist anywhere in this framework).
  - LUAX has no arrow-function syntax (`() => expr` fails to parse --
    verified directly against hydronium_luax.compile) -- every callback is
    `function() ... end`.
  - The SSR client-boundary guard (dom/src/hydronium_dom/server/init.lua,
    around the `onClick`/callback-prop handling) only recognizes a prop
    name whose 3rd byte is an uppercase ASCII letter (`onClick`, `onInput`,
    ...) -- `onclick` (lowercase) does NOT match, so a Lua function value on
    it is silently dropped by `html.serialize_attributes` (never an error,
    never rendered) instead of doing anything. But the inverse is also
    real and load-bearing: `onClick` (correctly-cased) with a Lua closure
    OUTSIDE a client-execution boundary is a hard render-time error ("Lua
    callback `onClick` requires a Lua client execution boundary"), verified
    directly by rendering both shapes.

  - UPDATED (previously this comment said Hydronium has no real Lua client
    hydration -- that was true for the specific pattern it was describing,
    inline `<d.lua.island>` markers inside an ordinary SSR page, which
    indeed still do not auto-hydrate: dropping one into a page and hoping
    a client runtime picks it up on its own does not work. But a
    DIFFERENT, real mechanism does: `hydronium_dom/client/mount.js` boots
    wasmoon (LuaJIT compiled to WASM) in the browser, fetches the
    project's own compiled Lua modules over HTTP via a manifest, and
    mounts a Lua component as the root of its own container with
    `d.lua.mount` -- verified live against
    hydronium/examples/meteorite_ssr/client_mount_demo (two real browser
    clicks drive two real Lua-closure `onClick` calls through the ordinary
    reconciler, with zero JS interactivity layer). This template now uses
    exactly that mechanism for its client application (views/App.luax,
    mounted into the `<div id="app">` in views/Document.luax) instead of the
    non-hydrating `<d.lua.island>` pattern -- clicking the button in a
    browser really does call Lua running client-side. The counter also
    uses a BARE `{count}` binding (not `{count()}`) as its text child, so
    each click patches only that text node directly via a fine-grained
    Hydronium DOM binding, without re-running the whole component.

  - Framework plumbing is not generated into the app. `main.lua` calls
    `require("hydronium_dom.server.meteorite").mount(app)`, which declares
    the browser runtime (`/js/bootstrap`, `/js/router`), framework source
    (`/hydronium-src`), the framework module manifest (derived from the
    project's real require graph -- no pasted client_manifest.json to drift),
    the dev module server (`/__hydronium/dev/module/:id`) and the HMR stream
    (`/__hydronium/watch`). Its Lua routes are `m.lua` file handlers shipped
    inside hydronium/dom, so Meteorite's hybrid lifting never sees a closure.
    This is dev/unbundled serving, not a production asset pipeline -- see
    hydronium/docs/BUNDLING.md.

  - HMR, not live reload (roadmap M2). `/__hydronium/watch` is built on
    `hydronium_dom.dev.watch` (real, reusable framework code) and now
    reports WHICH watched file moved, not merely that something did. The
    browser side is `hydronium_dom/client/hmr.js`: it re-fetches just that
    module's freshly compiled source, installs it as `package.preload[id]`
    in the SURVIVING wasmoon VM, and calls `family_loader.reload(id)` --
    so the counter keeps its value and its DOM nodes across an edit, with
    no page navigation. A full page reload is the explicit safety fallback
    when a requested hot swap cannot be proven to have worked.
    `dev_reload.js` remains the simpler client for a page with no Lua VM.

  - `hydronium.sources.lua` is the single watch declaration: the HMR stream
    and `hydronium.dev_watch()` both derive from it. Its `updates` policies
    reach the browser through `/__hydronium/dev/manifest.json`; application
    modules use `hot`, the document uses `reload`.

  - THE `dev` SCRIPT RUNS `hydronium dev`, NOT `meteorite dev` DIRECTLY.
    `hydronium dev` (hydronium/cli, declared as a `tool`
    dependency above alongside meteorite itself) spawns exactly the same
    `meteorite dev` invocation this template used to run inline, tails the
    structured dev-event stream meteorite writes to
    `.meteorite/dev/events.log`, mirrors it into a durable
    `.hydronium/dev.log`, and renders a live status view (plus a
    fullscreen request-debug view on `f`). `moon run dev` is unchanged for
    the user.

    The meteorite flags travel in ONE `--meteorite-args` value rather than as
    trailing arguments: `moon exec` forwards everything after its own `--`
    verbatim, including any further `--` the child wants for itself (verified:
    `moon exec -- printf '[%s]' -- -- x` prints `[--][--][x]`), so `--`
    passthrough would reach `hydronium dev` intact -- the actual risk is
    upstream, since `moon run` hands the script body to the host shell before
    Moonstone ever parses it. A `hydronium dev -- --mode ...` line would depend
    on shell quoting to keep those flags together across edits; a single named,
    single-quoted `--meteorite-args='...'` value arrives as ONE argument
    regardless. The environment variable
    `HYDRONIUM_METEORITE_ARGS` still overrides it for a one-off run
    without editing this file (its words are appended after the flag's,
    and meteorite takes the last occurrence of a flag).

  - Transformed UI source lives under `src/views/`. The scaffold classifies
    client leaf modules as Meteorite `passive`/`exclude` inputs, while the
    document and shared route definitions remain graph inputs. HMR therefore
    preserves client state without making server-visible source edits stale.
]]

function ssr.files(opts)
  opts = opts or {}
  local project_name = opts.name or "my-hydronium-app"
  local use_tailwind = opts.tailwind == true

  local files = {}

  -- NOTE: this literal must use the `[=[ ... ]=]` long-bracket level, not
  -- plain `[[ ... ]]` -- the content itself contains the substring
  -- "[[dependencies]]" (real TOML array-of-tables syntax), which would
  -- otherwise prematurely close a plain `[[` long string right after
  -- "[[dependencies" the first time it appears.
  files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "bin"
description = "Full-stack SSR application powered by Hydronium and Meteorite"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
dev = "moon exec --dev -- hydronium dev --watch-sources --meteorite-args='--mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit'"
build = "moon exec -- ballad play build.partiture.lua && moon exec --dev -- meteorite build --mode release-hybrid --backend fast_http --lua-root .moonstone/env/libexec/luajit"

[[dependencies]]
name = "moonstone/meteorite"
# 0.3 adds `meteorite client typescript|luacats` (typed DTOs from the route
# graph) on top of 0.2.9's dev-event request headers/bodies, which `hydronium
# dev`'s filter bar queries (mime:, origin:, header:, body:).
constraint = "^0.3.1"
role = "tool"

[[dependencies]]
name = "hydronium/cli"
constraint = "^0.4.2"
role = "tool"

[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.4.0"
role = "tool"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.12"
role = "runtime"

[[dependencies]]
name = "hydronium/luax"
constraint = "^0.2.14"
role = "runtime"

[[dependencies]]
name = "hydronium/dom"
constraint = "^0.3.13"
role = "runtime"

# Ballad plugins: partiture.lua discovers this project's Lua sources.
[[dependencies]]
name = "hydronium/ballad"
constraint = "^0.2.8"
role = "runtime"

[[dependencies]]
name = "hydronium/router"
constraint = "^0.2.3"
role = "runtime"
]=], project_name)

  -- `.hydronium/` holds `hydronium dev`'s own durable dev log and the
  -- spawned server's captured output -- local run artifacts, like
  -- `.meteorite/`.
  files[".gitignore"] = [[.moonstone/
dist/
.zig-cache/
zig-out/
.meteorite/
.hydronium/
*.log
]]

  -- Lua source discovery is a Ballad node. `hydronium dev --watch-sources`
  -- re-runs it when a file under a declared root appears or disappears;
  -- `moon run build` runs it before compiling the server.
  files["partiture.lua"] = [[-- Ballad discovers every .lua/.luax file under the roots declared in
-- hydronium.sources.lua and writes .hydronium/ballad/source-inventory.lua, the
-- module authority the Meteorite dev host (hydronium.mount) serves from.
local ballad = require("ballad")
local hb = require("hydronium_ballad")

return ballad.partiture(function(p)
  hb.source_inventory(p)
end)
]]

  -- Release build: discovery plus the production browser bundle. The server
  -- (hydronium.mount, release mode) serves the hashed chunk and pages boot
  -- from it instead of fetching modules one by one.
  files["build.partiture.lua"] = [[-- `moon run build` runs this before compiling the server: the source
-- inventory, then one content-hashed browser chunk with every client/shared
-- module declared in hydronium.sources.lua plus only the framework modules
-- they reach (.hydronium/client/).
local ballad = require("ballad")
local hb = require("hydronium_ballad")

return ballad.partiture(function(p)
  hb.source_inventory(p)
  hb.client_bundle(p)
end)
]]

  files["hydronium.sources.lua"] = [[-- Project-owned browser/source topology: which directories hold modules and
-- how edits to them apply. Ballad (partiture.lua) turns it into the explicit
-- inventory the dev host serves from, so no request ever scans the disk.
return {
  entry = "views.App",
  roots = {
    { path = "src/components", namespace = "components", target = "client", update = "hot", effects = "safe" },
    { path = "src/views", namespace = "views", target = "client", update = "hot", effects = "safe",
      transforms = { lua = "lua", luax = "luax" } },
  },
  entries = {
    { id = "views.App", path = "src/views/App.luax" },
    { id = "views.Document", path = "src/views/Document.luax", target = "server", update = "reload", effects = "restart" },
    { id = "views.Site", path = "src/views/Site.lua", target = "shared", update = "reload", effects = "restart" },
    { id = "views.Actions", path = "src/views/Actions.lua", target = "shared", update = "reload", effects = "restart" },
    { id = "views.loaders.Overview", path = "src/views/loaders/Overview.lua", target = "shared", update = "reload", effects = "restart" },
    { id = "views.loaders.Projects", path = "src/views/loaders/Projects.lua", target = "shared", update = "reload", effects = "restart" },
    { id = "views.loaders.Project", path = "src/views/loaders/Project.lua", target = "shared", update = "reload", effects = "restart" },
    { id = "views.DemoProjects", path = "src/views/DemoProjects.lua", target = "shared", update = "reload", effects = "restart" },
  },
}
]]

  -- Keep markup identical across styling choices. Tailwind projects get a
  -- semantic utility-class map scanned from this Lua source; plain projects
  -- get namespaced classes backed by public/style.css.
  if use_tailwind then
    files["src/views/Styles.lua"] = [[return {
  page = "min-h-screen bg-slate-50 text-slate-900",
  shell = "mx-auto grid min-h-screen max-w-[1440px] grid-cols-1 md:grid-cols-[232px_minmax(0,1fr)]",
  sidebar = "sticky top-0 hidden h-screen border-r border-slate-200 bg-white px-5 py-7 md:flex md:flex-col",
  brand = "mb-10 flex items-center gap-3 text-lg font-semibold tracking-tight text-slate-950",
  brand_mark = "grid size-10 place-items-center rounded-2xl bg-teal-700 text-sm font-bold text-white",
  brand_copy = "flex flex-col",
  brand_hint = "text-[11px] font-medium uppercase tracking-[0.16em] text-slate-400",
  nav_label = "mb-3 px-3 text-[11px] font-semibold uppercase tracking-[0.14em] text-slate-400",
  nav = "flex flex-col gap-1",
  nav_link = "rounded-xl px-3 py-2.5 text-sm font-medium text-slate-600 transition hover:bg-slate-100 hover:text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700",
  nav_link_active = "rounded-xl bg-teal-50 px-3 py-2.5 text-sm font-semibold text-teal-900 transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700",
  sidebar_footer = "mt-auto rounded-2xl border border-slate-200 bg-slate-50 p-4 text-xs leading-5 text-slate-500",
  main_column = "min-w-0",
  topbar = "flex min-h-16 items-center justify-between border-b border-slate-200 bg-white/90 px-5 sm:px-8",
  topbar_context = "text-sm font-medium text-slate-500",
  topbar_badge = "rounded-full border border-teal-200 bg-teal-50 px-3 py-1.5 text-xs font-semibold text-teal-900",
  mobile_nav = "flex gap-1 overflow-x-auto border-b border-slate-200 bg-white px-4 py-2 md:hidden",
  content = "mx-auto w-full max-w-6xl px-5 py-8 sm:px-8 lg:py-10",
  skip_link = "sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded-lg focus:bg-white focus:px-4 focus:py-3 focus:text-teal-900 focus:shadow-lg",
  page_header = "mb-8 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between",
  eyebrow = "mb-2 text-xs font-semibold uppercase tracking-[0.16em] text-teal-800",
  title = "text-3xl font-semibold tracking-tight text-slate-950 sm:text-4xl",
  description = "mt-2 max-w-2xl text-sm leading-6 text-slate-600 sm:text-base",
  primary_link = "inline-flex min-h-11 items-center justify-center rounded-xl bg-teal-800 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:bg-teal-900 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700",
  stats = "mb-6 grid gap-3 sm:grid-cols-3",
  stat = "rounded-2xl border border-slate-200 bg-white p-5 shadow-sm",
  stat_label = "text-xs font-medium text-slate-500",
  stat_value = "mt-3 block text-3xl font-semibold tracking-tight text-slate-950",
  stat_note = "mt-1 block text-xs text-slate-500",
  columns = "grid gap-5 xl:grid-cols-[minmax(0,1.6fr)_minmax(280px,0.9fr)]",
  panel = "rounded-2xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6",
  panel_header = "mb-5 flex items-center justify-between gap-4",
  panel_title = "text-base font-semibold tracking-tight text-slate-950",
  subtle_link = "text-sm font-semibold text-teal-800 underline decoration-teal-300 underline-offset-4 hover:text-teal-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700",
  project_list = "divide-y divide-slate-100",
  project_row = "-mx-2 flex items-center justify-between gap-4 rounded-xl px-2 py-4 transition hover:bg-slate-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700",
  project_name = "font-semibold text-slate-900",
  project_description = "mt-1 text-sm leading-5 text-slate-500",
  project_meta = "mt-3 flex flex-wrap items-center gap-2 text-xs text-slate-500",
  panel_spaced = "mt-5",
  tag = "rounded-full bg-slate-100 px-2.5 py-1 font-medium text-slate-600",
  status = "rounded-full px-2.5 py-1 text-xs font-semibold",
  status_active = "bg-teal-50 text-teal-900",
  status_review = "bg-amber-50 text-amber-900",
  status_done = "bg-slate-100 text-slate-600",
  activity_list = "space-y-4",
  activity_item = "flex gap-3",
  activity_dot = "mt-1.5 size-2 shrink-0 rounded-full bg-teal-600 ring-4 ring-teal-50",
  activity_text = "text-sm leading-5 text-slate-600",
  focus_row = "mt-5 flex items-center justify-between rounded-xl bg-slate-50 px-4 py-3",
  focus_label = "text-sm font-medium text-slate-600",
  counter = "flex items-center gap-2",
  counter_value = "min-w-7 text-center text-sm font-semibold tabular-nums text-slate-900",
  icon_button = "grid size-9 place-items-center rounded-lg border border-slate-200 bg-white text-lg font-medium text-slate-700 hover:border-teal-300 hover:text-teal-900 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700 disabled:cursor-not-allowed disabled:opacity-40",
  form = "mt-5 space-y-3 border-t border-slate-100 pt-5",
  field_label = "block text-sm font-medium text-slate-700",
  input = "mt-1.5 min-h-11 w-full rounded-xl border border-slate-300 bg-white px-3.5 py-2.5 text-sm text-slate-900 placeholder:text-slate-400 focus:border-teal-700 focus:outline-none focus:ring-2 focus:ring-teal-100 aria-invalid:border-rose-500 aria-invalid:ring-2 aria-invalid:ring-rose-100",
  submit = "inline-flex min-h-10 items-center justify-center rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700 disabled:opacity-50",
  feedback = "min-h-5 text-sm text-slate-600",
  detail_grid = "grid gap-5 lg:grid-cols-[minmax(0,1.5fr)_minmax(260px,0.8fr)]",
  detail_metric = "rounded-xl bg-slate-50 p-4",
  progress = "mt-3 h-2 overflow-hidden rounded-full bg-slate-100",
  progress_fill = "h-full rounded-full bg-teal-700 transition-[width] duration-300",
  empty = "rounded-xl border border-dashed border-slate-300 bg-slate-50 p-6 text-sm text-slate-600",
  error = "rounded-2xl border border-rose-200 bg-rose-50 p-6 text-rose-950",
}
]]
    files["public/style.css"] = [[:root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #17252b; background: #f6f8f8; }
* { box-sizing: border-box; }
body { min-width: 320px; min-height: 100vh; margin: 0; }
button, input { font: inherit; }
a { color: inherit; }
]]
  else
    files["src/views/Styles.lua"] = [[return {
  page = "app-page", shell = "app-shell", sidebar = "app-sidebar", brand = "app-brand",
  brand_mark = "app-brand-mark", brand_copy = "app-brand-copy", brand_hint = "app-brand-hint",
  nav_label = "app-nav-label", nav = "app-nav", nav_link = "app-nav-link", nav_link_active = "app-nav-link app-nav-link-active",
  sidebar_footer = "app-sidebar-footer", main_column = "app-main-column", topbar = "app-topbar",
  topbar_context = "app-topbar-context", topbar_badge = "app-topbar-badge", mobile_nav = "app-mobile-nav",
  content = "app-content", skip_link = "app-skip-link", page_header = "app-page-header", eyebrow = "app-eyebrow",
  title = "app-title", description = "app-description", primary_link = "app-primary-link", stats = "app-stats",
  stat = "app-stat", stat_label = "app-stat-label", stat_value = "app-stat-value", stat_note = "app-stat-note",
  columns = "app-columns", panel = "app-panel", panel_header = "app-panel-header", panel_title = "app-panel-title",
  subtle_link = "app-subtle-link", project_list = "app-project-list", project_row = "app-project-row",
  project_name = "app-project-name", project_description = "app-project-description", project_meta = "app-project-meta",
  panel_spaced = "app-panel-spaced", tag = "app-tag", status = "app-status", status_active = "app-status-active", status_review = "app-status-review",
  status_done = "app-status-done", activity_list = "app-activity-list", activity_item = "app-activity-item",
  activity_dot = "app-activity-dot", activity_text = "app-activity-text", focus_row = "app-focus-row",
  focus_label = "app-focus-label", counter = "app-counter", counter_value = "app-counter-value",
  icon_button = "app-icon-button", form = "app-form", field_label = "app-field-label", input = "app-input",
  submit = "app-submit", feedback = "app-feedback", detail_grid = "app-detail-grid",
  detail_metric = "app-detail-metric", progress = "app-progress", progress_fill = "app-progress-fill",
  empty = "app-empty", error = "app-error",
}
]]
  end

  -- Registry packages mount at `.moonstone/env/libexec/<namespace>/<package>`
  -- (Moonstone 0.5.9+; the flat `libexec/meteorite` alias is absent whenever
  -- another package, such as Lab's hydronium/meteorite, shares the name).
  -- Meteorite's collected Zig sources live one level below that root.
  files["build.zig"] = [[const std = @import("std");
const meteorite = @import(".moonstone/env/libexec/moonstone/meteorite/meteorite/zig/build_api.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = meteorite.addService(b, .{
        .meteorite_root = ".moonstone/env/libexec/moonstone/meteorite/meteorite",
        .lua_root = ".moonstone/env/libexec/luajit",
        .target = target,
        .optimize = optimize,
        .mode = b.option([]const u8, "mode", "Meteorite build mode") orelse "release-hybrid",
        .graph_input = b.option([]const u8, "graph-input", "Meteorite graph input") orelse "src/main.lua",
        .graph_output = b.option([]const u8, "graph-output", "Meteorite graph output") orelse ".meteorite/graph/current",
        .backend = b.option([]const u8, "backend", "Meteorite HTTP backend") orelse "std_http",
        .router_dispatch = b.option([]const u8, "router-dispatch", "Router dispatch strategy") orelse "method_buckets",
        .hybrid_profile = b.option([]const u8, "hybrid-profile", "Meteorite hybrid runtime profile") orelse "default",
    });
}
]]

  files["src/views/Document.luax"] = string.format([=[-- Stable server document boundary, analogous to Vite's index.html.
-- Application UI belongs in views/App.luax and refreshes inside the
-- surviving browser Lua VM. Editing this file intentionally reloads the page.

local H = require("hydronium")

local function Document(props)
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{props.title or "%s"}</title>
        <link rel="stylesheet" href="/public/style.css" />
      </head>
      <body>
        <div id="app">{props.app}</div>

        <script type="module">{[[
          import { mount } from "/js/bootstrap/mount.js";
          import { installHmr } from "/js/bootstrap/hmr.js";
          import { createHistoryGlobals } from "/js/router/history.js";
          import { createHttpGlobals } from "/js/router/http.js";
          import { createFormGlobals } from "/js/bootstrap/forms.js";

          window.__bootId = Math.random().toString(36).slice(2);
          const pageStateText = document.getElementById("__HYDRONIUM_STATE__")?.textContent;
          const routerState = pageStateText
            ? JSON.stringify(JSON.parse(pageStateText).hydronium_router)
            : undefined;
          const sourceResponse = await fetch("/__hydronium/dev/manifest.json", { cache: "no-store" });
          if (!sourceResponse.ok) throw new Error("Hydronium source manifest unavailable");
          const sourceManifest = await sourceResponse.json();
          const appModule = sourceManifest.modules[sourceManifest.entry];
          if (!appModule) throw new Error("Hydronium source manifest has no browser entry");
          const moduleUrls = Object.fromEntries(
            Object.entries(sourceManifest.modules).map(([id, record]) => [id, record.url]),
          );
          const moduleEffects = Object.fromEntries(
            Object.entries(sourceManifest.modules).map(([id, record]) => [id, record.effects]),
          );

          // Release builds with a Ballad bundle boot from its hashed chunk;
          // development (and unbundled builds) load modules one by one.
          const bundled = Array.isArray(sourceManifest.chunks) && sourceManifest.chunks.length > 0;
          const { lua, remount } = await mount({
            ...(bundled
              ? { chunkUrls: sourceManifest.chunks }
              : {
                  hydroniumBaseUrl: "/hydronium-src",
                  manifestUrl: "/__hydronium/client_manifest.json",
                  appModuleUrl: appModule.url,
                  moduleUrls,
                  moduleEffects,
                }),
            appModuleId: sourceManifest.entry,
            container: "#app",
            props: { title: "%s", initial: 0 },
            hydrate: true,
            hmr: true,
            luaGlobals: {
              ...createHistoryGlobals(),
              ...createHttpGlobals(),
              ...createFormGlobals(),
              __hydronium_router_state: routerState || undefined,
            },
          });

          // Release builds serve no HMR stream and say so in the manifest.
          if (sourceManifest.hmr !== false) installHmr({
            lua,
            remount,
            updates: {
              ...sourceManifest.updates,
              "hydronium.sources.lua": { action: "reload" },
            },
          });
        ]]}</script>
      </body>
    </html>
  )
end

return Document
]=], project_name, project_name)

  -- Compiles views/Document.luax on demand and returns the component function.
  -- Lives in its own requirable module (not a main.lua upvalue) for
  -- exactly the reason explained in this file's header comment and in
  -- hydronium/examples/quickstart/src/views/Document.lua, which this
  -- mirrors structurally: Meteorite's hybrid build lifts inline route
  -- handlers, so a handler cannot close over a `local App = require(...)`
  -- declared above it.


  files["src/app/page_handler.lua"] = string.format([[-- Hybrid request VMs have their own package loaders; install once at this entry.
require("hydronium_luax").loader.install()
local adapter = require("hydronium_router.meteorite")
local dom = require("hydronium_dom.server.meteorite")
local site = require("views.Site")

return adapter.handler(site, {
  resolve = require,
  resolve_loader = require,
  render = function(c, page, opts)
    local Document = require("views.Document")
    local d = require("hydronium_dom").d
    return dom.render(c, Document, {
      status = opts.status,
      state = opts.state,
      props = { title = "%s", app = d.lua.mount(page, { module = "views.App" }) },
    })
  end,
})
]], project_name)

  files["src/app/contact_action.lua"] = [[local H = require("hydronium.core")
local action = require("views.Actions").contact

return function(ctx)
  local valid, errors, output = action:check(ctx.values)
  if not valid then
    return H.action_fail({ values = ctx.values, errors = errors })
  end
  return H.action_ok({
    status = 201,
    data = { greeting = "Hello, " .. output.name },
  })
end
]]

  files["src/app/action_handler.lua"] = [[local adapter = require("hydronium_router.meteorite")
local site = require("views.Site")

return adapter.action_handler(site, {
  resolve_action = require,
})
]]

  files["src/views/Site.lua"] = [[local r = require("hydronium_router")

return r.createSite({
  root = r.node({
    id = "root",
    path = "/",
    screen = "views.Layout",
    error = "views.RouteError",
    children = {
      r.node({
        id = "home",
        path = "",
        screen = "views.Home",
        load = "views.loaders.Overview",
        pending = "views.Loading",
        actions = { contact = { id = "contact.submit", ref = "app.contact_action", path = "/actions/contact" } },
      }),
      r.node({ id = "projects", path = "projects", screen = "views.Projects", load = "views.loaders.Projects", pending = "views.Loading" }),
      r.node({ id = "project", path = "projects/:projectId", screen = "views.Project", load = "views.loaders.Project", pending = "views.Loading" }),
      r.node({ id = "about", path = "about", screen = "views.About" }),
    },
  }),
})
]]

  files["src/views/DemoProjects.lua"] = [[local projects = {
  {
    id = "hydronium", name = "Hydronium starter", category = "Framework",
    description = "A focused example app with routing, reactive UI, and server actions.",
    status = "In progress", progress = 72, owner = "Mira Chen", updated = "Updated today",
  },
  {
    id = "moonstone", name = "Moonstone package index", category = "Tooling",
    description = "Make package discovery and release workflows easier to follow.",
    status = "In review", progress = 48, owner = "Rafael Costa", updated = "Updated yesterday",
  },
  {
    id = "terminal-lab", name = "Terminal Lab refresh", category = "Product",
    description = "Bring the same clear project flow to the terminal experience.",
    status = "Complete", progress = 100, owner = "Noor Haddad", updated = "Updated Monday",
  },
}

local M = {}

function M.all()
  local copy = {}
  for index, project in ipairs(projects) do copy[index] = project end
  return copy
end

function M.find(id)
  for _, project in ipairs(projects) do
    if project.id == id then return project end
  end
  return nil
end

return M
]]

  files["src/views/loaders/Overview.lua"] = [[local demo_projects = require("views.DemoProjects")

return function()
  local projects = demo_projects.all()
  local stats = { active = 0, in_review = 0, completed = 0 }
  for _, project in ipairs(projects) do
    if project.status == "Complete" then
      stats.completed = stats.completed + 1
    elseif project.status == "In review" then
      stats.in_review = stats.in_review + 1
    else
      stats.active = stats.active + 1
    end
  end
  return {
    projects = projects,
    stats = stats,
    activity = {
      { text = "Mira moved Hydronium starter into implementation.", when = "Today, 10:42" },
      { text = "Rafael requested a review on the package index.", when = "Yesterday" },
      { text = "Noor completed the terminal layout pass.", when = "Monday" },
    },
  }
end
]]

  files["src/views/loaders/Projects.lua"] = [[local demo_projects = require("views.DemoProjects")

return function()
  return { projects = demo_projects.all() }
end
]]

  files["src/views/loaders/Project.lua"] = [[local r = require("hydronium_router")
local demo_projects = require("views.DemoProjects")

return function(ctx)
  local project = demo_projects.find(ctx.params.projectId)
  if not project then return r.routeError(404, "That project could not be found.") end
  return project
end
]]

  -- Meteorite owns HTTP; everything here is an ordinary Meteorite route.
  -- `hydronium.mount(app)` declares the framework's own routes (browser
  -- runtime, framework source, module manifest, dev module server, HMR
  -- stream) as file handlers shipped inside hydronium/dom, so none of that
  -- plumbing is copied into the application.
  files["src/main.lua"] = string.format([[-- Server entrypoint.
--
-- Meteorite owns HTTP: every route below is an ordinary Meteorite
-- declaration. Hydronium contributes three things to it:
--
--   1. `hydronium.mount(app)` -- the framework's own routes (browser runtime,
--      framework source, dev module server, HMR stream). Nothing to copy.
--   2. `router.mount(app, site, ...)` -- one GET per addressable page in
--      views/Site.lua, rendered by app/page_handler.lua, plus its form actions.
--   3. Plain route handlers -- any Meteorite route can render a Hydronium
--      component (see /hello/:name and app/hello.lua).
--
-- Handlers live in their own modules (`meteorite.lua("app.x")`) because
-- Meteorite's hybrid build loads each handler standalone per request; an
-- inline `function(c) ... end` must not capture locals from this file.
local meteorite = require("meteorite")
local hydronium = require("hydronium_dom.server.meteorite")
local router = require("hydronium_router.meteorite")
require("hydronium_luax").loader.install()

local app = meteorite.app({
  name = "%s",
  host = "127.0.0.1",
  port = tonumber(os.getenv("PORT")) or 8080,
  -- Hot UI modules declared in hydronium.sources.lua are passive: the browser
  -- swaps them in place, so editing one must not restart the server.
  dev_watch = hydronium.dev_watch(),
})

-- Before meteorite.site: Meteorite matches routes in declaration order, and in
-- development mount may serve watched stylesheets from disk at their own URL.
hydronium.mount(app)

meteorite.site(app, {
  root = ".",
  assets = {
    ["/public/:path*"] = { dir = "public", param = "path" },
  },
})

local site = require("views.Site")
router.mount(app, site, {
  handler = meteorite.lua("app.page_handler", { arg_mode = "lazy_context" }),
  action_handler = meteorite.lua("app.action_handler", { arg_mode = "lazy_context" }),
})

-- A plain Meteorite route rendering a Hydronium component: no router, no
-- browser VM. The component lives in src/features/, not src/views/.
app:get("/hello/:name", {
  summary = "Server-rendered greeting",
}, meteorite.lua("app.hello", { arg_mode = "lazy_context" }))

app:get("/api/health", { summary = "Health check" }, function(c)
  return c:json({ status = "ok", timestamp = os.time() })
end)

router.validate_final(app, site)

return app
]], project_name)

  files["src/app/hello.lua"] = [[-- A Meteorite route handler that renders a Hydronium component on the server.
-- Each hybrid request VM has its own package loaders, so install the LUAX
-- searcher at this entry before requiring a .luax module.
require("hydronium_luax").loader.install()
local dom = require("hydronium_dom.server.meteorite")
local Greeting = require("features.greeting.Greeting")

return function(c)
  return dom.render(c, Greeting, {
    props = { name = c:param("name") },
  })
end
]]

  files["src/features/greeting/Greeting.luax"] = [[-- Rendered by a plain Meteorite route (src/app/hello.lua). Components are
-- ordinary modules: they can live anywhere on the Lua path, not only views/.
local H = require("hydronium")
local d = require("hydronium_dom").d

local function Greeting(props)
  return (
    <d.html lang="en">
      <d.head>
        <d.meta charset="utf-8" />
        <d.title>Hello, {props.name}</d.title>
        <d.link rel="stylesheet" href="/public/style.css" />
      </d.head>
      <d.body>
        <d.main class="container">
          <d.h1>Hello, {props.name}!</d.h1>
          <d.p>
            This page is a plain Meteorite route whose handler renders a
            Hydronium component. <d.a href="/">Back to the app</d.a>
          </d.p>
        </d.main>
      </d.body>
    </d.html>
  )
end

return Greeting
]]

  -- The client application root. Keeping it separate from Document.luax
  -- makes normal layout edits hot-swappable instead of page reloads.
  files["src/views/App.luax"] = [[local H = require("hydronium.core.element")
local r = require("hydronium_router")
local site = require("views.Site")
local d = require("hydronium_dom").d

-- The site manifest stores logical IDs as strings. Resolve the same
-- components/loaders explicitly here so the production client bundle has
-- the complete route closure as well as the server source inventory.
local screens = {
  ["views.Layout"] = require("views.Layout"),
  ["views.Home"] = require("views.Home"),
  ["views.Projects"] = require("views.Projects"),
  ["views.Project"] = require("views.Project"),
  ["views.About"] = require("views.About"),
  ["views.Loading"] = require("views.Loading"),
  ["views.RouteError"] = require("views.RouteError"),
  ["views.NotFound"] = require("views.NotFound"),
}
local loaders = {
  ["views.loaders.Overview"] = require("views.loaders.Overview"),
  ["views.loaders.Projects"] = require("views.loaders.Projects"),
  ["views.loaders.Project"] = require("views.loaders.Project"),
}

local function App()
  local router = site:createRouter({
    history = r.createBrowserHistory(),
    resolve = function(id) return assert(screens[id], "Unknown screen: " .. tostring(id)) end,
    resolve_loader = function(id) return assert(loaders[id], "Unknown loader: " .. tostring(id)) end,
  })

  return function()
    return d.lua.mount(H.h(router.Provider, nil,
      H.h(r.Outlet, { notFound = screens["views.NotFound"] })
    ), { module = "views.App" })
  end
end

return App
]]

  files["src/views/Layout.luax"] = [[local H = require("hydronium.core.element")
local r = require("hydronium_router")
local styles = require("views.Styles")
local d = require("hydronium_dom").d

local function Layout(props)
  local router = r.useRouter()
  local navigate = r.useNavigate()
  local function link(path, label, active)
    return d.a({
      href = path,
      class = active and styles.nav_link_active or styles.nav_link,
      ["aria-current"] = active and "page" or nil,
      onNavigate = function() navigate(path) end,
    }, label)
  end

  return function(current_props)
    current_props = current_props or props
    local match = router.match()
    local active = {
      overview = match and match.id == "home",
      projects = match and (match.id == "projects" or match.id == "project"),
      about = match and match.id == "about",
    }
    return d.div({ class = styles.page },
      d.a({ href = "#main-content", class = styles.skip_link }, "Skip to content"),
      d.div({ class = styles.shell },
        d.aside({ class = styles.sidebar },
          d.a({ href = "/", class = styles.brand, onNavigate = function() navigate("/") end },
            d.span({ class = styles.brand_mark, ["aria-hidden"] = "true" }, "h"),
            d.span({ class = styles.brand_copy },
              d.span({}, "Hydronium"),
              d.span({ class = styles.brand_hint }, "Project desk")
            )
          ),
          d.p({ class = styles.nav_label }, "WORKSPACE"),
          d.nav({ class = styles.nav, ["aria-label"] = "Primary navigation" },
            link("/", "Overview", active.overview),
            link("/projects", "Projects", active.projects),
            link("/about", "About", active.about)
          ),
          d.p({ class = styles.sidebar_footer }, "A small, working Hydronium app. Explore a route, follow its loader, then try the progressive form.")
        ),
        d.div({ class = styles.main_column },
          d.header({ class = styles.topbar },
            d.p({ class = styles.topbar_context }, "Workspace  /  Project desk"),
            d.span({ class = styles.topbar_badge }, "LOCAL DEMO")
          ),
          d.nav({ class = styles.mobile_nav, ["aria-label"] = "Primary navigation" },
            link("/", "Overview", active.overview),
            link("/projects", "Projects", active.projects),
            link("/about", "About", active.about)
          ),
          d.main({ id = "main-content", class = styles.content }, current_props.outlet)
        )
      )
    )
  end
end

return Layout
]]

  files["src/views/Home.luax"] = string.format([[local H = require("hydronium.core.element")
local r = require("hydronium_router")
local styles = require("views.Styles")
local Counter = require("views.Counter")
local actions = require("views.Actions")
local d = require("hydronium_dom").d

local function Home()
  local data = r.useRouteData("home")
  local navigate = r.useNavigate()
  local form = require("hydronium.core.form").useForm(actions.contact, { enhance = true })

  return function()
    local loaded = data:value() or { projects = {}, stats = {}, activity = {} }
    local projects, activity = {}, {}
    for _, project in ipairs(loaded.projects or {}) do
      local status_class = project.status == "Complete" and styles.status_done
        or project.status == "In review" and styles.status_review or styles.status_active
      projects[#projects + 1] = d.a({
        key = project.id, href = "/projects/" .. project.id, class = styles.project_row,
        onNavigate = function() navigate("/projects/" .. project.id) end,
      },
        d.div({},
          d.p({ class = styles.project_name }, project.name),
          d.p({ class = styles.project_description }, project.description),
          d.p({ class = styles.project_meta },
            d.span({ class = styles.tag }, project.category),
            d.span({}, project.updated)
          )
        ),
        d.span({ class = styles.status .. " " .. status_class }, project.status)
      )
    end
    for index, item in ipairs(loaded.activity or {}) do
      activity[#activity + 1] = d.li({ key = index, class = styles.activity_item },
        d.span({ class = styles.activity_dot, ["aria-hidden"] = "true" }),
        d.div({},
          d.p({ class = styles.activity_text }, item.text),
          d.p({ class = styles.stat_note }, item.when)
        )
      )
    end

    return d.div({},
      d.header({ class = styles.page_header },
        d.div({},
          d.p({ class = styles.eyebrow }, "YOUR WORK, IN ONE PLACE"),
          d.h1({ class = styles.title }, "Welcome to %s"),
          d.p({ class = styles.description }, "A compact project workspace that demonstrates Hydronium routes, loader data, reactive state, and server actions.")
        ),
        d.a({ href = "/projects", class = styles.primary_link, onNavigate = function() navigate("/projects") end }, "Browse projects")
      ),
      d.section({ class = styles.stats, ["aria-label"] = "Workspace summary" },
        d.article({ class = styles.stat }, d.span({ class = styles.stat_label }, "Active projects"), d.strong({ class = styles.stat_value }, tostring(loaded.stats.active or 0)), d.span({ class = styles.stat_note }, "Across your workspace")),
        d.article({ class = styles.stat }, d.span({ class = styles.stat_label }, "In review"), d.strong({ class = styles.stat_value }, tostring(loaded.stats.in_review or 0)), d.span({ class = styles.stat_note }, "Ready for a second look")),
        d.article({ class = styles.stat }, d.span({ class = styles.stat_label }, "Completed"), d.strong({ class = styles.stat_value }, tostring(loaded.stats.completed or 0)), d.span({ class = styles.stat_note }, "Small steps add up"))
      ),
      d.div({ class = styles.columns },
        d.section({ class = styles.panel },
          d.div({ class = styles.panel_header },
            d.h2({ class = styles.panel_title }, "Recent projects"),
            d.a({ href = "/projects", class = styles.subtle_link, onNavigate = function() navigate("/projects") end }, "View all")
          ),
          #projects > 0 and d.div({ class = styles.project_list }, (table.unpack or unpack)(projects))
            or d.p({ class = styles.empty }, "No projects yet. Add one to get started.")
        ),
        d.div({},
          d.section({ class = styles.panel },
            d.div({ class = styles.panel_header }, d.h2({ class = styles.panel_title }, "Latest activity")),
            d.ul({ class = styles.activity_list }, (table.unpack or unpack)(activity))
          ),
          d.section({ class = styles.panel .. " " .. styles.panel_spaced },
            d.div({ class = styles.panel_header },
              d.div({}, d.h2({ class = styles.panel_title }, "Focus blocks"), d.p({ class = styles.stat_note }, "A tiny reactive signal example"))
            ),
            d.div({ class = styles.focus_row }, d.span({ class = styles.focus_label }, "Today"), H.h(Counter, { initial = 3 }))
          ),
          d.section({ class = styles.panel .. " " .. styles.panel_spaced },
            d.div({ class = styles.panel_header }, d.h2({ class = styles.panel_title }, "Send a quick hello")),
            d.form({ class = styles.form, method = form.props.method, action = form.props.action, onSubmit = form.props.onSubmit },
              d.label({ class = styles.field_label }, "Your name",
              d.input({
                id = "name", name = "name", autocomplete = "name", placeholder = "e.g. Alex", class = styles.input,
                ["aria-describedby"] = "contact-feedback",
                ["aria-invalid"] = form:error("name") and "true" or nil,
              })
              ),
              d.button({ class = styles.submit, type = "submit", disabled = form:pending() }, function() return form:pending() and "Sending…" or "Send hello" end),
              d.p({ id = "contact-feedback", class = styles.feedback, role = "status", ["aria-live"] = "polite" }, function() return form:error("name") or form:error("_form") or (form:data() and form:data().greeting) or "" end)
            )
          )
        )
      )
    )
  end
end

return Home
]], project_name)

  files["src/views/Projects.luax"] = [[local r = require("hydronium_router")
local styles = require("views.Styles")
local d = require("hydronium_dom").d

local function Projects()
  local data = r.useRouteData("projects")
  local navigate = r.useNavigate()
  return function()
    local rows = {}
    for _, project in ipairs((data:value() or {}).projects or {}) do
      rows[#rows + 1] = d.a({ key = project.id, href = "/projects/" .. project.id, class = styles.project_row,
        onNavigate = function() navigate("/projects/" .. project.id) end },
        d.div({}, d.p({ class = styles.project_name }, project.name), d.p({ class = styles.project_description }, project.description)),
        d.span({ class = styles.tag }, project.category)
      )
    end
    return d.section({},
      d.header({ class = styles.page_header }, d.div({}, d.p({ class = styles.eyebrow }, "THE WORKSPACE"), d.h1({ class = styles.title }, "Projects"), d.p({ class = styles.description }, "Open a project to see route parameters and loader-backed detail data."))),
      d.div({ class = styles.panel }, #rows > 0 and d.div({ class = styles.project_list }, (table.unpack or unpack)(rows)) or d.p({ class = styles.empty }, "No projects are available."))
    )
  end
end

return Projects
]]

  files["src/views/Project.luax"] = [[local r = require("hydronium_router")
local styles = require("views.Styles")
local d = require("hydronium_dom").d

local function Project()
  local data = r.useRouteData("project")
  local navigate = r.useNavigate()
  return function()
    local project = data:value()
    if not project then return d.p({ class = styles.empty, ["aria-live"] = "polite" }, "Loading project…") end
    local status_class = project.status == "Complete" and styles.status_done
      or project.status == "In review" and styles.status_review or styles.status_active
    return d.section({},
      d.p({}, d.a({ href = "/projects", class = styles.subtle_link, onNavigate = function() navigate("/projects") end }, "← All projects")),
      d.header({ class = styles.page_header },
        d.div({}, d.p({ class = styles.eyebrow }, project.category), d.h1({ class = styles.title }, project.name), d.p({ class = styles.description }, project.description)),
        d.span({ class = styles.status .. " " .. status_class }, project.status)
      ),
      d.div({ class = styles.detail_grid },
        d.section({ class = styles.panel },
          d.h2({ class = styles.panel_title }, "Project pulse"),
          d.p({ class = styles.description }, "This page is selected by the route manifest. The loader reads the project ID from the URL and returns the matching record."),
          d.div({ class = styles.focus_row }, d.span({ class = styles.focus_label }, "Progress"), d.strong({}, tostring(project.progress) .. "%")),
          d.div({
            class = styles.progress, role = "progressbar", ["aria-label"] = "Project completion",
            ["aria-valuemin"] = 0, ["aria-valuemax"] = 100, ["aria-valuenow"] = project.progress,
          }, d.div({ class = styles.progress_fill, style = { width = tostring(project.progress) .. "%" } }))
        ),
        d.aside({ class = styles.panel },
          d.h2({ class = styles.panel_title }, "Project details"),
          d.div({ class = styles.detail_metric }, d.p({ class = styles.stat_label }, "Project lead"), d.p({ class = styles.project_name }, project.owner)),
          d.p({ class = styles.stat_note }, project.updated)
        )
      )
    )
  end
end

return Project
]]

  files["src/views/Loading.luax"] = [[local styles = require("views.Styles")
local d = require("hydronium_dom").d

return function()
  return d.p({ class = styles.empty, role = "status", ["aria-live"] = "polite" }, "Loading workspace data…")
end
]]

  files["src/views/RouteError.luax"] = [[local styles = require("views.Styles")
local d = require("hydronium_dom").d

return function(props)
  local message = props.error and props.error.message or "Something went wrong while loading this page."
  return d.section({ class = styles.error, role = "alert" },
    d.p({ class = styles.eyebrow }, "ROUTE ERROR"),
    d.h1({ class = styles.panel_title }, "We could not open that page"),
    d.p({}, message),
    d.a({ href = "/", class = styles.subtle_link }, "Return to the overview")
  )
end
]]

  files["src/views/NotFound.luax"] = [[local styles = require("views.Styles")
local d = require("hydronium_dom").d

return function(props)
  local path = props.location and props.location.path or "this address"
  return d.section({ class = styles.error, role = "status" },
    d.p({ class = styles.eyebrow }, "404 · NOT FOUND"),
    d.h1({ class = styles.panel_title }, "That page is not here"),
    d.p({}, "No route matches " .. path .. ". Check the URL or head back to the overview."),
    d.a({ href = "/", class = styles.subtle_link }, "Return to the overview")
  )
end
]]

  files["src/views/About.luax"] = [[local r = require("hydronium_router")
local styles = require("views.Styles")
local d = require("hydronium_dom").d

local function About()
  local navigate = r.useNavigate()
  return function()
    return d.section({},
      d.header({ class = styles.page_header },
        d.div({}, d.p({ class = styles.eyebrow }, "BUILT WITH HYDRONIUM"), d.h1({ class = styles.title }, "A small app, real framework paths"), d.p({ class = styles.description }, "The pages, data, and form on this starter are ordinary Hydronium modules—not a screenshot or a mock UI.")),
        d.a({ href = "/", class = styles.primary_link, onNavigate = function() navigate("/") end }, "Back to overview")
      ),
      d.div({ class = styles.columns },
        d.article({ class = styles.panel }, d.h2({ class = styles.panel_title }, "Routes and loaders"), d.p({ class = styles.description }, "The shared site manifest drives server routes and browser navigation. Project pages use route parameters and loader resources.")),
        d.article({ class = styles.panel }, d.h2({ class = styles.panel_title }, "Progressive actions"), d.p({ class = styles.description }, "The hello form submits as ordinary HTML first, then uses the same validated action without a page navigation after hydration."))
      )
    )
  end
end

return About
]]

  files["src/views/Actions.lua"] = [[local H = require("hydronium.core")

local name_schema = {
  ["~standard"] = {
    validate = function(values)
      if type(values.name) ~= "string" or values.name:match("^%s*$") then
        return { issues = { { path = { { key = "name" } }, message = "Enter your name" } } }
      end
      return { value = values }
    end,
  },
}

return {
  contact = H.action({
    id = "contact.submit",
    path = "/actions/contact",
    method = "POST",
    schema = name_schema,
  }),
}
]]

-- The real, client-executed component -- compiled on demand by
-- src/main.lua's /__hydronium/dev/module route, fetched over HTTP by
-- mount.js, and run live in the browser Lua VM.
  --
  -- Edit this file while `moon run dev` is up and the running page is
  -- hot-swapped in place: the signal keeps its current value and its DOM
  -- nodes are never remounted. Try changing the increment.
  --
  -- Note what this file does NOT contain: any HMR annotation. The state
  -- is declared as an ordinary `signals.createSignal(...)`, and
  -- hydronium_luax's compile-time refresh pass rewrites it into the
  -- descriptor form the refresh registry matches on
  -- (`scope.refresh_registry:signal(v, {kind, name, block_path})`) --
  -- which is what earlier versions of this template had to hand-write.
  -- Two conditions make the pass recognize it, both satisfied here and
  -- both easy to break by accident: the setup function takes a parameter
  -- literally named `scope`, and the declaration is a two-name
  -- destructure at the setup function's top level (not inside the
  -- returned render function, an `if`, or a loop).
  --
  -- Uses a BARE `{count}` binding as the display's text child (not
  -- `{count()}`, called), so each click patches only that text node via a
  -- fine-grained Hydronium DOM binding effect instead of re-running this
  -- whole component -- ground truth for this being the default, not
  -- opt-in, behavior is
  -- hydronium/core/src/hydronium/core/reconciler.lua's
  -- Reconciler:_bindReactiveText.
  --
  -- `local H = ...` is deliberate. Compiled LUAX emits `H.h(...)` for
  -- every element, resolved as an ordinary Lua name -- so a file-level
  -- `local H` satisfies it directly, and the browser VM never has to
  -- fetch the whole `hydronium` barrel (which pulls in the test renderer)
  -- just to supply a global one.
  files["src/views/Counter.luax"] = [[local H = require("hydronium.core.element")
local dom = require("hydronium_dom")
local signals = require("hydronium.signals")
local styles = require("views.Styles")
local d = dom.d

local function Counter(props, scope)
  local count, setCount = signals.createSignal(props.initial or 0)

  return function()
    return (
      <d.div class={styles.counter}>
        <d.button class={styles.icon_button} type="button" aria-label="Decrease focus blocks" disabled={count() <= 0} onClick={function() setCount(count() - 1) end}>−</d.button>
      <d.output class={styles.counter_value} aria-live="polite">{count}</d.output>
      <d.button class={styles.icon_button} type="button" aria-label="Increase focus blocks" onClick={function() setCount(count() + 1) end}>+</d.button>
      </d.div>
    )
  end
end

return Counter
]]

  if not use_tailwind then
    files["public/style.css"] = [[:root {
  color-scheme: light;
  font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  color: #17252b;
  background: #f5f8f7;
  --ink: #17252b;
  --muted: #66777b;
  --line: #e1e9e7;
  --surface: #fff;
  --accent: #087f78;
  --accent-soft: #e4f4f1;
}
* { box-sizing: border-box; }
body { min-width: 320px; min-height: 100vh; margin: 0; background: #f5f8f7; }
button, input { font: inherit; }
a { color: inherit; text-decoration: none; }
h1, h2, p { margin-top: 0; }
.app-page { min-height: 100vh; color: var(--ink); }
.app-shell { display: grid; min-height: 100vh; max-width: 1440px; margin: 0 auto; grid-template-columns: 232px minmax(0, 1fr); }
.app-sidebar { position: sticky; top: 0; display: flex; height: 100vh; flex-direction: column; border-right: 1px solid var(--line); background: var(--surface); padding: 28px 20px; }
.app-brand { display: flex; align-items: center; gap: 12px; margin: 0 0 42px; color: #152729; font-size: 18px; font-weight: 700; letter-spacing: -.03em; }
.app-brand-mark { display: grid; width: 40px; height: 40px; place-items: center; border-radius: 15px; background: var(--accent); color: white; font-size: 17px; }
.app-brand-copy { display: flex; flex-direction: column; gap: 3px; }
.app-brand-hint, .app-nav-label { color: #859394; font-size: 10px; font-weight: 700; letter-spacing: .15em; }
.app-nav-label { margin: 0 0 12px 12px; }
.app-nav { display: flex; flex-direction: column; gap: 4px; }
.app-nav-link { display: flex; align-items: center; min-height: 42px; border-radius: 12px; padding: 0 12px; color: #5c6c70; font-size: 14px; font-weight: 600; transition: background .15s, color .15s; }
.app-nav-link:hover, .app-nav-link-active { background: var(--accent-soft); color: #075d59; }
.app-nav-link:focus-visible, .app-mobile-nav a:focus-visible, .app-primary-link:focus-visible, .app-subtle-link:focus-visible, .app-project-row:focus-visible, .app-icon-button:focus-visible, .app-submit:focus-visible { outline: 3px solid #54b9ae; outline-offset: 2px; }
.app-sidebar-footer { margin-top: auto; border: 1px solid var(--line); border-radius: 16px; background: #f7faf9; padding: 14px; color: var(--muted); font-size: 12px; line-height: 1.55; }
.app-main-column { min-width: 0; }
.app-topbar { display: flex; min-height: 64px; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--line); background: rgba(255,255,255,.92); padding: 0 34px; }
.app-topbar-context { margin: 0; color: #768487; font-size: 13px; font-weight: 550; }
.app-topbar-badge { border: 1px solid #cce7e2; border-radius: 999px; background: #eff9f7; padding: 6px 11px; color: #116a63; font-size: 10px; font-weight: 750; letter-spacing: .09em; }
.app-mobile-nav { display: none; }
.app-content { width: min(100%, 1160px); margin: 0 auto; padding: 38px 34px 56px; }
.app-skip-link { position: absolute; left: -9999px; top: 8px; z-index: 10; }
.app-skip-link:focus { left: 8px; border-radius: 8px; background: white; padding: 12px 16px; box-shadow: 0 4px 20px #0002; color: #075d59; }
.app-page-header { display: flex; align-items: end; justify-content: space-between; gap: 24px; margin-bottom: 28px; }
.app-eyebrow { margin: 0 0 8px; color: #08766e; font-size: 10px; font-weight: 750; letter-spacing: .15em; }
.app-title { margin: 0; color: #17252b; font-size: clamp(28px, 4vw, 38px); font-weight: 680; letter-spacing: -.045em; line-height: 1.12; }
.app-description { max-width: 620px; margin: 10px 0 0; color: #68797c; font-size: 14px; line-height: 1.65; }
.app-primary-link, .app-submit { display: inline-flex; min-height: 42px; align-items: center; justify-content: center; border: 0; border-radius: 12px; background: #116f68; padding: 0 16px; color: white; font-size: 13px; font-weight: 700; cursor: pointer; transition: background .15s, transform .15s; }
.app-primary-link:hover, .app-submit:hover { background: #0b5f59; transform: translateY(-1px); }
.app-stats { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; margin-bottom: 20px; }
.app-stat, .app-panel { border: 1px solid var(--line); border-radius: 17px; background: var(--surface); box-shadow: 0 4px 14px rgba(25, 57, 55, .035); }
.app-stat { padding: 18px 20px; }
.app-stat-label { color: #77878a; font-size: 12px; font-weight: 550; }
.app-stat-value { display: block; margin-top: 12px; color: #1a3032; font-size: 30px; font-weight: 680; letter-spacing: -.04em; line-height: 1; }
.app-stat-note { margin: 6px 0 0; color: #899597; font-size: 11px; line-height: 1.5; }
.app-columns { display: grid; grid-template-columns: minmax(0, 1.55fr) minmax(265px, .85fr); align-items: start; gap: 17px; }
.app-panel { min-width: 0; padding: 20px; }
.app-panel-spaced { margin-top: 16px; }
.app-panel-header { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
.app-panel-title { margin: 0; color: #1b2d30; font-size: 15px; font-weight: 680; letter-spacing: -.015em; }
.app-subtle-link { color: #08766e; font-size: 12px; font-weight: 700; text-decoration: underline; text-decoration-color: #b4dcd5; text-underline-offset: 4px; }
.app-project-list { display: flex; flex-direction: column; }
.app-project-row { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin: 0 -8px; border-radius: 12px; padding: 15px 8px; transition: background .15s; }
.app-project-row + .app-project-row { border-top: 1px solid #edf1f0; }
.app-project-row:hover { background: #f8fbfa; }
.app-project-name { margin: 0; color: #233538; font-size: 13px; font-weight: 650; }
.app-project-description { margin: 4px 0 0; color: #78878a; font-size: 12px; line-height: 1.5; }
.app-project-meta { display: flex; align-items: center; gap: 8px; margin: 9px 0 0; color: #929e9f; font-size: 10px; }
.app-tag { border-radius: 999px; background: #f0f4f3; padding: 4px 8px; color: #637377; font-weight: 650; }
.app-status { flex: 0 0 auto; border-radius: 999px; padding: 6px 9px; font-size: 10px; font-weight: 700; }
.app-status-active { background: #e8f6f1; color: #197158; }
.app-status-review { background: #fff4df; color: #8c6417; }
.app-status-done { background: #eff2f1; color: #687779; }
.app-activity-list { display: flex; flex-direction: column; gap: 17px; margin: 0; padding: 0; list-style: none; }
.app-activity-item { display: flex; gap: 11px; }
.app-activity-dot { flex: 0 0 auto; width: 7px; height: 7px; margin: 5px 2px 0; border-radius: 50%; background: #16877e; box-shadow: 0 0 0 4px #e6f4f1; }
.app-activity-text { margin: 0; color: #58696d; font-size: 12px; line-height: 1.5; }
.app-focus-row { display: flex; align-items: center; justify-content: space-between; margin-top: 14px; border-radius: 12px; background: #f6f9f8; padding: 9px 12px; }
.app-focus-label { color: #66777b; font-size: 12px; font-weight: 600; }
.app-counter { display: flex; align-items: center; gap: 8px; }
.app-counter-value { min-width: 24px; color: #1b3032; font-size: 13px; font-weight: 700; text-align: center; }
.app-icon-button { display: grid; width: 32px; height: 32px; place-items: center; border: 1px solid #dfe8e6; border-radius: 9px; background: white; color: #44575a; font-size: 16px; cursor: pointer; }
.app-icon-button:hover { border-color: #9ccfc7; color: #08766e; }
.app-icon-button:disabled { cursor: not-allowed; opacity: .4; }
.app-form { display: grid; gap: 10px; margin-top: 16px; border-top: 1px solid #edf1f0; padding-top: 16px; }
.app-field-label { display: grid; gap: 7px; color: #526367; font-size: 12px; font-weight: 650; }
.app-input { width: 100%; min-height: 42px; border: 1px solid #d8e2df; border-radius: 10px; background: white; padding: 0 12px; color: #17252b; font-size: 13px; }
.app-input::placeholder { color: #a2adad; }
.app-input:focus { border-color: #16877e; outline: 3px solid #def2ee; }
.app-input[aria-invalid="true"] { border-color: #d35e5b; }
.app-submit { justify-self: start; min-height: 38px; background: #24383b; font-size: 12px; }
.app-submit:hover { background: #10282a; }
.app-submit:disabled { cursor: wait; opacity: .55; }
.app-feedback { min-height: 18px; margin: 0; color: #617276; font-size: 12px; }
.app-detail-grid { display: grid; grid-template-columns: minmax(0, 1.5fr) minmax(260px, .8fr); gap: 18px; }
.app-detail-metric { margin-top: 16px; border-radius: 12px; background: #f6f9f8; padding: 15px; }
.app-progress { height: 8px; overflow: hidden; margin-top: 12px; border-radius: 999px; background: #edf2f0; }
.app-progress-fill { height: 100%; border-radius: inherit; background: #16877e; transition: width .3s; }
.app-empty { border: 1px dashed #cbd9d5; border-radius: 13px; background: #f7faf9; padding: 18px; color: #647477; font-size: 13px; }
.app-error { border: 1px solid #f2c9c4; border-radius: 16px; background: #fff6f4; padding: 22px; color: #743d37; }
@media (max-width: 820px) {
  .app-shell { grid-template-columns: minmax(0, 1fr); }
  .app-sidebar { display: none; }
  .app-mobile-nav { display: flex; gap: 4px; overflow-x: auto; border-bottom: 1px solid var(--line); background: white; padding: 8px 16px; }
  .app-mobile-nav a { flex: 0 0 auto; border-radius: 9px; padding: 9px 12px; color: #5c6c70; font-size: 12px; font-weight: 650; }
  .app-mobile-nav a:hover, .app-mobile-nav a.app-nav-link-active { background: var(--accent-soft); color: #075d59; }
  .app-topbar { padding: 0 20px; }
  .app-content { padding: 28px 20px 40px; }
}
@media (max-width: 640px) {
  .app-stats { grid-template-columns: 1fr; }
  .app-stat { display: grid; grid-template-columns: 1fr auto; align-items: center; gap: 5px 12px; padding: 14px 16px; }
  .app-stat-value { grid-column: 2; grid-row: 1 / span 2; margin: 0; font-size: 25px; }
  .app-stat-note { margin: 0; }
  .app-columns, .app-detail-grid { grid-template-columns: minmax(0, 1fr); }
  .app-page-header { align-items: flex-start; flex-direction: column; }
  .app-panel { padding: 17px; }
}
]]
  end

  files["README.md"] = string.format([[# %s

Full-stack SSR application built with [Hydronium](https://moonstone.sh/packages/hydronium) and [Meteorite](https://moonstone.sh/packages/meteorite). The first screen is a small project workspace, not a blank shell: it has loader-backed overview/project routes, a progressive form action, and a compact reactive signal example.

The generated manifest uses registry packages. No sibling source checkout is
required. If you are testing unreleased packages, add a local Moonstone
registry before running `moon sync`.

## Routes and actions

Meteorite owns HTTP. `src/main.lua` is an ordinary Meteorite app with three
kinds of routes:

- **Framework routes** -- `hydronium.mount(app)` declares the browser runtime,
  framework source and the dev/HMR endpoints. You never edit these.
- **Pages** -- `src/views/Site.lua` is the page manifest. The browser creates a
  reactive router from it; `hydronium_router.meteorite` lowers the same route
  leaves to explicit Meteorite GET routes rendered by `src/app/page_handler.lua`.
- **Your routes** -- anything else is a normal Meteorite route. A handler can
  return JSON (`/api/health`) or render any Hydronium component on the server:
  `/hello/:name` is handled by `src/app/hello.lua`, which renders
  `src/features/greeting/Greeting.luax`. Components can live anywhere on the
  Lua path.

`src/views/Actions.lua` defines the shared `contact.submit` action. The form in
`src/views/Home.luax` works as a normal HTML POST before hydration. Once the browser
Lua VM is ready, the same form validates through its Standard Schema contract,
submits in the background, consumes a JSON action result without navigation,
and exposes pending,
field-error, and result state through `useForm`.

`views/loaders/Overview.lua`, `Projects.lua`, and `Project.lua` provide local
demo data to the `/`, `/projects`, and `/projects/:projectId` routes. The
project detail loader handles an unknown ID as a route error. This seed data is
intentionally in-memory example data, not a persistent database integration.

## Styling

The default scaffold uses semantic class names and `public/style.css`, with a
small token palette and responsive layout. If you scaffold with `--tailwind`,
the same view components use Tailwind utility classes from `views/Styles.lua`
and Vite scans that Lua source. Edit the generated implementation you chose;
there is no component-style runtime or hidden CSS abstraction.

## Reactive UI and hot reloading

`src/views/App.luax` is the hot application root and `src/views/Counter.luax` is
its child. Both run **in your browser**, as Lua. `src/views/Document.luax` is
the stable server-rendered shell that boots the VM, analogous to Vite's
`index.html`.

With `moon run dev` running, edit `src/views/Counter.luax` and save. The page
does **not** reload. The signal keeps the
value it was already showing, its DOM nodes are never remounted, and the
next click uses the new logic.

Nothing in `src/views/Counter.luax` opts into that. Its state is an ordinary
`signals.createSignal(...)`; hydronium's LUAX compiler attaches the
descriptor that makes the value survive a swap. Two things do have to hold
for it to be recognized, and both are easy to break by accident:

- the setup function takes a parameter literally named `scope`;
- the signal is declared as `local x, setX = ...` at the setup function's
  top level -- not inside the returned render function, an `if`, or a loop.

Break either and nothing errors: that signal simply resets to its initial
value on each edit, exactly as it would have before this feature existed.

Edit `src/views/App.luax` and the counter state survives while the application
layout refreshes. Editing `public/style.css` replaces the stylesheet in
place. Only `src/views/Document.luax` is an explicit page-reload boundary.

## Getting Started

1. **Install Dependencies:**
   ```bash
   moon sync
   ```

2. **Start Dev Server:**
   ```bash
   moon run dev
   ```

   This runs `hydronium dev`, which starts the Meteorite dev server with
   this project's own `--mode`/`--backend`/`--lua-root` flags (they live in
   the `dev` script in `moonstone.toml`) and renders its dev-event stream
   live. Keys: `f` opens a fullscreen request inspector (every request,
   with status, duration and remote address), `esc` leaves it, `q` quits.
   Every event is also appended to `.hydronium/dev.log`.

3. **Build for Production:**
   ```bash
   moon run build
   ./dist/server
   ```
]], project_name)

  return files
end

return ssr
