/*
  hydronium.client.mount -- the real, reusable client bootstrap entry
  point `d.lua.mount(<App/>)` needed and never had.

  Before this module, every real proof of the DOM host
  (examples/meteorite_ssr/hmr_demo/dom_host_proof.html and its
  predecessors) hand-assembled, inline, per page: the wasmoon boot, the
  `__dom_*` bridge (now `./dom_bridge.js`), and a module-loading step
  driven by a hand-pasted JSON blob of every required module's full
  source text typed directly into the page. That was a real, correct
  VERIFICATION technique -- proving the underlying pieces (the DOM host,
  the reconciler, HMR) actually work -- but not a shippable API any real
  app could import. This module is that API: it fetches real files over
  HTTP (driven by a manifest `tools/gen_client_manifest.lua` derives
  from hydronium's own real `require()` graph, not a hand-maintained
  list) instead of requiring a blob to be typed into every page.

  This is still NOT a bundler (see docs/BUNDLING.md for what one would
  still need to do -- single-file amalgamation, minification, caching)
  -- it fetches each runtime module as its own real HTTP request. For a
  real app that's a genuine, known cost this doesn't try to hide; a
  bundler is real, separate, future work.

  Usage (unbundled -- fetches every runtime module as its own request):

    import { mount } from "hydronium/client/mount.js";

    await mount({
      hydroniumBaseUrl: "/hydronium-src",       // a served copy of hydronium's src/
      manifestUrl: "/hydronium-src/client_manifest.json",
      appModuleId: "app.components.root",       // the require() id your app entry uses
      appModuleUrl: "/app/root.lua",            // real Lua source (already .luax-compiled if needed)
      container: "#app",
      props: { initial: 0 },
      hydrate: true,                            // claim real SSR-produced DOM instead of building fresh
    });

  Usage (bundled -- hydronium_ballad.plugins.client.bundle()'s real
  output, see docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md): each URL in
  `chunkUrls` is real Lua source in "package_preload_v1" format -- loading
  and calling it installs `package.preload[id]` for every module it
  carries, INCLUDING the app's own entry module, so no separate
  `hydroniumBaseUrl`/`manifestUrl`/`appModuleUrl` fetch is needed at all:

    await mount({
      chunkUrls: ["/dist/client/runtime-a1b2c3d4.lua"],
      appModuleId: "App",
      container: "#app",
      props: { initial: 0 },
    });

  Loading state, and mounting later than "now" (both optional, both off by
  default -- an app that passes neither behaves exactly as it always did):

    <div id="app">
      <div data-hydronium-placeholder>...whatever you want to show...</div>
    </div>

    const { lua, mounted } = await mount({
      ...,
      defer: "visible",   // boot the VM NOW, render when scrolled into view
    });

  The VM is always booted eagerly; `defer` only postpones the render, so
  the component appears instantly when its trigger fires rather than
  starting a cold boot then. `mount()` resolves once the VM is up (so HMR
  can be installed against it immediately); `mounted` resolves when the
  component is really in the DOM. Any `[data-hydronium-placeholder]`
  element inside the container is removed at that exact moment, and the
  container carries `aria-busy="true"` until then. See PLACEHOLDERS further
  down for the full contract and the `hydronium:boot`/`hydronium:mount`
  events, and ./priority.js for the priority vocabulary (shared with
  ./bootstrap.js, which applies it to each SSR island's own `hydrate` prop).
*/

import { createDomBridge } from "./dom_bridge.js";
import { whenPriority, PRIORITIES } from "./priority.js";

/*
  TIMING INSTRUMENTATION
  ----------------------
  Real `performance.mark`/`performance.measure` entries, not a debug flag
  and not console logging: they show up in a browser's own performance
  panel next to the resource timeline, they survive into
  `performance.getEntriesByName(...)` for a Playwright/CI assertion, and
  they cost a few microseconds each. `mount()` also returns the same
  numbers as a plain object (`timings`), so a caller never has to scrape
  the buffer to get them.

  The phase names are deliberately the ones a person actually asks about
  when a boot feels slow -- "was it the network, the wasm, or the Lua?" --
  because those three have completely different fixes:

    engine:import   dynamic import() of the wasmoon ESM wrapper, which is
                    what pulls in its ~152KB index.js.
    engine:create   new LuaFactory(...).createEngine(), which fetches
                    glue.wasm and runs WebAssembly.instantiateStreaming on
                    it. Network AND compile, together -- separating those
                    two needs a wrapper around WebAssembly itself, which is
                    a profiling harness's job, not this module's.
    sources         every Lua source fetch: the manifest, all framework
                    modules it lists, and the app's own module.
    preload         load() over all of that source -- the pure PARSE cost,
                    and the only phase a bytecode cache could ever remove.
                    Kept as its own measure precisely so that question is
                    answerable with a number instead of an opinion.
    require         executing those parsed chunks (the app's require graph
                    actually running).
    render          building the vnode tree and reconciling it into the
                    container: "VM ready" -> mounted DOM.

  `boot` spans everything up to a live VM with all sources loaded;
  `total` spans mount() end to end.
*/
const perf =
  typeof performance !== "undefined" && typeof performance.mark === "function" ? performance : null;
const PERF_PREFIX = "hydronium:";

function mark(name) {
  if (!perf) return;
  // Never let instrumentation break a mount: a mark() call can throw in a
  // host with a locked-down/absent User Timing implementation, and a page
  // failing to boot because it tried to time itself would be absurd.
  try {
    perf.mark(PERF_PREFIX + name);
  } catch (_) {
    /* timing is best-effort */
  }
}

function measure(name, startMark, endMark) {
  if (!perf) return null;
  try {
    const entry = perf.measure(PERF_PREFIX + name, PERF_PREFIX + startMark, PERF_PREFIX + endMark);
    // Some hosts' measure() returns undefined rather than the entry.
    const duration = entry ? entry.duration : null;
    return duration == null ? null : Math.round(duration * 100) / 100;
  } catch (_) {
    return null;
  }
}

/*
  wasmoon is SELF-HOSTED, served from ./vendor/wasmoon/ next to this file,
  rather than fetched from a public CDN. Both URLs are resolved against
  `import.meta.url` -- this module's own real location -- and NOT against
  the page, so they keep working no matter what base path an app mounts
  the client bootstrap directory at (examples/quickstart serves it at
  /js/bootstrap/, examples/meteorite_ssr at /client/; neither has to say
  anything about wasmoon).

  Why this was worth doing, measured rather than assumed: the previous
  default pulled the ESM wrapper from cdn.jsdelivr.net (~118ms) and then
  -- because a browser-side `new LuaFactory()` with no explicit URI
  hardcodes `https://unpkg.com/wasmoon@<version>/dist/glue.wasm` inside
  wasmoon itself -- the 265KB binary from unpkg.com (~154ms). Two
  blocking round trips to two DIFFERENT third-party origins (two DNS
  lookups, two TLS handshakes) before this module had even started
  fetching the framework's own Lua sources.

  DEFAULT_WASMOON_WASM_URL is passed to `new LuaFactory(...)` explicitly.
  That is the documented, supported override ("You can pass the wasm
  location as the first argument, useful if you are using wasmoon on a
  web environment and want to host the file by yourself" -- wasmoon's
  README) and the ONLY way to redirect that second fetch: wasmoon always
  installs its own emscripten `locateFile` hook, so the binary's location
  comes from this argument or from wasmoon's hardcoded unpkg fallback,
  never from where index.js happens to sit on disk.
*/
const DEFAULT_WASMOON_URL = new URL("./vendor/wasmoon/wasmoon.esm.js", import.meta.url).href;
const DEFAULT_WASMOON_WASM_URL = new URL("./vendor/wasmoon/glue.wasm", import.meta.url).href;

/**
 * Boots the Lua VM. Kept as its own function so mount() can start it as a
 * promise and let it run CONCURRENTLY with the HTTP fetches of the Lua
 * sources -- see mount()'s own comment at the Promise.all.
 */
async function createLuaEngine(wasmoonUrl, wasmoonWasmUrl) {
  mark("engine:import:start");
  const { LuaFactory } = await import(/* @vite-ignore */ wasmoonUrl);
  mark("engine:import:end");

  // Marked separately from the import above because the two are fixed by
  // completely different things: the import is one JS fetch, while
  // createEngine() is where glue.wasm is fetched AND compiled.
  mark("engine:create:start");
  const factory = new LuaFactory(wasmoonWasmUrl);
  const engine = await factory.createEngine();
  mark("engine:create:end");
  return engine;
}

async function fetchText(url, describe) {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`hydronium.client.mount: failed to fetch ${describe} from ${url}: ${res.status}`);
  }
  return res.text();
}

/**
 * Bundled path: every chunk is fetched in parallel, but the resolved
 * array preserves `chunkUrls` order because that order is real -- chunks
 * are `load()`ed sequentially by the caller, and a later chunk may
 * legitimately overwrite a `package.preload` entry an earlier one set.
 * Only the network waiting is parallelized, never the evaluation.
 */
function fetchChunkSources(chunkUrls) {
  return Promise.all(chunkUrls.map((url) => fetchText(url, `chunk ${url}`)));
}

/**
 * Unbundled path. The app module's own source is fetched CONCURRENTLY
 * with the manifest (nothing about it depends on the manifest's
 * contents); the framework modules are the one genuinely dependent step,
 * since their URLs are what the manifest lists.
 */
async function fetchUnbundledSources({ hydroniumBaseUrl, manifestUrl, appModuleUrl, moduleUrls = {} }) {
  const appSourcePromise = fetchText(appModuleUrl, "app module");
  const appModuleEntriesPromise = Promise.all(
    Object.entries(moduleUrls).map(async ([moduleId, url]) => [
      moduleId,
      await fetchText(url, `app module '${moduleId}'`),
    ])
  );

  const manifestRes = await fetch(manifestUrl);
  if (!manifestRes.ok) {
    throw new Error(`hydronium.client.mount: failed to fetch manifest ${manifestUrl}: ${manifestRes.status}`);
  }
  const manifest = await manifestRes.json();

  const base = hydroniumBaseUrl.replace(/\/+$/, "");
  const moduleEntries = await Promise.all(
    Object.entries(manifest).map(async ([moduleId, relPath]) => [
      moduleId,
      await fetchText(`${base}/${relPath}`, `module '${moduleId}'`),
    ])
  );

  return {
    moduleEntries,
    appModuleEntries: await appModuleEntriesPromise,
    appSource: await appSourcePromise,
  };
}

/**
 * Serializes a plain JSON-like JS value into real Lua table-constructor
 * SOURCE TEXT (evaluated Lua-side via `load()`), rather than passing it
 * to wasmoon's own JS<->Lua value marshalling directly. Found the hard
 * way, verified live: `lua.global.set("props", { initial: 10 })` does
 * NOT reliably deep-marshal into a plain Lua table wasmoon.doString code
 * can index with `props.initial` -- the real, working pattern this
 * whole codebase already uses everywhere else for passing structured
 * data across the JS/Lua boundary is a source string evaluated with
 * `load(...)`, not the automatic object marshaller.
 */
function toLuaLiteral(value) {
  if (value === null || value === undefined) return "nil";
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return "{ " + value.map(toLuaLiteral).join(", ") + " }";
  }
  if (typeof value === "object") {
    const entries = Object.entries(value).map(([k, v]) => {
      const key = /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : `[${JSON.stringify(k)}]`;
      return `${key} = ${toLuaLiteral(v)}`;
    });
    return "{ " + entries.join(", ") + " }";
  }
  throw new Error(`hydronium.client.mount: cannot serialize value of type ${typeof value} to a Lua literal`);
}

/**
 * @param {object} options
 * @param {string[]} [options.chunkUrls] Bundled path: URLs of real
 *   "package_preload_v1"-format Lua chunks (hydronium_ballad.plugins.client.bundle()'s
 *   output), fetched and `load()`ed in order. Each chunk installs
 *   `package.preload` for every module it carries, INCLUDING the app's
 *   own entry module -- so no `hydroniumBaseUrl`/`manifestUrl`/`appModuleUrl`
 *   is needed alongside this. Mutually exclusive with the unbundled options below.
 * @param {string} [options.hydroniumBaseUrl] Unbundled path: base URL a served copy of hydronium's `src/` is reachable at.
 * @param {string} [options.manifestUrl] Unbundled path: URL of the JSON manifest (module id -> path relative to `hydroniumBaseUrl`) `tools/gen_client_manifest.lua` produces.
 * @param {string} [options.appModuleUrl] Unbundled path: URL of the app's own module's real Lua source.
 * @param {{ [moduleId: string]: string }} [options.moduleUrls] Unbundled
 *   application dependencies to preload as `moduleId -> source URL` before
 *   requiring the app entry. This is the application-side counterpart to
 *   the framework manifest: use it when the root component imports other
 *   project modules.
 * @param {string} options.appModuleId The `require()` id your app's root component module registers under (required in both paths).
 * @param {string|Element} options.container CSS selector or a real DOM element to mount/hydrate into.
 * @param {object} [options.props] Props passed to the root component.
 * @param {boolean} [options.hydrate] Claim real pre-existing DOM (via `Reconciler:hydrateRoot`) instead of building fresh (via `Reconciler:mount`).
 * @param {boolean} [options.hmr] Dev only: enable `hydronium.core.family_loader`
 *   BEFORE the app module is required, so every component it exports is
 *   discovered and can later be hot-swapped by `./hmr.js`. This has to
 *   happen here rather than in hmr.js because family discovery hooks
 *   `require` and only fires on a module's FIRST load, and because a
 *   ComponentInstance binds to its family at construction
 *   (core/component.lua's `familyLoader.lookup(self.type)`) -- both of
 *   which are already past by the time mount() returns. Off by default:
 *   family_loader is documented as opt-in precisely so production pays
 *   nothing and sees no `require` wrapping.
 * @param {{ [name: string]: any }} [options.luaGlobals] Values installed in
 *   the Lua VM before the app module is required. This is the composition
 *   seam for host extensions such as hydronium-router's `__router_*`
 *   history bridge; mount does not need to know each extension by name.
 * @param {string} [options.wasmoonUrl] Override the wasmoon ESM import URL.
 *   Defaults to the copy vendored next to this file
 *   (`./vendor/wasmoon/wasmoon.esm.js`, resolved against `import.meta.url`).
 *   Still a fully supported override -- point it at a CDN build or a
 *   different wasmoon version if you would rather not serve your own.
 * @param {string} [options.wasmoonWasmUrl] Override the URL wasmoon fetches
 *   its `glue.wasm` binary from, passed straight to `new LuaFactory(...)`.
 *   Defaults to `./vendor/wasmoon/glue.wasm`. Set this whenever you set
 *   `wasmoonUrl`: the two are independent, and wasmoon does NOT derive the
 *   binary's location from wherever its JS was loaded -- left unset it
 *   falls back to wasmoon's own hardcoded `unpkg.com` URL, so overriding
 *   only `wasmoonUrl` would quietly keep one cross-origin fetch (and could
 *   pair a vendored binary with a mismatched build, or vice versa).
 * @param {false|"load"|"idle"|"visible"|((el: Element) => any)} [options.defer]
 *   WHEN to render the component. The Lua VM always boots eagerly, the
 *   moment `mount()` is called -- this defers only the render, never the
 *   boot, and that is the entire point: by the time the trigger fires the
 *   VM is already warm and the component appears at once, instead of
 *   starting a cold boot at the worst possible moment (the frame the user
 *   just scrolled to it).
 *
 *   `false` (the default) renders as soon as the VM is ready --
 *   byte-for-byte the previous behaviour, so an app that does not pass
 *   this sees no change at all. `"idle"`, `"visible"` and a custom
 *   function are resolved by ./priority.js, the same module ./bootstrap.js
 *   uses for an island's own `hydrate` prop, so the two vocabularies
 *   cannot drift apart.
 *
 *   With `defer` set, `mount()` resolves as soon as the VM is up; it does
 *   NOT wait for the render. Await the returned `mounted` promise for that.
 * @param {false|string|((el: Element) => void)} [options.placeholder]
 *   What to do with the loading state the app already put in the
 *   container. See PLACEHOLDERS below. Defaults to removing every
 *   `[data-hydronium-placeholder]` element inside the container at the
 *   exact moment the component is mounted.
 * @returns {Promise<{ lua: unknown, containerEl: Element, mounted: Promise<void>, timings: object }>}
 */
export async function mount(options) {
  const handle = await boot(options);
  const defer = options.defer || false;

  if (!defer) {
    await handle.render();
    return {
      lua: handle.lua,
      containerEl: handle.containerEl,
      mounted: Promise.resolve(),
      timings: handle.timings,
    };
  }

  // Deferred: arm the trigger and hand the caller a live handle NOW.
  // `mounted` is returned rather than awaited so a page can install HMR
  // against the (already booted) VM without waiting for a component that,
  // at "visible" priority, may never be scrolled to at all.
  const mounted = whenPriority(defer, handle.containerEl, (bad) => {
    console.warn(
      "hydronium.client.mount: unknown defer priority " +
        JSON.stringify(bad) +
        " -- rendering immediately. Expected one of " +
        PRIORITIES.join(", ") +
        ", false, or a function."
    );
  }).then(() => handle.render());

  // A deferred render that throws must not surface as an unhandled
  // rejection for a caller who never touches `mounted`. The error still
  // reaches anyone who does await it, and the hydronium:error DOM event.
  mounted.catch(() => {});

  return { lua: handle.lua, containerEl: handle.containerEl, mounted, timings: handle.timings };
}

/*
  PLACEHOLDERS -- the skeleton/loading mechanism
  ----------------------------------------------
  Hydronium deliberately ships NO skeleton component, no spinner, and no
  opinion about what a loading state looks like. What a page shows while a
  Lua VM boots is an application design decision, and any built-in would
  either be ignored or fought.

  What every app DID need, and had to hand-roll identically, is the
  plumbing around it. examples/quickstart wrote this by hand in its own
  page shell:

      const booting = document.querySelector("#app .booting");
      const { lua } = await mount({ ... });
      if (booting) booting.remove();

  with a real comment explaining the non-obvious part -- the reconciler
  APPENDS its tree to the container rather than clearing it, so a
  placeholder left as a child sits above the mounted component forever.
  That is framework knowledge leaking into every app, and it is subtly
  wrong for a deferred mount (the placeholder must survive until the
  component actually renders, which is no longer when mount() returns).

  So the mechanism is a CONVENTION plus an EVENT, and no styling:

    1. Put whatever you want in the container and mark it:

         <div id="app">
           <div data-hydronium-placeholder class="my-skeleton">...</div>
         </div>

       Any element carrying `data-hydronium-placeholder` inside the
       container is removed at the exact moment the component is mounted --
       after a deferred wait, not when mount() resolved. Pass a different
       CSS selector as `placeholder`, a function to take over entirely, or
       `false` to opt out and do it yourself.

    2. While booting, the container carries `aria-busy="true"` (removed on
       mount). That is a real assistive-technology signal AND a styling
       hook -- `#app[aria-busy="true"] { ... }` needs no class of ours.
       Set only when building fresh: during hydration the container's DOM
       is already the real, meaningful content, not a loading state.

    3. Real DOM events on the container (they bubble, so a document-level
       listener works), for anything the two above cannot express -- a
       fade-out transition, swapping a cached render, telemetry:

         hydronium:boot   VM live and all sources loaded, before render.
         hydronium:mount  component mounted; placeholder already removed.
         hydronium:error  boot or render threw. detail: { error, phase }

       Each carries `detail.timings`, the same numbers mount() returns.
*/
const DEFAULT_PLACEHOLDER_SELECTOR = "[data-hydronium-placeholder]";

function dispatch(el, type, detail) {
  if (!el || typeof CustomEvent !== "function" || typeof el.dispatchEvent !== "function") return;
  try {
    el.dispatchEvent(new CustomEvent(type, { detail, bubbles: true }));
  } catch (_) {
    /* a non-DOM host has nothing to notify */
  }
}

/**
 * Clears the app's loading state. Returns how many elements were removed
 * (0 for the function form, which owns the whole job itself).
 */
function clearPlaceholder(containerEl, placeholder) {
  if (placeholder === false) return 0;
  if (typeof placeholder === "function") {
    placeholder(containerEl);
    return 0;
  }
  const selector = typeof placeholder === "string" ? placeholder : DEFAULT_PLACEHOLDER_SELECTOR;
  let removed = 0;
  try {
    // Queried against the CONTAINER, never the document: two independently
    // mounted islands on one page must not clear each other's placeholder.
    for (const el of Array.from(containerEl.querySelectorAll(selector))) {
      el.remove();
      removed++;
    }
  } catch (_) {
    /* an invalid selector should not take the mount down with it */
  }
  return removed;
}

/*
  Split out of one combined chunk so the two halves can be timed -- and,
  more importantly, SEPARATED IN TIME -- independently. Everything here is
  the eager half: it runs during boot(), before any deferral, so a deferred
  island has already paid its require cost by the time it becomes visible.

  Results are parked in globals rather than chunk locals precisely because
  the render half below is a different chunk and cannot see them otherwise.
*/
const REQUIRE_LUA = `
  -- The "hydronium" luax compile target unconditionally emits H.h(...)
  -- for every element regardless of bare vs. lexical tags (H is the
  -- createElement factory reference; bare/lexical only changes the TAG
  -- argument) -- see run.lua/run_luax.lua's own shared_env = {H = hydronium, ...}
  -- pattern elsewhere in this codebase. A module loaded via plain load()
  -- with no explicit env (as both the bundled and unbundled preload
  -- loaders are) resolves H through the ambient globals, so it must be a
  -- real global before requiring any .luax-compiled app entry.
  -- pcall'd: an app entry that never needs H (hand-written Lua calling
  -- hydronium_dom directly, e.g. examples/meteorite_ssr/client_mount_demo)
  -- may not have the top-level "hydronium" barrel in its module set at
  -- all (found live: it broke that exact real, already-verified demo when
  -- this was an unconditional require) -- only apps that actually
  -- reference H.h(...) need this to have succeeded.
  local __H_ok, __H_mod = pcall(require, "hydronium")
  if not __H_ok then
    -- The barrel is frequently NOT resolvable client-side: the module
    -- manifest is generated from a component's REAL require graph
    -- (dom/tools/gen_client_manifest.lua), and a component that pulls in
    -- "hydronium.core.element" directly never causes the top-level
    -- "hydronium" barrel to be listed -- so the pcall above fails and,
    -- before this fallback existed, H stayed nil. That was invisible for
    -- a LEXICAL-tag component (which declares its own module-level
    -- local H = require("hydronium.core.element")) but fatal for a
    -- BARE-tag one, whose codegen emits a bare H.h("div", ...) and relies
    -- entirely on this global -- every bare-tag component died on first
    -- render with "attempt to index a nil value (global 'H')".
    --
    -- The element module is the right substitute rather than a
    -- convenience: .h and .Fragment are the ONLY members LUAX codegen
    -- ever emits on H (compiler/init.lua's factory_name / fragment_name),
    -- the barrel's own h/Fragment are literally these same values
    -- re-exported (core/init.lua), and this module is always present in
    -- the manifest because element.h is what every compiled component calls.
    __H_ok, __H_mod = pcall(require, "hydronium.core.element")
  end
  if __H_ok then H = __H_mod end

  -- Must precede the app require below: family_loader wraps the global
  -- require and only scans a module's exports on its FIRST load, so
  -- enabling it after the app module was already required would leave that
  -- module's components permanently undiscoverable (and hmr.js would then
  -- correctly, but uselessly, fall back to a full reload on every save).
  -- See mount()'s options.hmr doc comment.
  -- (No backticks in here: this whole block is a JS template literal.)
  if __hydronium_hmr_enabled then
    require("hydronium.core.family_loader").enable()
  end

  _G.__hydronium_element = require("hydronium.core.element")
  _G.__hydronium_dom = require("hydronium_dom")
  _G.__hydronium_domhost_mod = require("hydronium_dom.host.dom")
  _G.__hydronium_reconciler_mod = require("hydronium.core.reconciler")
  _G.__hydronium_App = require(__hydronium_app_module_id)
`;

/*
  The deferrable half: everything that actually touches the DOM. Runs
  immediately after REQUIRE_LUA for a default mount, or arbitrarily later
  for a deferred one -- nothing in here depends on WHEN it runs.

  Props are evaluated here rather than in the require half so that a
  deferred mount reads them at render time.
*/
const RENDER_LUA = `
  local element = _G.__hydronium_element
  local dom = _G.__hydronium_dom
  local App = _G.__hydronium_App
  local props = assert(load(__hydronium_props_src, "hydronium.client.mount props"))()

  _G.__hydronium_host = _G.__hydronium_domhost_mod.createDomHost()
  _G.__hydronium_reconciler = _G.__hydronium_reconciler_mod.Reconciler.new(_G.__hydronium_host)
  _G.__hydronium_tree = dom.lua.mount(element.h(App, props))

  if __hydronium_hydrate then
    _G.__hydronium_root_host_node = _G.__hydronium_reconciler:hydrateRoot(_G.__hydronium_tree, __hydronium_container)
  else
    _G.__hydronium_root_host_node = _G.__hydronium_reconciler:mount(_G.__hydronium_tree, __hydronium_container, nil, nil)
  end
`;

/**
 * Boots the Lua VM, loads every module, and runs the app's require graph
 * -- everything EXCEPT rendering into the DOM, which the returned
 * `render()` performs.
 *
 * `mount()` is this plus an immediate (or deferred) `render()`, and is what
 * an app should normally call. Reach for `boot()` directly only when the
 * render trigger is something no `defer` value can express and the app
 * wants to own the call itself.
 *
 * Accepts every `mount()` option except `defer` (meaningless here: not
 * rendering IS the point) and returns:
 *
 *   { lua, containerEl, timings, render() }
 *
 * `timings` is live -- the render phases are filled into the SAME object
 * once `render()` runs, so a reference taken now stays current.
 *
 * @param {object} options See mount().
 */
export async function boot(options) {
  const {
    chunkUrls,
    hydroniumBaseUrl,
    manifestUrl,
    appModuleId,
    appModuleUrl,
    moduleUrls = {},
    container,
    props = {},
    hydrate = false,
    hmr = false,
    luaGlobals = {},
    placeholder,
    wasmoonUrl = DEFAULT_WASMOON_URL,
    wasmoonWasmUrl = DEFAULT_WASMOON_WASM_URL,
  } = options;

  const bundled = Array.isArray(chunkUrls) && chunkUrls.length > 0;
  if (!appModuleId) throw new Error("hydronium.client.mount: appModuleId is required");
  if (!bundled) {
    if (!hydroniumBaseUrl) throw new Error("hydronium.client.mount: hydroniumBaseUrl is required (or pass chunkUrls)");
    if (!manifestUrl) throw new Error("hydronium.client.mount: manifestUrl is required (or pass chunkUrls)");
    if (!appModuleUrl) throw new Error("hydronium.client.mount: appModuleUrl is required (or pass chunkUrls)");
  }

  const containerEl = typeof container === "string" ? document.querySelector(container) : container;
  if (!containerEl) {
    throw new Error(`hydronium.client.mount: container not found: ${String(container)}`);
  }

  const timings = {};
  let rendered = false;

  function fail(phase, error) {
    dispatch(containerEl, "hydronium:error", { error, phase, timings });
    return error;
  }

  mark("mount:start");

  // Announced before any awaiting: during hydration the container already
  // holds the real, meaningful SSR content, so calling it busy would be a
  // lie to a screen reader. Only a fresh build is genuinely "loading".
  if (!hydrate && typeof containerEl.setAttribute === "function") {
    containerEl.setAttribute("aria-busy", "true");
  }

  try {
    // Booting the Lua VM and fetching the Lua SOURCES are independent, and
    // are started together here rather than one after the other.
    //
    // They used to be strictly sequential -- import(wasmoon) ->
    // createEngine() -> and only THEN the first fetch() -- which cost a
    // real, measured ~270ms of dead time on every page load: nothing about
    // issuing an HTTP request for a .lua file needs a Lua VM to exist, yet
    // every one of them waited behind the wasm download and instantiation.
    //
    // A live engine IS required before any lua.global.set / lua.doString
    // below, so the two halves rejoin at this Promise.all and the ordering
    // of everything after it is unchanged.
    //
    // Promise.all (not sequential awaits) also matters for failure
    // behaviour: it subscribes to both promises immediately, so if the
    // engine boot and a fetch both reject, neither becomes an unhandled
    // rejection -- the first error is thrown and the other stays observed.
    mark("sources:start");
    const [lua, sources] = await Promise.all([
      createLuaEngine(wasmoonUrl, wasmoonWasmUrl),
      (bundled
        ? fetchChunkSources(chunkUrls)
        : fetchUnbundledSources({ hydroniumBaseUrl, manifestUrl, appModuleUrl, moduleUrls })
      ).then((result) => {
        // Marked inside the .then rather than after the Promise.all so it
        // records when the FETCHES finished, not when the slower of the
        // two halves did -- otherwise a slow wasm boot would be silently
        // attributed to the network.
        mark("sources:end");
        return result;
      }),
    ]);
    mark("boot:end");

    const bridge = createDomBridge();
    for (const [name, fn] of Object.entries(bridge)) {
      lua.global.set("__dom_" + name, fn);
    }
    lua.global.set("__hydronium_container", containerEl);
    for (const [name, value] of Object.entries(luaGlobals)) {
      lua.global.set(name, value);
    }

    mark("preload:start");
    if (bundled) {
      // Real chunk source is passed as a global string and load()ed
      // Lua-side, never interpolated into a JS template literal -- a
      // compiled Lua chunk routinely contains ]==]/backtick/${-looking
      // byte sequences that would corrupt a naive string interpolation.
      // Same reasoning as toLuaLiteral()'s own doc comment for props.
      //
      // Still strictly in chunkUrls order: only the fetching was
      // parallelized (in fetchChunkSources), never the evaluation.
      for (const src of sources) {
        lua.global.set("__hydronium_chunk_src", src);
        await lua.doString('assert(load(__hydronium_chunk_src, "@hydronium-chunk"))()');
      }
    } else {
      const { moduleEntries, appModuleEntries, appSource } = sources;

      const preloadEntries = [...moduleEntries, ...appModuleEntries];
      for (const [index, [moduleId, source]] of preloadEntries.entries()) {
        // Keep IDs and source as values across the JS/Lua boundary. Turning a
        // module ID into a Lua identifier would make punctuation unsafe and
        // would make `a.b` collide with `a_b` after sanitization.
        lua.global.set(`__hydronium_preload_id_${index}`, moduleId);
        lua.global.set(`__hydronium_preload_src_${index}`, source);
      }
      lua.global.set("__hydronium_app_src", appSource);
      lua.global.set("__hydronium_app_module_id_unbundled", appModuleId);

      const preloadLua = preloadEntries
        .map((_, index) => {
          const idKey = `__hydronium_preload_id_${index}`;
          const sourceKey = `__hydronium_preload_src_${index}`;
          return `package.preload[${idKey}] = assert(load(${sourceKey}, "@" .. ${idKey}))`;
        })
        .join("\n");
      await lua.doString(preloadLua);
      await lua.doString(
        "package.preload[__hydronium_app_module_id_unbundled] = assert(load(__hydronium_app_src, __hydronium_app_module_id_unbundled))"
      );
    }
    mark("preload:end");

    lua.global.set("__hydronium_app_module_id", appModuleId);
    lua.global.set("__hydronium_hydrate", hydrate === true);
    lua.global.set("__hydronium_hmr_enabled", hmr === true);

    mark("require:start");
    await lua.doString(REQUIRE_LUA);
    mark("require:end");

    timings["engine:import"] = measure("engine:import", "engine:import:start", "engine:import:end");
    timings["engine:create"] = measure("engine:create", "engine:create:start", "engine:create:end");
    timings.sources = measure("sources", "sources:start", "sources:end");
    timings.boot = measure("boot", "mount:start", "boot:end");
    timings.preload = measure("preload", "preload:start", "preload:end");
    timings.require = measure("require", "require:start", "require:end");

    dispatch(containerEl, "hydronium:boot", { lua, timings });

    async function render() {
      // Idempotent rather than an error: a page that both awaits `mounted`
      // and (defensively) calls render() itself should not get a second,
      // duplicate component appended to the container.
      if (rendered) return;
      rendered = true;
      try {
        mark("render:start");
        // Set here, not at boot, so a deferred mount reads the props it
        // was given at the moment it actually renders.
        lua.global.set("__hydronium_props_src", `return ${toLuaLiteral(props)}`);
        await lua.doString(RENDER_LUA);
        mark("render:end");

        timings.render = measure("render", "render:start", "render:end");
        timings.total = measure("total", "mount:start", "render:end");

        // AFTER the component is really in the DOM: swapping a skeleton out
        // before its replacement exists is exactly the flash of empty
        // container this mechanism is meant to prevent.
        timings.placeholdersRemoved = clearPlaceholder(containerEl, placeholder);
        if (typeof containerEl.removeAttribute === "function") {
          containerEl.removeAttribute("aria-busy");
        }

        dispatch(containerEl, "hydronium:mount", { lua, timings });
      } catch (err) {
        throw fail("render", err);
      }
    }

    return { lua, containerEl, timings, render };
  } catch (err) {
    // aria-busy must not outlive a failed boot: a container stuck at
    // aria-busy="true" forever tells assistive tech the page is still
    // loading when it has actually given up.
    if (typeof containerEl.removeAttribute === "function") {
      containerEl.removeAttribute("aria-busy");
    }
    throw fail("boot", err);
  }
}
