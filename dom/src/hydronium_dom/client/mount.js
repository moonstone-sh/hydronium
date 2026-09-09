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

const DEFAULT_WASMOON_URL = "https://cdn.jsdelivr.net/npm/wasmoon@1.16.0/+esm";

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
 * @param {string} [options.wasmoonUrl] Override the wasmoon ESM import URL.
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
    wasmoonUrl = DEFAULT_WASMOON_URL,
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

  const { LuaFactory } = await import(/* @vite-ignore */ wasmoonUrl);
  const factory = new LuaFactory();
  const lua = await factory.createEngine();

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
    for (const url of chunkUrls) {
      const res = await fetch(url);
      if (!res.ok) {
        throw new Error(`hydronium.client.mount: failed to fetch chunk ${url}: ${res.status}`);
      }
      const src = await res.text();
      lua.global.set("__hydronium_chunk_src", src);
      await lua.doString('assert(load(__hydronium_chunk_src, "@hydronium-chunk"))()');
    }
  } else {
    const manifestRes = await fetch(manifestUrl);
    if (!manifestRes.ok) {
      throw new Error(`hydronium.client.mount: failed to fetch manifest ${manifestUrl}: ${manifestRes.status}`);
    }
    const manifest = await manifestRes.json();

    const moduleEntries = await Promise.all(
      Object.entries(manifest).map(async ([moduleId, relPath]) => {
        const url = `${hydroniumBaseUrl.replace(/\/+$/, "")}/${relPath}`;
        const res = await fetch(url);
        if (!res.ok) {
          throw new Error(`hydronium.client.mount: failed to fetch module '${moduleId}' from ${url}: ${res.status}`);
        }
        return [moduleId, await res.text()];
      })
    );

    const appRes = await fetch(appModuleUrl);
    if (!appRes.ok) {
      throw new Error(`hydronium.client.mount: failed to fetch app module from ${appModuleUrl}: ${appRes.status}`);
    }
    const appSource = await appRes.text();

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
    if __H_ok then H = __H_mod end

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
