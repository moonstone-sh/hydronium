/**
 * DevTransport: a small, replaceable abstraction over "connect to a dev
 * update source, get called back on each notification." HMR client code
 * (dev_reload.js, and the WASM-Lua HMR proof) should depend on this
 * `{ subscribe(cb), close() }` interface, never directly on EventSource,
 * a specific route path, or Meteorite itself -- Meteorite's
 * `/__hydronium/watch` is the first transport implementation, not an
 * HMR semantic dependency.
 *
 * Reconnection is handled explicitly here, not via native EventSource
 * auto-reconnect: a first implementation relied on the browser's
 * built-in Last-Event-ID mechanism (an `id:` field on every frame,
 * expecting it echoed back as a `Last-Event-ID` request header on
 * reconnect -- the SSE spec's own designed-in way to resume a stream).
 * That was verified live against a real Chromium via Playwright to NOT
 * reliably resend Last-Event-ID for named (non-default) SSE event types
 * across an automatic reconnect -- a real, observed engine gap, not a
 * bug in the server or in this reasoning about the spec. Every
 * `hello`/`reload`/`bye` frame's fingerprint is instead tracked
 * client-side and sent as an explicit `?since=` query parameter (which
 * `/__hydronium/watch` already accepts as its documented fallback) on a
 * connection this code opens and closes itself -- immediately closing
 * the old EventSource before opening the new one means the server's
 * own `retry:` directive never gets a chance to race with it.
 *
 * `/__hydronium/watch` speaks SSE, but this transport asks it for an
 * immediate poll (`budget=0`) and waits in the browser before reconnecting.
 * Sleeping inside a request used to leave several Lua handlers alive when a
 * page was refreshed repeatedly; enough abandoned EventSources could delay
 * the replacement page's SSR request for seconds. The `since` token makes
 * client-paced polling lossless: an edit in the gap is reported by the next
 * request. See docs/METEORITE_STREAMING_FOUNDATION.md.
 *
 * Only `hello` and `reload` are surfaced to subscribers -- `bye` is a
 * transport-internal signal (drives the reconnect) a consumer has no
 * reason to see.
 *
 * A `reload` event also carries `paths`. New servers send per-file stamps
 * in an SSE `snapshot` frame; the browser compares them with its last
 * snapshot so changes between requests retain exact file identity while
 * the `since` token stays fixed-size. Older servers' `changed` frames
 * remain supported. Missing paths mean the edit is unknown, so HMR falls
 * back rather than treating it as no change.
 *
 * @param {string} url
 * @returns {{ subscribe: (cb: (event: {type: "hello"|"reload", fingerprint: string, paths: string[]}) => void) => (() => void), close: () => void }}
 */
export function createDevTransport(url) {
  const pollDelayMs = 500;
  // RELOAD-STORM FLOOR. A `reload` reconnects at delay 0 -- correct for a
  // real edit, where the very next poll's fingerprint matches what the
  // server just reported and the server answers `hello`+`bye`, dropping
  // back to the slow `pollDelayMs` cadence. That assumes the watched set
  // CONVERGES. It does not if something keeps rewriting a watched file on
  // its own -- a generated artifact caught in the watch set (`.meteorite/`
  // output, other build products, `.hydronium/vite-dev.json`) is the prime
  // suspect -- in which case every poll's fingerprint differs from the
  // last again, `reload` fires every time, and delay-0 reconnects become a
  // hot loop: continuous connections, forever (see the module doc above
  // for why polling is client-paced at all). A real edit is always ONE
  // `reload` followed by convergence, never a long unbroken run of them,
  // so a run past this threshold is the signal that something is not
  // converging rather than that edits are arriving unusually fast.
  const RELOAD_STORM_THRESHOLD = 3;
  // Capped exponential backoff once a storm is detected, so a
  // non-converging fingerprint degrades to slow polling instead of
  // spinning -- never raised for everyone, only after sustained
  // back-to-back reloads with no intervening idle (`bye`) poll.
  const MAX_BACKOFF_MS = 8000;
  let closed = false;
  let listeners = [];
  let since = null;
  let source = null;
  let reconnectTimer = null;
  // Consecutive `reload` events with no idle (`hello`/`bye`) poll between
  // them. Reset on every `bye` (server saw nothing new) and on every fresh
  // `hello` (a brand new connection's first frame) -- both mean the
  // watched set was observed to be quiet at least once, so whatever run
  // preceded it is over, storm or not.
  let consecutiveReloads = 0;
  // Set by the `changed` frame that precedes each `reload`, consumed by
  // that `reload` and immediately cleared -- SSE frames are delivered in
  // order over one connection, so the pairing is safe, and clearing
  // means a `reload` from a server that sent no `changed` can never
  // inherit a stale path list from an earlier update.
  let pendingPaths = [];
  let pendingSnapshot = null;
  let lastSnapshot = null;

  function notify(type, fingerprint, paths) {
    for (const cb of listeners) cb({ type, fingerprint, paths: paths || [] });
  }

  function reconnect(delayMs = 0) {
    if (source) source.close();
    source = null;
    if (reconnectTimer !== null) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (closed) return;
    if (delayMs > 0) {
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        reconnect();
      }, delayMs);
      return;
    }
    // A cache-busting `_t` param on every connection, not just a
    // Cache-Control response header, because Meteorite's
    // stream_begin(status, content_type) has no options argument to set
    // one -- verified live: without this, repeated reconnects to the
    // same `?since=...` URL (identical once nothing changes) got served
    // a stale cached response by Chromium's own HTTP cache instead of
    // ever reaching the server again, so a real file edit was never
    // seen by ANY subsequent connection. Pure curl/raw-socket testing
    // never exhibited this (no HTTP cache in the picture at all), which
    // is why it wasn't caught until testing through a real browser.
    // Keep encoding explicitly. Current revisions are fixed-size; older
    // server revisions may contain spaces and require `%20`, not `+`.
    const parts = [`_t=${Date.now()}`, "budget=0"];
    if (since) parts.push(`since=${encodeURIComponent(since)}`);
    const fullUrl = `${url}?${parts.join("&")}`;
    source = new EventSource(fullUrl);
    source.addEventListener("hello", (ev) => {
      since = ev.data;
      consecutiveReloads = 0;
      if (pendingSnapshot) {
        lastSnapshot = pendingSnapshot;
        pendingSnapshot = null;
      }
      notify("hello", ev.data);
    });
    source.addEventListener("snapshot", (ev) => {
      try {
        const parsed = JSON.parse(String(ev.data || ""));
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          pendingSnapshot = parsed;
        }
      } catch {
        pendingSnapshot = null;
      }
    });
    source.addEventListener("changed", (ev) => {
      pendingPaths = String(ev.data || "")
        .split("|")
        .filter((p) => p !== "");
    });
    source.addEventListener("reload", (ev) => {
      since = ev.data;
      let paths = pendingPaths;
      if (pendingSnapshot) {
        if (lastSnapshot) {
          const names = new Set([...Object.keys(lastSnapshot), ...Object.keys(pendingSnapshot)]);
          paths = [...names].filter((name) => {
            const before = Object.prototype.hasOwnProperty.call(lastSnapshot, name) ? lastSnapshot[name] : undefined;
            const after = Object.prototype.hasOwnProperty.call(pendingSnapshot, name) ? pendingSnapshot[name] : undefined;
            return before !== after;
          }).sort();
        }
        lastSnapshot = pendingSnapshot;
        pendingSnapshot = null;
      }
      pendingPaths = [];
      notify("reload", ev.data, paths);
      consecutiveReloads += 1;
      if (consecutiveReloads <= RELOAD_STORM_THRESHOLD) {
        // A real edit: still instant, exactly as before this fix.
        reconnect();
      } else {
        // consecutiveReloads has already run past the threshold at least
        // once (RELOAD_STORM_THRESHOLD + 1), so this exponent starts at 0.
        const steps = consecutiveReloads - RELOAD_STORM_THRESHOLD - 1;
        const delay = Math.min(pollDelayMs * 2 ** steps, MAX_BACKOFF_MS);
        reconnect(delay);
      }
    });
    source.addEventListener("bye", (ev) => {
      since = ev.data;
      consecutiveReloads = 0;
      reconnect(pollDelayMs);
    });
  }

  reconnect();

  return {
    subscribe(cb) {
      listeners.push(cb);
      return () => {
        listeners = listeners.filter((l) => l !== cb);
      };
    },
    close() {
      closed = true;
      if (source) source.close();
      source = null;
      if (reconnectTimer !== null) clearTimeout(reconnectTimer);
      reconnectTimer = null;
    },
  };
}
