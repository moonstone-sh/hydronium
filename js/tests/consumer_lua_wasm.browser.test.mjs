// The browser half of the packaged lua-wasm gate: tests/e2e/consumer_scaffold.sh
// with HYDRONIUM_CONSUMER_TEMPLATE=ssr. The app is scaffolded and built from
// the *exported packages* (no source-tree overlays) and served by its real
// Meteorite release binary, so this proves the published client closure boots
// Hydronium's default lua-wasm engine and that hydration, the DOM bridge, the
// forms bridge and router navigation work on it.
import test from "node:test";
import assert from "node:assert/strict";
import * as playwright from "playwright";
// HYDRONIUM_BROWSER=firefox|webkit runs the same suite in another engine.
const chromium = playwright[process.env.HYDRONIUM_BROWSER || "chromium"];

const baseUrl = process.env.HYDRONIUM_CONSUMER_URL;

test("packaged SSR app hydrates and runs on the default lua-wasm engine", { skip: !baseUrl }, async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const consoleErrors = [], pageErrors = [], requested = [];
  page.on("console", (message) => { if (message.type() === "error") consoleErrors.push(message.text()); });
  page.on("pageerror", (error) => pageErrors.push(String(error)));
  page.on("request", (request) => requested.push(new URL(request.url()).pathname));
  await page.addInitScript(() => { window.__bootId = Math.random(); });
  try {
    const response = await page.goto(`${baseUrl}/`, { waitUntil: "domcontentloaded" });
    assert.equal(response?.status(), 200);
    // mount() records this measure only after the client render completed.
    await page.waitForFunction(() => performance.getEntriesByName("hydronium:total").length > 0, null, { timeout: 30_000 });

    assert.ok(requested.some((path) => path.endsWith("/vendor/lua-wasm/5.4.9/engine.wasm")), "the lua-wasm engine binary must be served");
    assert.ok(requested.some((path) => path.endsWith("/vendor/lua-wasm/5.4.9/task-runtime.mjs")), "the lua-wasm task runtime must be served");
    assert.ok(!requested.some((path) => path.includes("wasmoon")), "the default boot must not request Wasmoon");

    // Counter: interactive only once the Lua VM has hydrated the SSR markup.
    const display = page.locator(".count-display");
    assert.equal((await display.textContent()).trim(), "Count: 0");
    await page.locator(".counter-box .btn-primary").click();
    await page.waitForFunction(() => document.querySelector(".count-display")?.textContent.trim() === "Count: 1");
    await page.locator(".counter-box .btn-primary").click();
    await page.waitForFunction(() => document.querySelector(".count-display")?.textContent.trim() === "Count: 2");

    // Progressive form: the Lua submit handler runs the action over fetch and
    // renders its result in place (forms bridge + retained Lua callbacks).
    const bootId = await page.evaluate(() => window.__bootId);
    await page.fill("#name", "Ada");
    await page.click("form button[type=submit]");
    await page.waitForFunction(() => document.querySelector(".form-result")?.textContent.includes("Hello, Ada"), null, { timeout: 15_000 });
    assert.equal(await page.evaluate(() => location.pathname), "/", "the enhanced submit must not navigate");
    assert.equal(await page.evaluate(() => window.__bootId), bootId, "the enhanced submit must not reload the page");

    // Router navigation through a Lua onNavigate handler, without a reload.
    await page.click("a[href='/about']");
    await page.waitForFunction(() => location.pathname === "/about", null, { timeout: 15_000 });
    assert.equal(await page.evaluate(() => window.__bootId), bootId, "client-side navigation must not reload the page");

    assert.deepEqual(pageErrors, []);
    assert.deepEqual(consoleErrors, []);
  } finally {
    await browser.close();
  }
});
