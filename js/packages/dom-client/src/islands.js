/*
  hydronium.client.islands -- Lua islands on a server-rendered page.

  The server renders the whole page; each `d.lua.island` wraps its content in
  <!--hy:i:ID:lua--> ... <!--hy:/i:ID--> and records { module, props, hydrate }
  in __HYDRONIUM_CLIENT_PLAN__. This module boots ONE Lua VM for the page and
  hydrates every top-level Lua island in place, each at its own priority
  ("load" | "idle" | "visible"), by requiring the island's module and
  claiming the DOM between its markers. Nothing outside an island is touched,
  so server-only content needs no Lua at all -- and a page with no Lua
  islands never starts an engine (bootIslands returns before importing one).

    import { bootIslands } from "/js/bootstrap/islands.js";
    const { hydrated } = await bootIslands({ luaGlobals });

  Release pages carry __HYDRONIUM_BOOT__ (hydronium_dom.server.client_boot)
  listing exactly the chunks their islands need. Development pages read the
  live module manifest and get HMR: an update that cannot refresh in place
  remounts the islands rather than reloading the page.

  Island props cross as a Lua literal (see mount.js toLuaLiteral): plain
  data only -- no functions, which also could not have been serialized into
  the client plan in the first place.
*/
import { boot, toLuaLiteral } from "./mount.js";
import { whenPriority } from "./priority.js";
import * as boundaries from "./boundary_registry.js";

const OWNER = "hydronium-lua-islands";

const SETUP_LUA = `
  if not _G.__hydronium_host then
    _G.__hydronium_host = _G.__hydronium_domhost_mod.createDomHost(require("hydronium.runtime.hosts").require("dom", 1))
    _G.__hydronium_reconciler = _G.__hydronium_reconciler_mod.Reconciler.new(_G.__hydronium_host)
  end
  _G.__hydronium_islands = _G.__hydronium_islands or {}
`;

// Hydrate claims the server's nodes between the markers; anything the vnode
// tree did not account for is removed, exactly as a root hydration does past
// its last child. Mount (HMR remount) inserts before the closing marker.
const RENDER_LUA = `
  local host, reconciler = _G.__hydronium_host, _G.__hydronium_reconciler
  local Component = require(__hydronium_island_module)
  local props = assert(__hydronium_compile(__hydronium_island_props_src, "@" .. __hydronium_island_id .. " props"))()
  local vnode = _G.__hydronium_element.h(Component, props)
  local parent, stop = __hydronium_island_parent, __hydronium_island_end
  if __hydronium_island_hydrate then
    local _, cursor = reconciler:hydrate(vnode, parent, host.nextSibling(__hydronium_island_start), stop)
    while cursor and cursor ~= stop do
      local after = host.nextSibling(cursor)
      if host.hydrationMismatch then host.hydrationMismatch({ reason = "extra_island_child", domNode = cursor }) end
      host.removeChild(parent, cursor)
      cursor = after
    end
  else
    reconciler:mount(vnode, parent, stop, nil)
  end
  _G.__hydronium_islands[__hydronium_island_id] = vnode
`;

const UNMOUNT_LUA = `
  local vnode = _G.__hydronium_islands[__hydronium_island_id]
  if vnode then _G.__hydronium_reconciler:unmount(vnode) end
  _G.__hydronium_islands[__hydronium_island_id] = nil
`;

function readJson(id) {
  const node = typeof document !== "undefined" ? document.getElementById(id) : null;
  if (!node || !node.textContent) return null;
  return JSON.parse(node.textContent);
}

/** Lua islands the page asks the browser to hydrate (root mounts excluded). */
export function luaIslands(plan) {
  return (plan?.islands || []).filter((island) => island.interpreter === "lua" && !island.root);
}

function firstElement(boundary) {
  for (let node = boundary.start.nextSibling; node && node !== boundary.end; node = node.nextSibling) {
    if (node.nodeType === 1) return node;
  }
  return null;
}

// A Lua island nested in another is hydrated as part of its ancestor's tree.
function topLevel(entries) {
  const FOLLOWING = 4; // Node.DOCUMENT_POSITION_FOLLOWING
  return entries.filter(({ boundary }) => !entries.some((other) =>
    other.boundary !== boundary
    && (other.boundary.start.compareDocumentPosition(boundary.start) & FOLLOWING)
    && (boundary.start.compareDocumentPosition(other.boundary.end) & FOLLOWING)));
}

function report(island, error) {
  console.error(`[hydronium] island ${island.id} (${island.module}) failed:`, error);
  if (typeof window !== "undefined" && typeof CustomEvent === "function") {
    window.dispatchEvent(new CustomEvent("hydronium:error", { detail: { island, error, phase: "island" } }));
  }
}

/**
 * Boots one VM and hydrates `islands` (client-plan records). Every other
 * option is passed to mount.js `boot()` (chunkUrls, or the unbundled
 * hydroniumBaseUrl/manifestUrl/moduleUrls trio, engineProvider, luaGlobals,
 * hmr, ...).
 *
 * @returns {Promise<{ lua: object, timings: object, islands: object[],
 *   hydrated: Promise<Error[]>, remount: () => Promise<void> }>}
 *   `hydrated` settles once every island has hydrated or failed (deferred
 *   islands may take arbitrarily long, or never, for "visible").
 */
export async function hydrateIslands({ islands, root = document, container, ...bootOptions }) {
  const entries = [];
  for (const island of luaIslands({ islands })) {
    try {
      const boundary = boundaries.discover(root, island.id);
      if (!boundary) throw new Error("island markers not found in the document");
      boundaries.claim(island.id, OWNER);
      entries.push({ island, boundary });
    } catch (error) {
      report(island, error);
    }
  }
  const active = topLevel(entries);

  const handle = await boot({
    ...bootOptions,
    entryless: true,
    container: container || root.body || root,
    hydrate: true,
  });
  const { lua } = handle;

  // One Lua call at a time: overlapping async doString calls into one wasm
  // VM corrupt its state.
  let tail = Promise.resolve();
  const serial = (fn) => {
    const run = tail.then(fn);
    tail = run.catch(() => {});
    return run;
  };
  const select = ({ island, boundary }, hydrate) => {
    lua.global.set("__hydronium_island_id", island.id);
    lua.global.set("__hydronium_island_module", island.module);
    lua.global.set("__hydronium_island_props_src", `return ${toLuaLiteral(island.props ?? {})}`);
    lua.global.set("__hydronium_island_parent", boundary.start.parentNode);
    lua.global.set("__hydronium_island_start", boundary.start);
    lua.global.set("__hydronium_island_end", boundary.end);
    lua.global.set("__hydronium_island_hydrate", hydrate);
  };
  await serial(() => lua.doString(SETUP_LUA));

  const rendered = new Set();
  const hydrated = Promise.all(active.map((entry) =>
    whenPriority(entry.island.hydrate || "load", firstElement(entry.boundary) || entry.boundary.start.parentNode)
      .then(() => serial(async () => {
        select(entry, true);
        await lua.doString(RENDER_LUA);
        rendered.add(entry);
        boundaries.markFinalized(entry.island.id);
      }))
      .then(() => null, (error) => { report(entry.island, error); return error; })
  )).then((results) => results.filter(Boolean));

  async function remount() {
    for (const entry of rendered) {
      await serial(async () => {
        select(entry, false);
        await lua.doString(UNMOUNT_LUA);
        const { start, end } = entry.boundary;
        while (start.nextSibling && start.nextSibling !== end) start.parentNode.removeChild(start.nextSibling);
        await lua.doString(RENDER_LUA);
      });
    }
  }

  return { lua, timings: handle.timings, islands: active.map((entry) => entry.island), hydrated, remount };
}

/**
 * Page entry point: reads the client plan, returns at once when the page has
 * no Lua islands, otherwise loads exactly what they need and hydrates them.
 *
 * @param {object} [options]
 * @param {object} [options.luaGlobals] JS values exposed as Lua globals.
 * @param {object} [options.engineProvider] Override the default Lua 5.4 engine.
 * @param {object} [options.updates] Extra HMR update policies merged over the manifest's.
 * @param {string} [options.sourceManifestUrl] Dev module manifest.
 */
export async function bootIslands({
  luaGlobals = {},
  engineProvider,
  updates = {},
  root = document,
  sourceManifestUrl = "/__hydronium/dev/manifest.json",
  hydroniumBaseUrl = "/hydronium-src",
  manifestUrl = "/__hydronium/client_manifest.json",
} = {}) {
  const islands = luaIslands(readJson("__HYDRONIUM_CLIENT_PLAN__"));
  if (islands.length === 0) return { lua: null, islands, hydrated: Promise.resolve([]), remount: async () => {} };

  const release = readJson("__HYDRONIUM_BOOT__");
  let manifest = null;
  let sources;
  if (Array.isArray(release?.chunks) && release.chunks.length > 0) {
    sources = { chunkUrls: release.chunks };
  } else {
    const response = await fetch(sourceManifestUrl, { cache: "no-store" });
    if (!response.ok) throw new Error(`hydronium.client.islands: module manifest unavailable (${response.status})`);
    manifest = await response.json();
    if (Array.isArray(manifest.chunks) && manifest.chunks.length > 0) {
      sources = { chunkUrls: manifest.chunks };
    } else {
      const modules = Object.entries(manifest.modules || {});
      sources = {
        hydroniumBaseUrl,
        manifestUrl,
        moduleUrls: Object.fromEntries(modules.map(([id, record]) => [id, record.url])),
        moduleEffects: Object.fromEntries(modules.map(([id, record]) => [id, record.effects])),
      };
    }
  }
  const hmr = manifest !== null && manifest.hmr !== false;

  const result = await hydrateIslands({
    islands, root, luaGlobals, hmr, ...sources, ...(engineProvider ? { engineProvider } : {}),
  });
  if (hmr) {
    const { installHmr } = await import("./hmr.js");
    installHmr({ lua: result.lua, remount: result.remount, updates: { ...manifest.updates, ...updates } });
  }
  return result;
}
