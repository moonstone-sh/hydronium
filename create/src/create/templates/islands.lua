local islands = {}
local look = require("create.look")

--[[
  Islands template: a mostly-static SSR shell with ONE real, working
  interactive island -- built on the JS-island path, the only hydration
  mechanism genuinely proven end-to-end in this ecosystem today (verified
  live: build -> run -> real browser -> click -> DOM text actually
  changes). The previous version of this template had a `hydration="client"`
  prop on its counter that nothing ever read -- no real hydration wiring
  existed at all, making "islands" a misleading name for what was actually
  a fully static page. This version has none of that: the counter really
  hydrates.

  Ground truth, all read directly from the sibling hydronium checkout
  (do not guess at these shapes):
  - hydronium/examples/meteorite_ssr/src/main.lua's `/mixed` route: the
    `d.js.island` usage pattern (`h(d.js.island, {module=..., hydrate=...,
    props={...}}, h(JsCounter, {...}))`) and how it's served
    (meteorite.site's `assets` table).
  - hydronium/examples/js_island/counter.js: the real hydrate(context)/
    dispose(context) ABI this template's own counter.js implements.
  - hydronium/dom/src/hydronium_dom/client/bootstrap.js and its siblings
    boundary_registry.js and priority.js: the real client bootstrap that reads
    `__HYDRONIUM_CLIENT_PLAN__` and dynamically imports a JS island's
    module. Both files are shipped here as real, self-contained copies
    under public/js/bootstrap/ -- this template does NOT reach back into
    the hydronium checkout's own client directory the way
    the internal example does (that example deliberately serves its own
    framework source for a "look, no build step" proof; a generated
    project resolves its Hydronium modules through Moonstone dependencies).

  The `dev` script runs `hydronium dev` (hydronium/cli) around the same
  `meteorite dev` invocation it used to run inline, passing the meteorite flags
  through one `--meteorite-args` value -- see ssr.lua's own header comment for
  the full reasoning (short version: `moon run` hands the script body to the
  host shell before Moonstone parses it, so a single named, quoted value
  survives shell requoting better than `--` passthrough would), and the CLI adds
  a live status view plus a fullscreen request-debug view over meteorite's dev-
  event stream).

  Same base fixes as ssr.lua also apply here (see that file's own header
  comment for exhaustive detail): meteorite.app/meteorite.site/app:get
  real API, requires inside handler bodies only, dependency-based module
  resolution, the TOML array-of-tables dependency header (double square
  brackets around "dependencies", not a single-bracket table), no arrow
  functions, and no hand-written .luarc.json (luals.configure owns that
  file).
]]

function islands.files(opts)
  local project_name = opts.name or "my-hydronium-islands"
  local files = {}

  -- See ssr.lua's own comment on why this must be `[=[ ... ]=]`, not
  -- plain `[[ ... ]]` -- the content contains the literal substring
  -- "[[dependencies]]".
  files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "bin"
description = "Hydronium Islands architecture with SSR and real JS-island client hydration"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
dev = "moon exec --dev -- hydronium dev --meteorite-args='--mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit'"
build = "moon exec --dev -- meteorite build --mode release-hybrid --backend fast_http --lua-root .moonstone/env/libexec/luajit"

[[dependencies]]
name = "moonstone/meteorite"
# 0.3 adds `meteorite client typescript|luacats` (typed DTOs from the route
# graph) on top of 0.2.9's dev-event request headers/bodies, which `hydronium
# dev`'s filter bar queries (mime:, origin:, header:, body:).
constraint = "^0.3.5"
role = "tool"

[[dependencies]]
name = "hydronium/cli"
constraint = "^0.4.2"
role = "tool"

[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.4.2"
role = "tool"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.10"
role = "runtime"

[[dependencies]]
name = "hydronium/luax"
constraint = "^0.2.11"
role = "runtime"

[[dependencies]]
name = "hydronium/dom"
constraint = "^0.3.12"
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

  -- Registry package layout matches the SSR template.
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

  -- Four views, all under src/views/ (on the Lua path, so `require`
  -- finds them): the HTML shell, the layout, and two pages.
  files["src/views/Document.luax"] = string.format([[-- The HTML shell. It loads the island bootstrap and, in development, the
-- live-reload client. Everything visible is src/views/App.luax.
local H = require("hydronium")
local d = require("hydronium_dom").d
local App = require("views.App")

local function Document(props)
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>%s</title>
        <link rel="stylesheet" href="/public/style.css" />
      </head>
      <body>
        <div class="glow" aria-hidden="true"></div>
        <script type="module" src="/public/ui/starter.js"></script>
        <App path={props.path} page={props.page} />
        {H.h("script", { type = "module" }, "import { activate } from '/js/bootstrap/bootstrap.js'; activate();")}
        {H.h("script", { type = "module", src = "/js/bootstrap/dev_reload.js" })}
      </body>
    </html>
  )
end

return Document
]], project_name)

  files["src/views/App.luax"] = string.format([[-- The layout around every page. Edit it with `moon run dev` running and the
-- page reloads with your change.
local H = require("hydronium")
local d = require("hydronium_dom").d

local function App(props)
  local function link(href, label)
    return <d.a href={href} aria-current={props.path == href and "page" or nil}>{label}</d.a>
  end

  return (
    <d.div class="shell">
      <d.header class="top">
        <d.a class="brand" href="/"><d.span class="mark">H₃O⁺</d.span> %s</d.a>
        <d.nav>{link("/", "Home")}{link("/about", "About")}</d.nav>
      </d.header>
      <d.main class="stage">{props.page}</d.main>
      <d.footer class="foot">Edit <d.code>src/views/App.luax</d.code> to see the changes.</d.footer>
    </d.div>
  )
end

return App
]], project_name)

  files["src/views/Home.luax"] = [[-- A plain HTML form: "Say hello" posts to /hello and the server renders this
-- page again with the greeting. The counter is a JavaScript island
-- (public/js/island/counter.js): rendered here, then hydrated in the browser.
local H = require("hydronium")
local d = require("hydronium_dom").d

-- The island's server markup; it must be exactly one root element.
local function Counter(props)
  return <d.span class="counter" role="group" aria-label="Times" data-testid="js-counter"><d.button type="button" aria-label="Fewer" disabled={props.times <= 1}>−</d.button><d.output class="count">{tostring(props.times)}</d.output><d.button type="button" aria-label="More" disabled={props.times >= 9}>+</d.button><d.input type="hidden" name="times" value={tostring(props.times)} /></d.span>
end

local function Home(props)
  local times = props.times or 3
  return (
    <d.form class="hello" method="post" action="/hello">
      <d.h1 class="line">Say hello to <d.input class="name" id="name" name="name" placeholder="Ada" autocomplete="off" aria-label="Name" value={props.name} /> <d.js.island module="/js/island/counter.js" hydrate="load" props={{ times = times }}><Counter times={times} /></d.js.island> times.</d.h1>
      <d.button class="send" type="submit">Say hello</d.button>
      <d.p class={props.error and "result error" or "result"} aria-live="polite">{props.error or props.greeting or ""}</d.p>
    </d.form>
  )
end

return Home
]]

  files["src/views/About.luax"] = [[local H = require("hydronium")
local d = require("hydronium_dom").d

local function About()
  return (
    <d.section class="hello">
      <d.h1 class="line">About</d.h1>
      <d.p class="lede">Meteorite renders every page on the server. Only the counter ships JavaScript: it is an island, hydrated by <d.code>public/js/bootstrap/bootstrap.js</d.code>. Everything else is plain HTML.</d.p>
    </d.section>
  )
end

return About
]]

  -- Route handlers are lifted out of main.lua and run standalone per
  -- request, so they only call into this module.
  files["src/app/page_handler.lua"] = [[-- Server pages: GET /, GET /about, and POST /hello, which renders the home
-- page again with the greeting.
require("hydronium_luax").loader.install()
local H = require("hydronium")

local render = function(c, page, opts)
  local dom = require("hydronium_dom.server.meteorite")
  return dom.render(c, require("views.Document"), {
    status = opts.status or 200,
    props = { path = opts.path, page = page },
  })
end

local M = {}

function M.home(c)
  return render(c, H.h(require("views.Home"), { times = 3 }), { path = "/" })
end

function M.about(c)
  return render(c, H.h(require("views.About"), {}), { path = "/about" })
end

function M.hello(c)
  local values = c:form_body() or {}
  local name = type(values.name) == "string" and values.name:match("^%s*(.-)%s*$") or ""
  local times = math.max(1, math.min(9, math.floor(tonumber(values.times) or 3)))
  local props = { name = name, times = times }
  if name == "" then
    props.error = "Who should we say hello to?"
  else
    props.greeting = (string.rep("Hello, " .. name:sub(1, 40) .. "! ", times):gsub("%s+$", ""))
  end
  return render(c, H.h(require("views.Home"), props), { path = "/", status = name == "" and 422 or 200 })
end

return M
]]

  files["src/main.lua"] = string.format([[local meteorite = require("meteorite")

local app = meteorite.app({
  name = "%s",
  host = "127.0.0.1",
  port = tonumber(os.getenv("PORT")) or 8080,
  -- A built server also honours PORT at start-up (Meteorite 0.3.4+).
  port_env = "PORT",
})

meteorite.site(app, {
  root = ".",
  assets = {
    ["/public/:path*"] = { dir = "public", param = "path" },
    ["/js/bootstrap/:path*"] = { dir = "public/js/bootstrap", param = "path" },
    ["/js/island/:path*"] = { dir = "public/js/island", param = "path" },
  },
})

-- Development live reload: dev_reload.js reloads the page when this
-- stream reports an edit.
app:get("/__hydronium/watch", meteorite.lua("dev_watch", { arg_mode = "lazy_context" }))

-- Handlers run standalone per request; they call into src/app/page_handler.lua.
app:get("/", function(c) return require("app.page_handler").home(c) end)
app:get("/about", function(c) return require("app.page_handler").about(c) end)
app:post("/hello", function(c) return require("app.page_handler").hello(c) end)

return app
]], project_name)

  files["src/dev_watch.lua"] = [[-- Full-page development reload transport for the generated app.
local watch = require("hydronium_dom.dev.watch")

return function(c)
  watch.serve_sse(c, {
    "src/views/Document.luax",
    "src/views/App.luax",
    "src/views/Home.luax",
    "src/views/About.luax",
    "src/app/page_handler.lua",
    "src/main.lua",
    "src/dev_watch.lua",
    "public/style.css",
    "public/js/bootstrap/bootstrap.js",
    "public/js/bootstrap/boundary_registry.js",
    "public/js/bootstrap/priority.js",
    "public/js/bootstrap/dev_transport.js",
    "public/js/bootstrap/dev_reload.js",
    "public/js/island/counter.js",
  })
end
]]

  -- Real, self-contained copy of hydronium's own client bootstrap --
  -- reads the `__HYDRONIUM_CLIENT_PLAN__` script tag SSR emits and
  -- dynamically imports each `interpreter: "js"` island's module, calling
  -- its `hydrate(context)` export. Kept contract-compatible with
  -- hydronium_dom/client/bootstrap.js (v1); see that file for the full
  -- design rationale.
  files["public/js/bootstrap/bootstrap.js"] = [[/*
  Hydronium Client Bootstrap (v1) -- real, self-contained copy shipped by
  hydronium-create's `islands` template (see hydronium_dom/client/bootstrap.js
  in the framework repo for the canonical source and full design rationale).

  Reads the `__HYDRONIUM_CLIENT_PLAN__` script tag a real SSR render emits
  and activates only the client execution a given page actually declared:
  islands with interpreter "js" get dynamically `import()`ed and their
  `hydrate(context)` (default) or `mount(context)` (when `mode: "mount"`)
  export called -- the small foreign-module ABI documented in hydronium's
  docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md. Islands with interpreter "lua" are
  deliberately skipped by this JS-island bootstrap; Lua root mounting uses
  the separate mount.js runtime generated by the SSR template.

  No build step; ./boundary_registry.js and ./priority.js ship alongside
  this file. Load with
  `<script type="module">import { activate } from "/js/bootstrap/bootstrap.js"; activate();</script>`
  on any page that used `d.js.island`. `activate()` is idempotent-safe to
  call once on load; it does not poll or retry -- island DOM is assumed to
  already exist by the time this runs.

  IMPORTANT: a `d.js.island`'s `module` prop MUST be an absolute path
  (e.g. "/js/island/counter.js") or a full URL, never a relative one like
  "./counter.js" -- a dynamic `import(specifier)` call resolves a relative
  specifier against THIS file's own URL, not the page's.
*/

import * as registry from "./boundary_registry.js";
import { whenPriority } from "./priority.js";

const OWNER = "js-bootstrap";

function readClientPlan(doc) {
  const el = doc.getElementById("__HYDRONIUM_CLIENT_PLAN__");
  if (!el) return null;
  return JSON.parse(el.textContent);
}

const disposers = new Map();

async function activateIsland(island, context, result) {
  let mod;
  try {
    mod = await import(/* @vite-ignore */ island.module);
  } catch (err) {
    result.errors.push(`failed to import module ${island.module} for island ${island.id}: ${err.message}`);
    return;
  }

  try {
    registry.claim(island.id, OWNER);
  } catch (err) {
    result.errors.push(err.message);
    return;
  }

  if (island.mode === "mount" && typeof mod.mount === "function") {
    mod.mount(context);
  } else if (typeof mod.hydrate === "function") {
    mod.hydrate(context);
  } else {
    result.errors.push(`module ${island.module} exports neither hydrate() nor mount() for island ${island.id}`);
    registry.release(island.id, OWNER);
    return;
  }
  registry.markFinalized(island.id);

  if (typeof mod.dispose === "function") {
    disposers.set(island.id, () => mod.dispose(context));
  }
  result.activatedJsIslands++;
}

/**
 * Discovers every JS island immediately, then activates it according to its
 * `hydrate` priority: load, idle, or visible.
 * @param {Document} [doc] Defaults to the global `document` -- overridable for testing.
 * @param {Element} [root] Subtree to search for island markers. Defaults to `doc.body`.
 * @returns {Promise<{activatedJsIslands: number, deferredJsIslands: number, skippedLuaIslands: number, errors: string[], settled: Promise<void>}>}
 */
export async function activate(doc = document, root = doc.body) {
  const plan = readClientPlan(doc);
  const result = {
    activatedJsIslands: 0,
    deferredJsIslands: 0,
    skippedLuaIslands: 0,
    errors: [],
    settled: Promise.resolve(),
  };
  if (!plan) return result;

  const pending = [];

  for (const island of plan.islands || []) {
    if (island.interpreter === "lua") {
      result.skippedLuaIslands++;
      continue;
    }
    if (island.interpreter !== "js") continue;

    let boundary;
    try {
      boundary = registry.discover(root, island.id);
    } catch (err) {
      result.errors.push(`boundary "${island.id}": ${err.message}`);
      continue;
    }
    if (!boundary) {
      result.errors.push(`no DOM found for island ${island.id}`);
      continue;
    }

    const els = registry.elements(island.id);
    if (els.length === 0) {
      result.errors.push(`island ${island.id} has no element children to hand to its module`);
      continue;
    }
    const context = {
      root: els.length === 1 ? els[0] : els,
      props: island.props || {},
    };

    const priority = island.hydrate || "load";
    if (priority === "load") {
      await activateIsland(island, context, result);
      continue;
    }

    result.deferredJsIslands++;
    pending.push(
      whenPriority(priority, els[0], (bad) => {
        result.errors.push(
          `island ${island.id}: unknown hydrate priority ${JSON.stringify(bad)} -- activating immediately`
        );
      }).then(() => activateIsland(island, context, result))
    );
  }

  if (pending.length > 0) {
    result.settled = Promise.all(pending).then(() => undefined);
  }

  return result;
}

/** Calls the JS module's own `dispose()` (if any) and releases this bootstrap's ownership claim. */
export function disposeIsland(id) {
  const fn = disposers.get(id);
  if (fn) {
    fn();
    disposers.delete(id);
  }
  registry.release(id, OWNER);
}
]]

  -- Shared scheduling vocabulary for both island hydration and root mounts.
  files["public/js/bootstrap/priority.js"] = [[export const PRIORITIES = ["load", "idle", "visible"];

const IDLE_TIMEOUT_MS = 2000;
const VISIBLE_ROOT_MARGIN = "200px";

function whenIdle() {
  return new Promise((resolve) => {
    if (typeof requestIdleCallback === "function") {
      requestIdleCallback(() => resolve(), { timeout: IDLE_TIMEOUT_MS });
    } else {
      setTimeout(resolve, 0);
    }
  });
}

function whenVisible(element) {
  if (typeof IntersectionObserver !== "function" || !element) return Promise.resolve();
  return new Promise((resolve) => {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          observer.disconnect();
          resolve();
          return;
        }
      }
    }, { rootMargin: VISIBLE_ROOT_MARGIN });
    observer.observe(element);
  });
}

export function whenPriority(priority, element, onUnknown) {
  if (typeof priority === "function") return Promise.resolve(priority(element));
  if (priority === "idle") return whenIdle();
  if (priority === "visible") return whenVisible(element);
  if (priority !== "load" && priority != null && onUnknown) onUnknown(String(priority));
  return Promise.resolve();
}
]]

  -- Real, self-contained copy of hydronium's boundary registry --
  -- bootstrap.js imports this as a relative sibling module, so it must
  -- ship alongside it. Mirrors
  -- hydronium_dom/client/boundary_registry.js.
  files["public/js/bootstrap/boundary_registry.js"] = [[/*
  ClientBoundaryRegistry -- real, self-contained copy shipped by
  hydronium-create's `islands` template (see
  hydronium_dom/client/boundary_registry.js in the framework
  repo for the canonical source and full design rationale). The one place
  that knows how a Hydronium boundary is represented in the DOM.

  Marker format (matches hydronium/src/hydronium/server/init.lua's ISLAND
  handling): a start comment `hy:i:<id>:<interpreter>` and an end comment
  `hy:/i:<id>`, direct DOM siblings, zero or more nodes between.
*/

const boundaries = new Map(); // id -> { kind, start, end, generation, owner, state }

function findMarkers(root, id) {
  const doc = root.ownerDocument || root;
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
  let start = null;
  let end = null;
  let node;
  while ((node = walker.nextNode())) {
    const isStart = node.nodeValue === `hy:i:${id}:lua` || node.nodeValue === `hy:i:${id}:js`;
    if (isStart) {
      if (start !== null) {
        throw new Error(`ClientBoundaryRegistry: duplicate start marker for boundary "${id}" -- SSR emitted it twice`);
      }
      start = node;
    } else if (start !== null && node.nodeValue === `hy:/i:${id}`) {
      end = node;
      break;
    }
  }
  if (start === null) return null; // boundary genuinely not present (yet) -- not an error
  if (end === null) {
    throw new Error(`ClientBoundaryRegistry: boundary "${id}" has a start marker but no matching end marker -- malformed SSR output`);
  }
  return { start, end };
}

/**
 * Finds a boundary's DOM markers under `root` and registers it. Returns
 * the existing registration if already discovered (idempotent). Returns
 * null if the boundary is not present in the DOM at all.
 * @param {Node} root
 * @param {string} id
 * @param {"island"} [kind]
 */
export function discover(root, id, kind = "island") {
  const existing = boundaries.get(id);
  if (existing) return existing;
  const markers = findMarkers(root, id);
  if (!markers) return null;
  const entry = {
    kind,
    start: markers.start,
    end: markers.end,
    generation: 0,
    owner: null,
    state: "present",
  };
  boundaries.set(id, entry);
  return entry;
}

export function has(id) {
  return boundaries.has(id);
}

export function find(id) {
  return boundaries.get(id) || null;
}

/** Element (nodeType === 1) children within a boundary's range, in document order. */
export function elements(id) {
  const b = boundaries.get(id);
  if (!b) return [];
  const out = [];
  let n = b.start.nextSibling;
  while (n && n !== b.end) {
    if (n.nodeType === 1) out.push(n);
    n = n.nextSibling;
  }
  return out;
}

/**
 * Claims exclusive ownership of a boundary for `owner`. Idempotent for the
 * same owner. Throws if a *different* owner already holds the claim.
 */
export function claim(id, owner) {
  const b = boundaries.get(id);
  if (!b) {
    throw new Error(`ClientBoundaryRegistry: cannot claim unknown boundary "${id}"`);
  }
  if (b.owner !== null && b.owner !== owner) {
    throw new Error(`ClientBoundaryRegistry: boundary "${id}" is already owned by "${b.owner}", refused claim by "${owner}"`);
  }
  b.owner = owner;
  b.state = "claimed";
  return true;
}

/** Releases ownership if `owner` currently holds it. No-op (returns false) otherwise. */
export function release(id, owner) {
  const b = boundaries.get(id);
  if (!b || b.owner !== owner) return false;
  b.owner = null;
  return true;
}

/** Marks a boundary's content as final (no further replacement expected). No-op if unknown. */
export function markFinalized(id) {
  const b = boundaries.get(id);
  if (b) b.state = "finalized";
}

export function dispose(id) {
  boundaries.delete(id);
}
]]

  -- The development transport is copied into the application's own static
  -- root. Meteorite rejects dependency symlinks as static roots, so serving
  -- it directly from `.moonstone/env` would weaken a deliberate safety rule.
  files["public/js/bootstrap/dev_transport.js"] = [[export function createDevTransport(url) {
  const pollDelayMs = 500;
  let closed = false;
  let listeners = [];
  let since = null;
  let source = null;
  let reconnectTimer = null;
  let pendingPaths = [];

  function notify(type, fingerprint, paths) {
    for (const callback of listeners) callback({ type, fingerprint, paths: paths || [] });
  }

  function reconnect(delayMs = 0) {
    if (source) source.close();
    source = null;
    if (reconnectTimer !== null) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (closed) return;
    if (delayMs > 0) {
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        reconnect();
      }, delayMs);
      return;
    }
    // Immediate server polls keep abandoned refresh requests from occupying
    // Meteorite handlers. The browser owns the quiet-period delay instead.
    // encodeURIComponent is required because Meteorite treats `+` literally.
    const parts = [`_t=${Date.now()}`, "budget=0"];
    if (since) parts.push(`since=${encodeURIComponent(since)}`);
    source = new EventSource(`${url}?${parts.join("&")}`);
    source.addEventListener("hello", (event) => {
      since = event.data;
      notify("hello", event.data);
    });
    source.addEventListener("changed", (event) => {
      pendingPaths = String(event.data || "").split("|").filter((path) => path !== "");
    });
    source.addEventListener("reload", (event) => {
      since = event.data;
      const paths = pendingPaths;
      pendingPaths = [];
      notify("reload", event.data, paths);
      reconnect();
    });
    source.addEventListener("bye", (event) => {
      since = event.data;
      reconnect(pollDelayMs);
    });
  }

  reconnect();
  return {
    subscribe(callback) {
      listeners.push(callback);
      return () => { listeners = listeners.filter((item) => item !== callback); };
    },
    close() {
      closed = true;
      if (source) source.close();
      source = null;
      if (reconnectTimer !== null) clearTimeout(reconnectTimer);
      reconnectTimer = null;
    },
  };
}
]]

  files["public/js/bootstrap/dev_reload.js"] = [[import { createDevTransport } from "./dev_transport.js";

const transport = createDevTransport("/__hydronium/watch");
transport.subscribe((event) => {
  if (event.type === "reload") location.reload();
});
]]

  -- A real `d.js.island` module, hydrating a server-rendered <button>
  -- with vanilla JS -- no framework, no build step, no Lua or WASM
  -- anywhere in this file or its import graph. Adapted directly from
  -- hydronium/examples/js_island/counter.js in the framework repo (same
  -- ABI: `hydrate(context)`/`dispose(context)`, `context.root` the
  -- claimed DOM element, `context.props` the passed props). "hydrate"
  -- here means: claim the existing SSR button, don't replace it.
  files["public/js/island/counter.js"] = [[// The counter island: hydrates the server-rendered "− n +" group in
// src/views/Home.luax and keeps its hidden `times` input in step, so the
// form posts the chosen count.
const cleanups = new WeakMap();

export function hydrate(context) {
  const root = context.root;
  const [less, more] = root.querySelectorAll("button");
  const output = root.querySelector("output");
  const input = root.querySelector('input[name="times"]');
  let times = Number(context.props.times ?? 3);

  const render = () => {
    output.textContent = String(times);
    input.value = String(times);
    less.disabled = times <= 1;
    more.disabled = times >= 9;
  };
  const onLess = () => { times = Math.max(1, times - 1); render(); };
  const onMore = () => { times = Math.min(9, times + 1); render(); };

  less.addEventListener("click", onLess);
  more.addEventListener("click", onMore);
  render();
  cleanups.set(root, () => {
    less.removeEventListener("click", onLess);
    more.removeEventListener("click", onMore);
  });
}

export function dispose(context) {
  cleanups.get(context.root)?.();
  cleanups.delete(context.root);
}
]]

  files["public/style.css"] = look.CSS
  files["public/ui/starter.js"] = look.SCRIPT

  files["README.md"] = string.format([[# %s

Server-rendered pages with one JavaScript island, built with
[Hydronium](https://moonstone.sh/packages/hydronium) and
[Meteorite](https://moonstone.sh/packages/meteorite).

```bash
moon sync
moon run dev
```

Open the printed URL and edit `src/views/App.luax`: the page reloads with your
change.

`moon run dev` runs `hydronium dev`: a live log of requests and rebuilds (also
written to `.hydronium/dev.log`). Press `f` for the fullscreen request
inspector, `esc` to leave it, `q` to quit.

## Files

- `src/views/App.luax` -- the layout: header, page, footer.
- `src/views/Home.luax`, `src/views/About.luax` -- the pages. Home's form posts
  to `/hello` as plain HTML.
- `public/js/island/counter.js` -- the counter island. It is the only
  JavaScript the page ships besides the island bootstrap.
- `src/app/page_handler.lua` -- the server side of `/`, `/about` and `/hello`.
- `src/views/Document.luax` -- the HTML shell.
- `src/main.lua` -- the Meteorite server.
- `public/style.css` -- the styles.

## Build

```bash
moon run build
./dist/server
```

`PORT=9000 ./dist/server` listens on another port.
]], project_name)

  return files
end

return islands
