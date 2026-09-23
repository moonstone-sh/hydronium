/*
  Hydronium Client Bootstrap (v1)

  Reads the `__HYDRONIUM_CLIENT_PLAN__` script tag a real SSR render emits
  (see src/hydronium/server/init.lua's ISLAND handling) and activates only
  the client execution a given page actually declared:

    - islands with interpreter "js": dynamically `import()`s the named
      ES module and calls its `hydrate(context)` (default) or
      `mount(context)` (when `mode: "mount"`) export -- the small foreign-
      module ABI documented in docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md.
      WHEN that happens is now the island's own `hydrate` priority
      ("load" | "idle" | "visible"), resolved through ./priority.js. That
      field was already being emitted by the server for every island and
      had no consumer here until now -- see activate()'s doc comment.
      A deferred island's module is not even fetched until it triggers.
    - islands with interpreter "lua": deliberately NOT handled here. This
      file has no `import` of any Lua/WASM runtime anywhere in it -- a
      page with zero `d.js.island`s never executes the dynamic-import
      branch below at all, and a page with zero `d.lua.island`s never
      causes this file to load anything Lua-related, because there is no
      such code path in this file to take. (The published "Hydronium in
      WASM" proof hydrates its Lua island directly, without this
      bootstrap, precisely to keep that proof and this one independently
      falsifiable rather than coupled through shared plumbing.)

  Boundary discovery is owned by ./boundary_registry.js, not by this file
  -- see docs/HYDRONIUM_CLIENT_BOUNDARY_REGISTRY.md for why that was
  extracted (real, verified duplication with the published WASM proof)
  and what it deliberately does and doesn't do. This file also claims
  ownership of each island it activates, so a future consumer (an HMR
  coordinator, say) attempting to patch the same island concurrently gets
  a loud, explicit conflict instead of silently racing this bootstrap.

  No build step, no dependencies beyond the registry: load this with
  `<script type="module" src=".../bootstrap.js"></script>` on any page
  that used `d.js.island` / `d.lua.mount`. `activate()` is idempotent-safe
  to call once on load; it does not poll or retry -- island DOM is
  assumed to already exist by the time this runs (matches the
  buffered-SSR-only scope of this version; see the doc above for what
  streaming-aware activation would still need).

  IMPORTANT, found while first testing this against a real dynamic
  import(): `d.js.island`'s `module` prop MUST be an absolute path or a
  full URL, never a bare relative one like "./chart.js". A dynamic
  `import(specifier)` call resolves a relative specifier against the
  *importing module's own URL* -- which is this bootstrap file's
  location, not the page's, and not wherever the app's own JS assets
  live. A relative `module` value would therefore resolve against
  wherever Hydronium's own bootstrap.js happens to be deployed, which is
  almost never what an app author wants. Use "/static/chart.js" or a full
  "https://.../chart.js", not "./chart.js".
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

/**
 * Imports an island's module and runs its hydrate()/mount() export.
 *
 * Split out of activate() so the identical sequence can run either
 * immediately (priority "load") or arbitrarily later (a deferred
 * priority). Nothing in here depends on WHEN it runs -- the dynamic
 * import is deliberately part of it, so a deferred island costs no
 * network at all until its trigger fires.
 */
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

  // Lets a page (or a test) observe the exact moment a DEFERRED island
  // came alive, which is otherwise unobservable from outside: activate()
  // has long since resolved by then. Bubbles, so one document-level
  // listener covers every island.
  const el = Array.isArray(context.root) ? context.root[0] : context.root;
  if (el && typeof CustomEvent === "function" && typeof el.dispatchEvent === "function") {
    try {
      el.dispatchEvent(
        new CustomEvent("hydronium:island", {
          detail: { id: island.id, module: island.module, hydrate: island.hydrate || "load" },
          bubbles: true,
        })
      );
    } catch (_) {
      /* nothing to notify in a non-DOM host */
    }
  }
}

/**
 * Activates every `interpreter: "js"` island in the page's client plan,
 * each at the time its own `hydrate` priority asks for.
 *
 * PRIORITY, newly honoured. The server has emitted a per-island `hydrate`
 * field into the client plan since islands v1 (server/init.lua's
 * `hydrate = raw_props.hydrate or "load"`), and real pages have been
 * declaring `hydrate = "visible"` on real islands the whole time -- but
 * nothing here read it, so every island activated immediately regardless.
 * That is now wired through ./priority.js:
 *
 *   "load" (and the default, and anything unrecognized) is awaited inline,
 *   exactly as before -- so a page that declares no priority behaves
 *   byte-for-byte as it did, including the `activatedJsIslands` count it
 *   gets back.
 *
 *   "idle" / "visible" islands are SCHEDULED, not activated: this function
 *   returns without importing their modules at all. They are counted in
 *   `deferredJsIslands`, and `settled` resolves once every one of them has
 *   finished (for "visible", possibly never -- if the user never scrolls
 *   there, which is the entire point). `errors` and `activatedJsIslands`
 *   keep being updated in place as they land, so awaiting `settled` and
 *   re-reading the same result object gives the final tally.
 *
 * Boundary discovery stays EAGER for every island regardless of priority:
 * a missing/duplicate island boundary is a page-structure bug, and it
 * should be reported by the time this resolves rather than surfacing
 * minutes later when somebody happens to scroll.
 *
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
    // Never rejects: activateIsland records failures in `errors` rather
    // than throwing, so one broken island cannot hide the others.
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
