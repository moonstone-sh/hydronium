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
*/

import { createDomBridge } from "./dom_bridge.js";

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
  const { LuaFactory } = await import(/* @vite-ignore */ wasmoonUrl);
  const factory = new LuaFactory(wasmoonWasmUrl);
  return factory.createEngine();
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
async function fetchUnbundledSources({ hydroniumBaseUrl, manifestUrl, appModuleUrl }) {
  const appSourcePromise = fetchText(appModuleUrl, "app module");

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

  return { moduleEntries, appSource: await appSourcePromise };
}

function luaModuleGlobalKey(moduleId) {
  return "__hydronium_src_" + moduleId.replace(/\./g, "_");
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
 * @returns {Promise<{ lua: unknown, containerEl: Element }>}
 */
export async function mount(options) {
  const {
    chunkUrls,
    hydroniumBaseUrl,
    manifestUrl,
    appModuleId,
    appModuleUrl,
    container,
    props = {},
    hydrate = false,
    hmr = false,
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

  // Booting the Lua VM and fetching the Lua SOURCES are independent, and
  // are started together here rather than one after the other.
  //
  // They used to be strictly sequential -- `import(wasmoon)` ->
  // `createEngine()` -> and only THEN the first `fetch()` -- which cost a
  // real, measured ~270ms of dead time on every page load: nothing about
  // issuing an HTTP request for a `.lua` file needs a Lua VM to exist, yet
  // every one of them waited behind the wasm download and instantiation.
  //
  // A live engine IS required before any `lua.global.set` / `lua.doString`
  // below, so the two halves rejoin at this Promise.all and the ordering
  // of everything after it is unchanged.
  //
  // Promise.all (not sequential awaits) also matters for failure
  // behaviour: it subscribes to both promises immediately, so if the
  // engine boot and a fetch both reject, neither becomes an unhandled
  // rejection -- the first error is thrown and the other stays observed.
  const [lua, sources] = await Promise.all([
    createLuaEngine(wasmoonUrl, wasmoonWasmUrl),
    bundled
      ? fetchChunkSources(chunkUrls)
      : fetchUnbundledSources({ hydroniumBaseUrl, manifestUrl, appModuleUrl }),
  ]);

  const bridge = createDomBridge();
  for (const [name, fn] of Object.entries(bridge)) {
    lua.global.set("__dom_" + name, fn);
  }
  lua.global.set("__hydronium_container", containerEl);

  if (bundled) {
    // Real chunk source is passed as a global string and `load()`ed
    // Lua-side, never interpolated into a JS template literal -- a
    // compiled Lua chunk routinely contains `]==]`/backtick/`${`-looking
    // byte sequences that would corrupt a naive string interpolation.
    // Same reasoning as toLuaLiteral()'s own doc comment above for props.
    //
    // Still strictly in `chunkUrls` order: only the fetching was
    // parallelized (in fetchChunkSources), never the evaluation.
    for (const src of sources) {
      lua.global.set("__hydronium_chunk_src", src);
      await lua.doString('assert(load(__hydronium_chunk_src, "@hydronium-chunk"))()');
    }
  } else {
    const { moduleEntries, appSource } = sources;

    for (const [moduleId, source] of moduleEntries) {
      lua.global.set(luaModuleGlobalKey(moduleId), source);
    }
    lua.global.set("__hydronium_app_src", appSource);
    lua.global.set("__hydronium_app_module_id_unbundled", appModuleId);

    const preloadLua = moduleEntries
      .map(([moduleId]) => {
        const key = luaModuleGlobalKey(moduleId);
        return `package.preload["${moduleId}"] = assert(load(${key}, "${moduleId}"))`;
      })
      .join("\n");
    await lua.doString(preloadLua);
    await lua.doString(
      "package.preload[__hydronium_app_module_id_unbundled] = assert(load(__hydronium_app_src, __hydronium_app_module_id_unbundled))"
    );
  }

  lua.global.set("__hydronium_app_module_id", appModuleId);
  lua.global.set("__hydronium_props_src", `return ${toLuaLiteral(props)}`);
  lua.global.set("__hydronium_hydrate", hydrate === true);
  lua.global.set("__hydronium_hmr_enabled", hmr === true);

  await lua.doString(`
    -- The "hydronium" luax compile target unconditionally emits
    -- H.h(...) for every element regardless of bare vs. lexical tags (H
    -- is the createElement factory reference; bare/lexical only changes
    -- the TAG argument) -- see run.lua/run_luax.lua's own
    -- shared_env = {H = hydronium, ...} pattern elsewhere in this
    -- codebase. A module loaded via plain load() with no explicit env
    -- (as both the bundled and unbundled preload loaders above are)
    -- resolves H through the ambient globals, so it must be set as a
    -- real global before requiring any .luax-compiled app entry.
    -- pcall'd: an app entry that never needs H (hand-written Lua calling
    -- hydronium_dom directly, e.g. examples/meteorite_ssr/client_mount_demo)
    -- may not have the top-level "hydronium" barrel in its own module
    -- set at all (found live: it broke that exact real, already-verified
    -- demo when this was an unconditional require) -- only apps that
    -- actually reference H.h(...) need this to have succeeded.
    local __H_ok, __H_mod = pcall(require, "hydronium")
    if not __H_ok then
      -- The barrel is frequently NOT resolvable client-side: the module
      -- manifest is generated from a component's REAL require graph
      -- (dom/tools/gen_client_manifest.lua), and a component that pulls
      -- in "hydronium.core.element" directly never causes the top-level
      -- "hydronium" barrel to be listed -- so the pcall above fails and,
      -- before this fallback existed, H stayed nil. That was invisible
      -- for a LEXICAL-tag component (which declares its own module-level
      -- local H = require("hydronium.core.element")) but fatal for a
      -- BARE-tag one, whose codegen emits a bare H.h("div", ...) and
      -- relies entirely on this global -- every bare-tag component died
      -- on first render with "attempt to index a nil value (global 'H')".
      --
      -- The element module is the right substitute rather than a
      -- convenience: .h and .Fragment are the ONLY members LUAX codegen
      -- ever emits on H (compiler/init.lua's factory_name /
      -- fragment_name), the barrel's own h/Fragment are literally these
      -- same values re-exported (core/init.lua), and this module is
      -- always present in the manifest because element.h is what every
      -- compiled component calls.
      __H_ok, __H_mod = pcall(require, "hydronium.core.element")
    end
    if __H_ok then H = __H_mod end

    -- Must precede the app require below: family_loader wraps the global
    -- require and only scans a module's exports on its FIRST load, so
    -- enabling it after the app module was already required would leave
    -- that module's components permanently undiscoverable (and hmr.js
    -- would then correctly, but uselessly, fall back to a full reload on
    -- every save). See this function's options.hmr doc comment.
    -- (No backticks in here: this whole block is a JS template literal.)
    if __hydronium_hmr_enabled then
      require("hydronium.core.family_loader").enable()
    end

    local element = require("hydronium.core.element")
    local dom = require("hydronium_dom")
    local domHostMod = require("hydronium_dom.host.dom")
    local reconciler_mod = require("hydronium.core.reconciler")
    local App = require(__hydronium_app_module_id)
    local props = assert(load(__hydronium_props_src, "hydronium.client.mount props"))()

    _G.__hydronium_host = domHostMod.createDomHost()
    _G.__hydronium_reconciler = reconciler_mod.Reconciler.new(_G.__hydronium_host)
    _G.__hydronium_tree = dom.lua.mount(element.h(App, props))

    if __hydronium_hydrate then
      _G.__hydronium_root_host_node = _G.__hydronium_reconciler:hydrateRoot(_G.__hydronium_tree, __hydronium_container)
    else
      _G.__hydronium_root_host_node = _G.__hydronium_reconciler:mount(_G.__hydronium_tree, __hydronium_container, nil, nil)
    end
  `);

  return { lua, containerEl };
}
