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
 * A `reload` event also carries `paths`: the watched files the server
 * says actually moved, from the `changed` frame it emits immediately
 * before each `reload` (see hydronium_dom/dev/watch.lua's PROTOCOL
 * note). This is what lets a real HMR client (hmr.js) hot-swap one
 * module instead of reloading the page. It is always an array, empty
 * when the server is an older one that never sends `changed` at all --
 * so a consumer treats "no paths" as "I don't know what changed", which
 * hmr.js maps to its full-reload fallback rather than to "nothing
 * changed".
 *
 * @param {string} url
 * @returns {{ subscribe: (cb: (event: {type: "hello"|"reload", fingerprint: string, paths: string[]}) => void) => (() => void), close: () => void }}
 */
export function createDevTransport(url) {
  const pollDelayMs = 500;
  let closed = false;
  let listeners = [];
  let since = null;
  let source = null;
  let reconnectTimer = null;
  // Set by the `changed` frame that precedes each `reload`, consumed by
  // that `reload` and immediately cleared -- SSE frames are delivered in
  // order over one connection, so the pairing is safe, and clearing
  // means a `reload` from a server that sent no `changed` can never
  // inherit a stale path list from an earlier update.
  let pendingPaths = [];

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
    // Built with encodeURIComponent, NOT URLSearchParams -- found live,
    // and it silently broke the whole `since` mechanism. A fingerprint
    // contains spaces (it is `stat` output), and
    // URLSearchParams.toString() serializes a space as `+` per the
    // application/x-www-form-urlencoded rules, while Meteorite's query
    // parser decodes `%20` but treats `+` literally. So the server
    // received a `since` that could never equal any fingerprint it
    // computes, took its "changed while you were disconnected" branch on
    // EVERY reconnect, and answered with an immediate `reload`.
    //
    // With dev_reload.js that surfaced only as an unexplained periodic
    // page refresh -- easy to miss, since a reload is what that client
    // does anyway. It is fatal for hmr.js: a bogus `since` also makes
    // the server's per-file diff report every watched file as changed,
    // which reads as "I can't tell what changed" and forces a full
    // reload instead of a hot swap. Verified against the real route:
    // percent-encoded `since` round-trips and names exactly the one file
    // edited; plus-encoded `since` names all of them.
    const parts = [`_t=${Date.now()}`, "budget=0"];
    if (since) parts.push(`since=${encodeURIComponent(since)}`);
    const fullUrl = `${url}?${parts.join("&")}`;
    source = new EventSource(fullUrl);
    source.addEventListener("hello", (ev) => {
      since = ev.data;
      notify("hello", ev.data);
    });
    source.addEventListener("changed", (ev) => {
      pendingPaths = String(ev.data || "")
        .split("|")
        .filter((p) => p !== "");
    });
    source.addEventListener("reload", (ev) => {
      since = ev.data;
      const paths = pendingPaths;
      pendingPaths = [];
      notify("reload", ev.data, paths);
      reconnect();
    });
    source.addEventListener("bye", (ev) => {
      since = ev.data;
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
