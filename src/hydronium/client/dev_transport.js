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
 * `/__hydronium/watch` (examples/meteorite_ssr/src/main.lua) is a
 * bounded long-poll -- not an indefinite stream -- shaped like SSE.
 * Verified live end to end: an edit landing while a connection is open
 * mid-poll delivers `reload` within one poll tick; an edit landing in
 * the gap between connections (nothing connected at all) is caught by
 * the very next connection's `since` check. See
 * docs/METEORITE_STREAMING_FOUNDATION.md.
 *
 * Only `hello` and `reload` are surfaced to subscribers -- `bye` is a
 * transport-internal signal (drives the reconnect) a consumer has no
 * reason to see.
 *
 * @param {string} url
 * @returns {{ subscribe: (cb: (event: {type: "hello"|"reload", fingerprint: string}) => void) => (() => void), close: () => void }}
 */
export function createDevTransport(url) {
  let closed = false;
  let listeners = [];
  let since = null;
  let source = null;

  function notify(type, fingerprint) {
    for (const cb of listeners) cb({ type, fingerprint });
  }

  function reconnect() {
    if (source) source.close();
    if (closed) return;
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
    const params = new URLSearchParams({ _t: String(Date.now()) });
    if (since) params.set("since", since);
    const fullUrl = `${url}?${params.toString()}`;
    source = new EventSource(fullUrl);
    source.addEventListener("hello", (ev) => {
      since = ev.data;
      notify("hello", ev.data);
    });
    source.addEventListener("reload", (ev) => {
      since = ev.data;
      notify("reload", ev.data);
      reconnect();
    });
    source.addEventListener("bye", (ev) => {
      since = ev.data;
      reconnect();
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
    },
  };
}
