/*
  ClientBoundaryRegistry -- the one place that knows how a Hydronium
  boundary is represented in the DOM. Consumers (the client bootstrap
  today; a future streaming-Suspense patcher and HMR coordinator) ask
  semantic questions (discover, claim, elements, generation) and never
  parse comment markers themselves.

  Extracted from real, duplicated code: `bootstrap.js` and the published
  "Hydronium in WASM" hydration proof each independently implemented
  `findIslandRange`/`queryButton`-shaped marker traversal (verified by
  reading both files side by side; see
  docs/HYDRONIUM_CLIENT_BOUNDARY_REGISTRY.md for the exact diff). Neither
  is a mock -- both are real, shipped consumers, migrated below to use
  this module instead of their own copy.

  Scope, deliberately: only what current or concretely-anticipated
  consumers need. `discover`/`elements`/`claim`/`release`/`generation`/
  `advanceGeneration`/`isStale`/`dispose` exist because hydration needs
  them now and a streaming patcher or HMR coordinator would need the same
  shapes later (range-based boundaries, ownership, staleness rejection)
  without inventing new marker semantics. Boundary kind "suspense" and
  states like "declared"/"pending" are NOT implemented -- no real
  consumer exists yet to prove their shape against (see
  docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md's own warning against
  building speculative methods).

  Marker format (unchanged, matches src/hydronium/server/init.lua's
  ISLAND handling): a start comment `hy:i:<id>:<interpreter>` and an end
  comment `hy:/i:<id>`, direct DOM siblings, zero or more nodes between.
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
 * null if the boundary is not present in the DOM at all (not an error --
 * e.g. its SSR segment hasn't arrived yet). Throws on malformed markers
 * (duplicate start, missing end) -- see findMarkers.
 * @param {Node} root
 * @param {string} id
 * @param {"island"} [kind]
 * @returns {{kind: string, generation: number, owner: string|null, state: string}|null}
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
 * Claims exclusive ownership of a boundary for `owner` (a free-form
 * string identifying the claiming subsystem, e.g. "hydration",
 * "stream-patcher", "hmr"). Idempotent for the same owner. Throws if a
 * *different* owner already holds the claim -- the invariant this exists
 * to enforce is that two independent patch mechanisms must never believe
 * they own the same DOM range concurrently; a silent bool return would
 * let that invariant be violated silently.
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

/** Current generation, or -1 if the boundary is unknown. */
export function generation(id) {
  const b = boundaries.get(id);
  return b ? b.generation : -1;
}

/** Increments and returns the new generation. No-op (-1) if unknown. */
export function advanceGeneration(id) {
  const b = boundaries.get(id);
  if (!b) return -1;
  b.generation += 1;
  return b.generation;
}

/**
 * Whether a mutation tagged with `incomingGeneration` should be rejected
 * as stale. An unknown boundary is treated as stale (reject) -- there is
 * nothing safe to mutate. Must be checked before applying any DOM change
 * driven by async/out-of-order work (this is the concrete mechanism
 * behind "reject stale mutations before DOM mutation").
 */
export function isStale(id, incomingGeneration) {
  const b = boundaries.get(id);
  if (!b) return true;
  return incomingGeneration < b.generation;
}

export function dispose(id) {
  boundaries.delete(id);
}

/** Test/inspection only -- clears all registrations. */
export function _reset() {
  boundaries.clear();
}
