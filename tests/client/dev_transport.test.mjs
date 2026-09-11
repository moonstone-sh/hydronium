import test from "node:test";
import assert from "node:assert/strict";

import { createDevTransport } from "../../dom/src/hydronium_dom/client/dev_transport.js";

test("dev transport uses client-paced immediate polls and carries the fingerprint", () => {
  const originalEventSource = globalThis.EventSource;
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  const sources = [];
  const timers = [];

  class FakeEventSource {
    constructor(url) {
      this.url = url;
      this.listeners = new Map();
      this.closed = false;
      sources.push(this);
    }

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    emit(type, data) {
      this.listeners.get(type)?.({ data });
    }

    close() {
      this.closed = true;
    }
  }

  globalThis.EventSource = FakeEventSource;
  globalThis.setTimeout = (fn, delay) => {
    const timer = { fn, delay, cleared: false };
    timers.push(timer);
    return timer;
  };
  globalThis.clearTimeout = (timer) => {
    timer.cleared = true;
  };

  try {
    const transport = createDevTransport("/__hydronium/watch");
    assert.equal(sources.length, 1);
    assert.match(sources[0].url, /[?&]budget=0(?:&|$)/);

    sources[0].emit("hello", "views/App.luax|12 34");
    sources[0].emit("bye", "views/App.luax|12 34");
    assert.equal(sources[0].closed, true);
    assert.equal(timers.length, 1);
    assert.equal(timers[0].delay, 500);

    timers[0].fn();
    assert.equal(sources.length, 2);
    assert.match(sources[1].url, /[?&]budget=0(?:&|$)/);
    assert.match(sources[1].url, /since=views%2FApp\.luax%7C12%2034/);

    transport.close();
    assert.equal(sources[1].closed, true);
  } finally {
    globalThis.EventSource = originalEventSource;
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  }
});

test("reload reconnects immediately and forwards changed paths", () => {
  const originalEventSource = globalThis.EventSource;
  const sources = [];

  class FakeEventSource {
    constructor(url) {
      this.url = url;
      this.listeners = new Map();
      this.closed = false;
      sources.push(this);
    }

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    emit(type, data) {
      this.listeners.get(type)?.({ data });
    }

    close() {
      this.closed = true;
    }
  }

  globalThis.EventSource = FakeEventSource;
  try {
    const transport = createDevTransport("/__hydronium/watch");
    const events = [];
    transport.subscribe((event) => events.push(event));

    sources[0].emit("changed", "views/App.luax|public/style.css");
    sources[0].emit("reload", "next fingerprint");

    assert.deepEqual(events, [{
      type: "reload",
      fingerprint: "next fingerprint",
      paths: ["views/App.luax", "public/style.css"],
    }]);
    assert.equal(sources[0].closed, true);
    assert.equal(sources.length, 2);
    assert.match(sources[1].url, /since=next%20fingerprint/);
    transport.close();
  } finally {
    globalThis.EventSource = originalEventSource;
  }
});
