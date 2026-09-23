// Real-browser check for the M1 gate in docs/HYDRONIUM_SPA_MODE_PLAN.md:
// "a real browser check that a hashchange reaches a subscriber."
//
// Scoped exactly like M1 itself -- "no bundling, no app": this exercises
// ONLY router/client/hash_history.js, the JS half of
// hydronium_router.history.hash's bridge contract. No Lua, no wasmoon, no
// Meteorite/Vite dev server dependency -- it starts its own throwaway
// static HTTP server on a free port and serves the real, unmodified
// hash_history.js straight off disk (not a copy), so this test would
// catch real drift in the shipped file.
//
// Lives under js/ (not tests/client/, which sits outside the JS pnpm
// workspace and cannot resolve the "playwright" devDependency hoisted to
// js/node_modules) -- see docs/HYDRONIUM_SPA_MODE_PLAN.md hazard 2 on
// router/client/ being an unpackaged second pile of client JS outside
// @hydronium/dom-client; this test's own location is the same hazard.
//
// Run: node --test js/tests/router_hash_history.browser.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CLIENT_DIR = join(__dirname, "../../router/client");

const MIME = {
  ".js": "text/javascript; charset=utf-8",
  ".html": "text/html; charset=utf-8",
};

const INDEX_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>hash_history bridge check</title></head>
<body>
<script type="module">
  import { createHashHistoryBridge } from "/hash_history.js";

  window.__events = [];
  window.__unsubscribed = false;

  const bridge = createHashHistoryBridge();
  window.__bridge = bridge;
  const unsubscribe = bridge.on_change(() => {
    window.__events.push(bridge.read());
  });
  window.__unsubscribe = () => { unsubscribe(); window.__unsubscribed = true; };
  window.__ready = true;
</script>
</body></html>`;

function startServer() {
  return new Promise((resolve) => {
    const server = createServer(async (req, res) => {
      if (req.url === "/" || req.url === "/index.html") {
        res.writeHead(200, { "content-type": MIME[".html"] });
        res.end(INDEX_HTML);
        return;
      }
      try {
        const body = await readFile(join(CLIENT_DIR, req.url));
        res.writeHead(200, { "content-type": MIME[extname(req.url)] || "application/octet-stream" });
        res.end(body);
      } catch {
        res.writeHead(404);
        res.end("not found");
      }
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

test("a real 'hashchange' from location.hash assignment reaches an on_change subscriber", async (t) => {
  const server = await startServer();
  const { port } = server.address();
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const pageErrors = [];
  page.on("pageerror", (e) => pageErrors.push(String(e)));

  t.after(async () => {
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
  });

  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
  await page.waitForFunction(() => window.__ready === true);

  // --- a plain `location.hash = ...` assignment (the real navigation
  //     path hash.lua's push() drives) fires a real, observable event ---
  await page.evaluate(() => { window.location.hash = "/second?x=1"; });
  await page.waitForFunction(() => window.__events.length > 0, null, { timeout: 5000 });
  assert.equal(await page.evaluate(() => window.__events[0]), "#/second?x=1");
  assert.equal(await page.evaluate(() => window.location.hash), "#/second?x=1");

  // --- bridge.write() (the real push() path: hash assignment + a
  //     replaceState to attach state) also reaches the subscriber ---
  await page.evaluate(() => window.__bridge.write("/third", '{"n":1}'));
  await page.waitForFunction(() => window.__events.length > 1, null, { timeout: 5000 });
  assert.equal(await page.evaluate(() => window.__events[1]), "#/third");
  assert.equal(
    await page.evaluate(() => window.history.state && window.history.state.__hydronium_router_hash_state_v1),
    '{"n":1}',
    "write() must attach state via replaceState onto the entry it just pushed"
  );

  // --- bridge.replace() must NOT fire a change event (no new entry) ---
  const beforeReplace = await page.evaluate(() => window.__events.length);
  await page.evaluate(() => window.__bridge.replace("/third-edited", "null"));
  // Give any (wrongly) queued event a turn to arrive before asserting none did.
  await page.waitForTimeout(50);
  assert.equal(await page.evaluate(() => window.__events.length), beforeReplace,
    "replace() must not fire hashchange");
  assert.equal(await page.evaluate(() => window.location.hash), "#/third-edited");

  // --- real browser back/forward navigate among the entries write()
  //     actually pushed, and each one fires hashchange too ---
  await page.goBack();
  await page.waitForFunction(
    (expected) => window.location.hash === expected,
    "#/second?x=1",
    { timeout: 5000 }
  );
  await page.waitForFunction((n) => window.__events.length > n, beforeReplace, { timeout: 5000 });
  assert.equal(await page.evaluate(() => window.__events[window.__events.length - 1]), "#/second?x=1");

  // --- on_change's returned unsubscribe function really detaches ------
  const countBeforeUnsub = await page.evaluate(() => window.__events.length);
  await page.evaluate(() => window.__unsubscribe());
  assert.equal(await page.evaluate(() => window.__unsubscribed), true);
  await page.evaluate(() => { window.location.hash = "/after-unsubscribe"; });
  await page.waitForTimeout(50);
  assert.equal(await page.evaluate(() => window.__events.length), countBeforeUnsub,
    "no further event should reach a detached subscriber");

  assert.deepEqual(pageErrors, [], "uncaught page errors during the hashchange bridge check");
});
