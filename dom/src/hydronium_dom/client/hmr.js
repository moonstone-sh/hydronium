/*
  hydronium.client.hmr -- the real client-side Hot Module Replacement
  runtime: swap one changed module inside the SURVIVING Lua VM and let
  the ordinary reconciler patch the DOM, instead of destroying the page
  with `location.reload()`.

  This generalizes what
  examples/meteorite_ssr/hmr_demo/dom_host_proof.html proved by hand --
  a real wasmoon VM, a real edit on disk, `package.preload[id] = load(src)`
  followed by `family_loader.reload(id)`, with unrelated DOM nodes
  asserted `===`-identical afterwards. That page did it with modules
  inlined as a giant literal and hardcoded one-off routes. This module
  does the same thing over the ordinary dev transport and an ordinary
  HTTP route, against a VM booted by the ordinary `mount()`.

  WHY THIS WORKS AT ALL, and why it is less machinery than a JS bundler
  needs: the browser is running a persistent Lua VM with a real
  `package.loaded` registry, and `hydronium.core.family_loader` already
  maps a `require()` module id to every live ComponentInstance created
  from it. So "replace this module and re-run the affected components"
  is one existing primitive call, not a graph invalidation algorithm.
  Nothing in here re-implements refresh, reconciliation, or state
  preservation -- it only decides WHICH module to swap, and when to give
  up and reload the page instead.

  ---------------------------------------------------------------------
  CHANGE IDENTITY -- how a file on disk becomes a module id

  The server watches FILES; the Lua VM knows MODULE IDS. Nothing in the
  system can honestly derive one from the other on its own: there is no
  package searcher installed in the browser VM (that is M3's
  `loader.install()`), so a module's id is whatever key `mount()` used
  when it called `package.preload[...]`, which is an application
  decision, not a filesystem fact.

  So update policy is explicit and supplied by the app, as `updates`:

      updates: {
        "views/App.luax": { action: "hot", module: "views.App" },
        "views/Document.luax": { action: "reload" },
        "public/style.css": { action: "style", href: "/public/style.css" },
      }

  keyed by the exact watched path string the server reports. Missing rules
  are reported and ignored rather than silently destroying application
  state. A watched file must say whether it is a hot Lua module, a document
  boundary requiring reload, a stylesheet to replace in place, or ignored.

  ---------------------------------------------------------------------
  FALLBACK -- Vite's "graceful degradation to a full reload"

  `location.reload()` is not a failure path to be ashamed of; it is the
  documented, correct behavior whenever a hot swap cannot be PROVEN to
  have worked. This runtime falls back when:

    - fetching or compiling the new module source failed;
    - `family_loader.reload(id)` matched zero families -- the module
      never registered a component, so no live instance can be
      refreshed and the page's current DOM cannot reflect the edit;
    - any instance's own `refresh()` reported failure.

  Deliberately NOT a fallback: a family that matched but currently has
  zero mounted instances. That is a real, complete hot swap of a
  component nobody is showing right now -- the next mount uses the new
  definition, and reloading the page would change nothing.
*/

import { createDevTransport } from "./dev_transport.js";

const SWAP_LUA = `
  local id = __hydronium_hmr_id
  local result = require("hydronium.core.hmr").replace(id, __hydronium_hmr_src)
  __hydronium_hmr_families = result.families
  __hydronium_hmr_refreshed = result.refreshed
  __hydronium_hmr_failed = result.failed
`;

/**
 * @param {object} options
 * @param {any} options.lua The live wasmoon engine `mount()` returned.
 *   `mount({ hmr: true, ... })` is required: that flag is what enables
 *   `family_loader` BEFORE the app module is first required, which is
 *   the only moment its components can be discovered.
 * @param {{ [watchedPath: string]: { action: "hot", module: string }|{ action: "reload" }|{ action: "style", href: string }|{ action: "ignore" } }} options.updates
 *   Explicit policy for every path named by the watch endpoint.
 * @param {string} [options.watchUrl] SSE endpoint (default `/__hydronium/watch`).
 * @param {string} [options.moduleUrl] Base URL serving one compiled module's
 *   source per id, fetched as `<moduleUrl>/<id>` (default
 *   `/__hydronium/dev/module`).
 * @param {(info: object) => void} [options.onUpdate] Called after each
 *   handled change with `{ status, id, paths, families, refreshed, failed, error }`.
 * @param {() => void} [options.onFullReload] Overrides the reload action
 *   (tests use this; defaults to `location.reload()`).
 * @returns {{ close: () => void }}
 */
export function installHmr(options) {
  const {
    lua,
    updates = {},
    watchUrl = "/__hydronium/watch",
    moduleUrl = "/__hydronium/dev/module",
    onUpdate,
    onFullReload,
  } = options || {};

  if (!lua) throw new Error("hydronium.client.hmr: `lua` (the engine mount() returned) is required");

  const transport = createDevTransport(watchUrl);

  function report(info) {
    // A DOM event as well as the callback: it gives a page (or a test)
    // something to await that does not require holding the return value
    // of installHmr, and costs nothing when nobody listens.
    try {
      window.dispatchEvent(new CustomEvent("hydronium:hmr", { detail: info }));
    } catch (_) {
      /* non-DOM host: the callback below is still the real channel */
    }
    if (onUpdate) onUpdate(info);
  }

  function fullReload(info) {
    report({ ...info, status: "full-reload" });
    if (onFullReload) onFullReload();
    else location.reload();
  }

  function classify(paths) {
    const rules = [];
    const missing = [];
    for (const path of paths) {
      const rule = updates[path];
      if (!rule) missing.push(path);
      else rules.push({ path, ...rule });
    }
    return { rules, missing };
  }

  function replaceStylesheet(href) {
    const wanted = new URL(href, location.href).pathname;
    const current = Array.from(document.querySelectorAll('link[rel="stylesheet"]'))
      .find((link) => new URL(link.href, location.href).pathname === wanted);
    if (!current) throw new Error(`stylesheet ${href} is not linked by the document`);

    return new Promise((resolve, reject) => {
      const next = current.cloneNode();
      const url = new URL(current.href, location.href);
      url.searchParams.set("_t", Date.now());
      next.href = url.href;
      next.addEventListener("load", () => {
        current.remove();
        resolve();
      }, { once: true });
      next.addEventListener("error", () => {
        next.remove();
        reject(new Error(`stylesheet ${href} failed to reload`));
      }, { once: true });
      current.after(next);
    });
  }

  async function swap(id) {
    // Cache-busted for the same reason dev_transport.js busts its own
    // connection URL: this route's response is a plain 200 with no
    // cache headers, and a repeat fetch of an unchanged URL is exactly
    // what the browser's HTTP cache is designed to short-circuit --
    // which would silently serve the PRE-EDIT source.
    const url = `${moduleUrl.replace(/\/+$/, "")}/${encodeURIComponent(id)}?_t=${Date.now()}`;
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`fetching ${url} failed: ${res.status}`);
    }
    const src = await res.text();

    // Source is handed across as a global and `load()`ed Lua-side rather
    // than interpolated into the Lua snippet -- same reasoning as
    // mount.js's own note: real compiled Lua routinely contains byte
    // sequences that would corrupt naive string interpolation.
    lua.global.set("__hydronium_hmr_src", src);
    lua.global.set("__hydronium_hmr_id", id);
    await lua.doString(SWAP_LUA);

    return {
      families: Number(lua.global.get("__hydronium_hmr_families") || 0),
      refreshed: Number(lua.global.get("__hydronium_hmr_refreshed") || 0),
      failed: Number(lua.global.get("__hydronium_hmr_failed") || 0),
    };
  }

  transport.subscribe(async (event) => {
    if (event.type !== "reload") return;

    const paths = event.paths || [];
    if (paths.length === 0) {
      report({ status: "unhandled", reason: "server reported no changed paths", paths });
      return;
    }

    const { rules, missing } = classify(paths);
    if (missing.length > 0) {
      const reason = `no update policy for: ${missing.join(", ")}`;
      console.warn(`hydronium.client.hmr: ${reason}`);
      report({ status: "unhandled", reason, paths, missing });
      return;
    }

    const reloadRule = rules.find((rule) => rule.action === "reload");
    if (reloadRule) {
      fullReload({ reason: `explicit reload boundary: ${reloadRule.path}`, paths });
      return;
    }

    for (const rule of rules) {
      if (rule.action === "ignore") {
        report({ status: "ignored", path: rule.path, paths });
      } else if (rule.action === "style") {
        try {
          await replaceStylesheet(rule.href);
          report({ status: "style-updated", path: rule.path, href: rule.href, paths });
        } catch (err) {
          report({ status: "update-failed", path: rule.path, paths, error: String(err && err.message ? err.message : err) });
        }
      } else if (rule.action !== "hot") {
        report({ status: "unhandled", reason: `unknown action '${rule.action}' for ${rule.path}`, paths });
        return;
      }
    }

    const ids = [];
    for (const rule of rules) {
      if (rule.action === "hot" && rule.module && !ids.includes(rule.module)) ids.push(rule.module);
    }

    for (const id of ids) {
      let result;
      try {
        result = await swap(id);
      } catch (err) {
        fullReload({ reason: "hot swap threw", paths, id, error: String(err && err.message ? err.message : err) });
        return;
      }
      if (result.families === 0) {
        fullReload({ reason: "module registered no component family", paths, id, ...result });
        return;
      }
      if (result.failed > 0) {
        fullReload({ reason: "an instance failed to refresh", paths, id, ...result });
        return;
      }
      report({ status: "hot-swapped", paths, id, ...result });
    }
  });

  return {
    close() {
      transport.close();
    },
  };
}
