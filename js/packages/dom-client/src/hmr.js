/*
  hydronium.client.hmr -- the real client-side Hot Module Replacement
  runtime: swap a changed module batch inside the SURVIVING Lua VM and let
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
  from it. The runtime module graph expands a changed dependency to its
  affected component boundaries; this file only fetches a coherent source
  set and hands it to that planner at a browser-safe frame boundary.

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
    - the runtime graph requests a restart or remount that this browser
      transport cannot perform without destroying page state;
    - any instance's own `refresh()` reported failure.

  Deliberately NOT a fallback: a family that matched but currently has
  zero mounted instances. That is a real, complete hot swap of a
  component nobody is showing right now -- the next mount uses the new
  definition, and reloading the page would change nothing.
*/

import { createDevTransport } from "./dev_transport.js";

const APPLY_BATCH_LUA = `
  local host = _G.__hydronium_hmr_host
  if not host then
    host = require("hydronium.core.hmr_host").new({
      root = __hydronium_hmr_can_remount and "browser-root" or nil,
    })
    _G.__hydronium_hmr_host = host
  end
  for i = 1, __hydronium_hmr_count do
    host:queue(
      _G["__hydronium_hmr_id_" .. i],
      _G["__hydronium_hmr_src_" .. i],
      _G["__hydronium_hmr_module_revision_" .. i],
      _G["__hydronium_hmr_module_effects_" .. i]
    )
  end
  local result = host:flush(__hydronium_hmr_batch_revision)
  __hydronium_hmr_outcome = result and result.outcome or "skipped"
  __hydronium_hmr_reason = result and result.reason or nil
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
 * @param {{ [watchedPath: string]: { action: "hot", module: string, effects?: "safe"|"managed"|"restart" }|{ action: "reload" }|{ action: "style", href: string }|{ action: "ignore" } }} options.updates
 *   Explicit policy for every path named by the watch endpoint.
 * @param {string} [options.watchUrl] SSE endpoint (default `/__hydronium/watch`).
 * @param {string} [options.moduleUrl] Base URL serving one compiled module's
 *   source per id, fetched as `<moduleUrl>/<id>` (default
 *   `/__hydronium/dev/module`).
 * @param {(info: object) => void} [options.onUpdate] Called after each
 *   handled change with `{ status, id, ids, revision, paths, outcome,
 *   families, refreshed, failed, error }`.
 * @param {() => void} [options.onFullReload] Overrides the reload action
 *   (tests use this; defaults to `location.reload()`).
 * @param {(result: object) => Promise<void>|void} [options.remount] Explicit
 *   root remount boundary, normally the `remount` function returned by
 *   `mount()`. It may use the Lua VM's optional snapshot/restore hooks.
 * @param {(apply: () => void) => void} [options.schedule] Runs an accepted
 *   batch at a host-safe boundary. Defaults to `requestAnimationFrame`.
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
    remount,
    schedule,
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

  async function fetchModule(id, batchRevision) {
    // Cache-busted for the same reason dev_transport.js busts its own
    // connection URL: this route's response is a plain 200 with no
    // cache headers, and a repeat fetch of an unchanged URL is exactly
    // what the browser's HTTP cache is designed to short-circuit --
    // which would silently serve the PRE-EDIT source.
    const url = `${moduleUrl.replace(/\/+$/, "")}/${encodeURIComponent(id)}?_t=${Date.now()}&revision=${encodeURIComponent(batchRevision)}`;
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`fetching ${url} failed: ${res.status}`);
    }
    const src = await res.text();
    const responseRevision = res.headers?.get?.("x-hydronium-revision")
      || res.headers?.get?.("etag")
      || batchRevision;
    // A snapshot-aware endpoint proves that it read this source against the
    // same watcher revision that announced the batch. Older endpoints remain
    // compatible, but a disagreeing proof is never silently accepted.
    if (responseRevision !== batchRevision) {
      throw new Error(`module ${id} belongs to revision ${responseRevision}, expected ${batchRevision}`);
    }
    return { id, src, revision: String(responseRevision) };
  }

  function safeBoundary() {
    return new Promise((resolve) => {
      if (schedule) {
        schedule(resolve);
      } else if (typeof requestAnimationFrame === "function") {
        requestAnimationFrame(() => resolve());
      } else {
        queueMicrotask(resolve);
      }
    });
  }

  async function applyBatch(modules, batchRevision) {
    // Sources cross as values, never interpolated into Lua. All fetches have
    // completed before this point, and hmr_host flushes the queue once.
    lua.global.set("__hydronium_hmr_count", modules.length);
    lua.global.set("__hydronium_hmr_batch_revision", batchRevision);
    lua.global.set("__hydronium_hmr_can_remount", typeof remount === "function");
    modules.forEach((module, index) => {
      const slot = index + 1;
      lua.global.set(`__hydronium_hmr_id_${slot}`, module.id);
      lua.global.set(`__hydronium_hmr_src_${slot}`, module.src);
      lua.global.set(`__hydronium_hmr_module_revision_${slot}`, module.revision);
      lua.global.set(`__hydronium_hmr_module_effects_${slot}`, module.effects || "restart");
    });
    await safeBoundary();
    await lua.doString(APPLY_BATCH_LUA);

    return {
      outcome: String(lua.global.get("__hydronium_hmr_outcome") || "rejected"),
      reason: lua.global.get("__hydronium_hmr_reason") || undefined,
      families: Number(lua.global.get("__hydronium_hmr_families") || 0),
      refreshed: Number(lua.global.get("__hydronium_hmr_refreshed") || 0),
      failed: Number(lua.global.get("__hydronium_hmr_failed") || 0),
    };
  }

  async function handle(event) {
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

    if (ids.length === 0) return;

    let modules;
    try {
      modules = await Promise.all(ids.map(async (id) => {
        const module = await fetchModule(id, event.fingerprint);
        const rule = rules.find((candidate) => candidate.action === "hot" && candidate.module === id);
        module.effects = rule?.effects || "restart";
        return module;
      }));
    } catch (err) {
      fullReload({ reason: "hot batch fetch failed", paths, ids, error: String(err && err.message ? err.message : err) });
      return;
    }

    let result;
    try {
      result = await applyBatch(modules, event.fingerprint);
    } catch (err) {
      fullReload({ reason: "hot batch threw", paths, ids, error: String(err && err.message ? err.message : err) });
      return;
    }
    if (result.outcome === "remount" && typeof remount === "function") {
      try {
        await remount(result);
        report({ status: "remounted", paths, ids, ...result });
        return;
      } catch (err) {
        fullReload({ reason: "root remount failed", paths, ids, error: String(err && err.message ? err.message : err), ...result });
        return;
      }
    }
    if (result.outcome === "restart" || result.outcome === "remount" || result.outcome === "rejected") {
      fullReload({ reason: result.reason || `HMR requested ${result.outcome}`, paths, ids, ...result });
      return;
    }
    if (result.failed > 0) {
      fullReload({ reason: "an instance failed to refresh", paths, ids, ...result });
      return;
    }
    report({
      status: result.outcome === "skipped" ? "skipped" : result.outcome === "installed" ? "installed" : "hot-swapped",
      paths,
      ids,
      id: ids.length === 1 ? ids[0] : undefined,
      revision: event.fingerprint,
      ...result,
    });
  }

  let updateTail = Promise.resolve();
  transport.subscribe((event) => {
    updateTail = updateTail.then(() => handle(event)).catch((err) => {
      fullReload({ reason: "HMR transport handler failed", error: String(err && err.message ? err.message : err) });
    });
  });

  return {
    close() {
      transport.close();
    },
  };
}
