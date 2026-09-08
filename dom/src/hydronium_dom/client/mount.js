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

  Usage:

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
 * @param {string} options.hydroniumBaseUrl Base URL a served copy of hydronium's `src/` is reachable at.
 * @param {string} options.manifestUrl URL of the JSON manifest (module id -> path relative to `hydroniumBaseUrl`) `tools/gen_client_manifest.lua` produces.
 * @param {string} options.appModuleId The `require()` id your app's root component module registers under.
 * @param {string} options.appModuleUrl URL of that module's real Lua source.
 * @param {string|Element} options.container CSS selector or a real DOM element to mount/hydrate into.
 * @param {object} [options.props] Props passed to the root component.
 * @param {boolean} [options.hydrate] Claim real pre-existing DOM (via `Reconciler:hydrateRoot`) instead of building fresh (via `Reconciler:mount`).
 * @param {string} [options.wasmoonUrl] Override the wasmoon ESM import URL.
 * @returns {Promise<{ lua: unknown, containerEl: Element }>}
 */
export async function mount(options) {
  const {
    hydroniumBaseUrl,
    manifestUrl,
    appModuleId,
    appModuleUrl,
    container,
    props = {},
    hydrate = false,
    wasmoonUrl = DEFAULT_WASMOON_URL,
  } = options;

  if (!hydroniumBaseUrl) throw new Error("hydronium.client.mount: hydroniumBaseUrl is required");
  if (!manifestUrl) throw new Error("hydronium.client.mount: manifestUrl is required");
  if (!appModuleId) throw new Error("hydronium.client.mount: appModuleId is required");
  if (!appModuleUrl) throw new Error("hydronium.client.mount: appModuleUrl is required");

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
  lua.global.set("__hydronium_app_module_id", appModuleId);
  lua.global.set("__hydronium_props_src", `return ${toLuaLiteral(props)}`);
  lua.global.set("__hydronium_hydrate", hydrate === true);

  const preloadLua = moduleEntries
    .map(([moduleId]) => {
      const key = luaModuleGlobalKey(moduleId);
      return `package.preload["${moduleId}"] = assert(load(${key}, "${moduleId}"))`;
    })
    .join("\n");
  await lua.doString(preloadLua);

  await lua.doString(`
    package.preload[__hydronium_app_module_id] = assert(load(__hydronium_app_src, __hydronium_app_module_id))

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
