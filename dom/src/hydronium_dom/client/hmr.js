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

  So the mapping is explicit and supplied by the app, as `modules`:

      modules: { "views/Counter.luax": "app" }

  keyed by the exact watched path string the server reports (the same
  string that appears in the watch route's own file list -- these two
  lists must agree, and the app owns both). A changed path with no entry
  is not an error and not silently ignored: it triggers the full-reload
  fallback, which is the correct answer for a file this runtime cannot
  reason about (a stylesheet, a server route, a module nothing has
  registered a component from).

  ---------------------------------------------------------------------
  FALLBACK -- Vite's "graceful degradation to a full reload"

  `location.reload()` is not a failure path to be ashamed of; it is the
  documented, correct behavior whenever a hot swap cannot be PROVEN to
  have worked. This runtime falls back when:

    - the server reported no changed paths at all (an older server with
      no `changed` frame, so "something changed" is all we know);
    - a changed path has no `modules` entry;
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
  local chunk, err = load(__hydronium_hmr_src, "@" .. id)
  if not chunk then
    error("hydronium.client.hmr: could not load new source for '" .. id .. "': " .. tostring(err), 0)
  end

  -- Install the NEW source as this id's loader before asking the family
  -- loader to reload it. family_loader.reload() clears
  -- package.loaded[id] and re-requires, and require consults
  -- package.preload first -- which is exactly how mount() installed the
  -- module in the first place, so this is the same mechanism, not a
  -- parallel one.
  package.preload[id] = chunk

  local family_loader = require("hydronium.core.family_loader")
  local results = family_loader.reload(id)

  local families, refreshed, failed = 0, 0, 0
  for _, r in pairs(results) do
    families = families + 1
    refreshed = refreshed + (r.refreshed or 0)
    failed = failed + (r.failed or 0)
  end
  __hydronium_hmr_families = families
  __hydronium_hmr_refreshed = refreshed
  __hydronium_hmr_failed = failed
`;

/**
 * @param {object} options
 * @param {any} options.lua The live wasmoon engine `mount()` returned.
 *   `mount({ hmr: true, ... })` is required: that flag is what enables
 *   `family_loader` BEFORE the app module is first required, which is
 *   the only moment its components can be discovered.
 * @param {{ [watchedPath: string]: string }} options.modules Watched file
 *   path -> `require()` module id. See CHANGE IDENTITY above.
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
    modules = {},
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

  /**
   * Resolves the changed paths to module ids, preserving order and
   * dropping duplicates (two watched files can map to one module).
   * Returns null when any path is unmapped -- one unknown change is
   * enough to make a partial update dishonest, so the whole batch
   * degrades to a full reload.
   */
  function resolveIds(paths) {
    const ids = [];
    for (const p of paths) {
      const id = modules[p];
      if (!id) return null;
      if (!ids.includes(id)) ids.push(id);
    }
    return ids;
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
      fullReload({ reason: "server reported no changed paths", paths });
      return;
    }

    const ids = resolveIds(paths);
    if (!ids) {
      fullReload({ reason: "a changed path has no module mapping", paths });
      return;
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
