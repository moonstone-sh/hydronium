import test from "node:test";
import assert from "node:assert/strict";

import { createDevTransport } from "../../js/packages/dom-client/src/dev_transport.js";

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

// Reload-storm floor: dev_transport.js's own module doc explains why a
// `reload` reconnects at delay 0 -- correct for a real edit, where the
// very next poll converges (server answers hello+bye). A watched file
// that never stops changing on its own (a generated artifact caught in
// the watch set is the prime suspect -- see the fix's comment) makes
// EVERY poll look like a real change, so delay-0 reconnects never stop.
// These specs drive a fake EventSource through exactly that: `reload`
// fired over and over with no `bye`/`hello` between them.
function installFakeEventSourceAndTimers() {
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

  return {
    sources,
    timers,
    restore() {
      globalThis.EventSource = originalEventSource;
      globalThis.setTimeout = originalSetTimeout;
      globalThis.clearTimeout = originalClearTimeout;
    },
  };
}

test("a real edit (one reload, then convergence) keeps reconnecting instantly, unchanged", () => {
  const env = installFakeEventSourceAndTimers();
  try {
    createDevTransport("/__hydronium/watch");

    // Fewer than the storm threshold: every reload reconnects with a new
    // EventSource immediately (delay 0 means no setTimeout at all).
    env.sources[0].emit("reload", "fp-1");
    assert.equal(env.sources.length, 2, "first reload reconnects instantly");
    env.sources[1].emit("reload", "fp-2");
    assert.equal(env.sources.length, 3, "second reload still reconnects instantly");
    assert.equal(env.timers.length, 0, "no backoff timer was ever scheduled");

    // Converges: the next poll finds nothing new.
    env.sources[2].emit("hello", "fp-2");
    env.sources[2].emit("bye", "fp-2");
    assert.equal(env.timers.length, 1);
    assert.equal(env.timers[0].delay, 500, "converging falls back to the ordinary slow poll, not a storm backoff");
  } finally {
    env.restore();
  }
});

test("a non-converging fingerprint degrades to slow, capped backoff instead of spinning", () => {
  const env = installFakeEventSourceAndTimers();
  try {
    createDevTransport("/__hydronium/watch");

    // Three consecutive reloads still reconnect instantly (matches a
    // real, if unusually fast, burst of edits) -- no timer scheduled yet.
    env.sources[0].emit("reload", "fp-1");
    env.sources[1].emit("reload", "fp-2");
    env.sources[2].emit("reload", "fp-3");
    assert.equal(env.sources.length, 4);
    assert.equal(env.timers.length, 0, "still within the storm threshold");

    // The 4th consecutive reload with no idle poll in between is where a
    // real edit and a non-converging watch set stop looking alike --
    // this is the fix: back off instead of reconnecting at delay 0 forever.
    env.sources[3].emit("reload", "fp-4");
    assert.equal(env.timers.length, 1);
    assert.equal(env.sources.length, 4, "delayed reconnect does not open a new source until the timer fires");
    assert.equal(env.timers[0].delay, 500, "first storm step matches the ordinary slow-poll floor");

    env.timers[0].fn();
    assert.equal(env.sources.length, 5);
    env.sources[4].emit("reload", "fp-5");
    assert.equal(env.timers[1].delay, 1000, "backoff grows on sustained non-convergence");

    env.timers[1].fn();
    env.sources[5].emit("reload", "fp-6");
    assert.equal(env.timers[2].delay, 2000);

    env.timers[2].fn();
    env.sources[6].emit("reload", "fp-7");
    assert.equal(env.timers[3].delay, 4000);

    env.timers[3].fn();
    env.sources[7].emit("reload", "fp-8");
    assert.equal(env.timers[4].delay, 8000, "capped");

    env.timers[4].fn();
    env.sources[8].emit("reload", "fp-9");
    assert.equal(env.timers[5].delay, 8000, "stays capped rather than growing unbounded");
  } finally {
    env.restore();
  }
});

test("an idle poll (bye) after a storm resets the floor, so the next real edit is instant again", () => {
  const env = installFakeEventSourceAndTimers();
  try {
    createDevTransport("/__hydronium/watch");

    for (let i = 0; i < 5; i++) {
      env.sources[env.sources.length - 1]?.emit("reload", `fp-${i}`);
      if (env.timers.length > 0) {
        env.timers[env.timers.length - 1].fn();
      }
    }
    assert.ok(env.timers.length > 0, "sanity: a storm backoff was in effect");

    const lastSource = env.sources[env.sources.length - 1];
    lastSource.emit("hello", "fp-quiet");
    lastSource.emit("bye", "fp-quiet");
    const byeTimerCount = env.timers.length;
    env.timers[byeTimerCount - 1].fn();

    const sourceCountBeforeEdit = env.sources.length;
    env.sources[env.sources.length - 1].emit("reload", "fp-real-edit");
    assert.equal(
      env.sources.length,
      sourceCountBeforeEdit + 1,
      "reconnected with a brand new EventSource immediately -- no backoff timer for this one"
    );
    assert.equal(env.timers.length, byeTimerCount, "no new timer was scheduled for the post-quiet reload");
  } finally {
    env.restore();
  }
});
