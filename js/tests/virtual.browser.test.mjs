// Real-browser contract test for Hydronium's virtual-scroll DOM bridge.
//
// The Lua adapter is covered by the Lua suite. This test deliberately owns
// only the browser half: real scroll positions, real element dimensions and
// real ResizeObserver cleanup. It imports the shipped source module rather
// than a copied implementation.

import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC = join(__dirname, "../packages/dom-client/src");

const PAGE = `<!doctype html><html><body>
  <!-- #row is the measured item (40px tall).  The spacer exists only so the
       container actually has somewhere to scroll TO: without it the content is
       shorter than the 100px viewport and the browser clamps scrollTop to 0,
       so scroll_virtual_container(.., 80) would silently do nothing. -->
  <div id="list" style="height:100px;width:120px;overflow:auto"><div id="row" style="height:40px;width:300px"></div><div id="spacer" style="height:400px;width:300px"></div></div>
  <script type="module">
    import { createDomBridge } from "/dom_bridge.js";
    const bridge = createDomBridge();
    const list = document.querySelector("#list");
    const row = document.querySelector("#row");
    window.__events = { viewport: [], offset: [], item: [] };
    window.__bridge = bridge;
    window.__stopContainer = bridge.observe_virtual_container(list, "vertical",
      value => window.__events.viewport.push(value),
      value => window.__events.offset.push(value));
    window.__stopItem = bridge.observe_virtual_item(row, "vertical",
      value => window.__events.item.push(value));
    window.__ready = true;
  </script>
</body></html>`;

function startServer() {
  const server = createServer(async (req, res) => {
    const url = req.url.split("?")[0];
    if (url === "/") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(PAGE);
      return;
    }
    try {
      const body = await readFile(join(SRC, url.replace(/^\//, "")));
      res.writeHead(200, { "content-type": extname(url) === ".js" ? "text/javascript; charset=utf-8" : "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404).end("not found");
    }
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port })));
}

test("virtual bridge observes real DOM geometry, scrolls on its selected axis, and cleans up", async (t) => {
  const { server, port } = await startServer();
  const browser = await chromium.launch();
  t.after(async () => {
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
  });

  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
  await page.waitForFunction(() => window.__ready === true);
  await page.waitForFunction(() => window.__events.viewport.length > 0 && window.__events.item.length > 0);

  assert.equal(await page.evaluate(() => window.__events.viewport[0]), 100);
  assert.equal(await page.evaluate(() => window.__events.item[0]), 40);

  await page.evaluate(() => window.__bridge.scroll_virtual_container(document.querySelector("#list"), "vertical", 80));
  await page.waitForFunction(() => window.__events.offset.at(-1) === 80);
  assert.equal(await page.evaluate(() => document.querySelector("#list").scrollTop), 80);

  // Horizontal mode must use width/scrollLeft without changing vertical state.
  const horizontal = await page.evaluate(() => {
    const list = document.querySelector("#list");
    const seen = [];
    const stop = window.__bridge.observe_virtual_container(list, "horizontal", value => seen.push(["viewport", value]), value => seen.push(["offset", value]));
    window.__bridge.scroll_virtual_container(list, "horizontal", 60);
    stop();
    return { seen, scrollLeft: list.scrollLeft, scrollTop: list.scrollTop };
  });
  assert.deepEqual(horizontal.seen.slice(0, 2), [["viewport", 120], ["offset", 0]]);
  assert.equal(horizontal.scrollLeft, 60);
  assert.equal(horizontal.scrollTop, 80);

  const beforeCleanup = await page.evaluate(() => window.__events.offset.length);
  await page.evaluate(() => { window.__stopContainer(); window.__stopItem(); document.querySelector("#list").scrollTop = 20; });
  await page.waitForTimeout(50);
  assert.equal(await page.evaluate(() => window.__events.offset.length), beforeCleanup, "a disposed observer must not receive later scrolls");
  assert.deepEqual(errors, [], "no browser exceptions while running the bridge");
});
