// Real-browser proof for the dev error overlay.
//
// The unit tests (tests/client/overlay.test.mjs) cover parsing and DOM shape
// against a fake document. What they CANNOT show is the thing that actually
// matters to a developer: that the overlay is really on top of the page,
// visible, and dismissable. That needs a real browser, so it lives here.
//
// Serves the real module from js/packages/dom-client/src/ -- not a copy.
//
// Run: node --test js/tests/overlay.browser.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC = join(__dirname, "../packages/dom-client/src");

const TRACEBACK = [
  '[string "views.App"]:12: attempt to index a nil value (field \'props\')',
  "stack traceback:",
  '\t[string "views.App"]:12: in function <[string "views.App"]:9>',
  '\t[string "hydronium.core.component"]:406: in function \'refresh\'',
].join("\n");

const PAGE = `<!doctype html><html><body>
<div id="app">the page content, which must stay in the DOM behind the overlay</div>
<script type="module">
  import { installErrorOverlay } from "/overlay.js";
  const dev = installErrorOverlay();
  window.__report = (msg) => dev.report("mount", new Error(msg));
</script>
</body></html>`;

function startServer() {
  const server = createServer(async (req, res) => {
    const url = req.url.split("?")[0];
    if (url === "/") {
      res.writeHead(200, { "content-type": "text/html" });
      return res.end(PAGE);
    }
    try {
      const body = await readFile(join(SRC, url.replace(/^\//, "")));
      const type = extname(url) === ".js" ? "text/javascript" : "application/octet-stream";
      res.writeHead(200, { "content-type": type });
      res.end(body);
    } catch {
      res.writeHead(404).end("not found");
    }
  });
  return new Promise((resolve) => {
    // Port 0: never collide with a dev server someone left running.
    server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port }));
  });
}

test("the error overlay really renders over the page and dismisses", async (t) => {
  const { server, port } = await startServer();
  const browser = await chromium.launch();
  t.after(async () => {
    await browser.close();
    await new Promise((r) => server.close(r));
  });

  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle" });

  // Nothing before an error: the overlay must not exist merely because it
  // was installed.
  assert.equal(await page.locator("#__hydronium_error_overlay__").count(), 0);

  await page.evaluate((tb) => window.__report(tb), TRACEBACK);
  const overlay = page.locator("#__hydronium_error_overlay__");
  await overlay.waitFor({ state: "visible", timeout: 5000 });

  const text = await overlay.textContent();
  assert.match(text, /attempt to index a nil value/, "the message");
  assert.match(text, /views\.App/, "the Lua frame");
  assert.match(text, /stack traceback:/, "the raw traceback, verbatim");

  // Actually on top and actually covering -- a container that renders but sits
  // behind the page, or collapses to zero height, would pass a textContent
  // check and still be useless.
  const box = await overlay.boundingBox();
  const viewport = page.viewportSize();
  assert.ok(box.height > viewport.height * 0.5, `overlay too short: ${box.height}px`);
  const onTop = await page.evaluate(() => {
    const o = document.getElementById("__hydronium_error_overlay__");
    const mid = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2);
    return o.contains(mid) || o === mid;
  });
  assert.equal(onTop, true, "the overlay must be the element at the centre of the viewport");

  // The page underneath is not destroyed -- this is an overlay, not a replace.
  assert.match(await page.locator("#app").textContent(), /the page content/);

  await page.getByRole("button", { name: "Dismiss" }).click();
  await overlay.waitFor({ state: "detached", timeout: 5000 });
  assert.equal(await page.locator("#__hydronium_error_overlay__").count(), 0);
});
