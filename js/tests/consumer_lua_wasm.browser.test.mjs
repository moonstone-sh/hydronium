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
    const display = page.locator(".count");
    assert.equal((await display.textContent()).trim(), "3");
    await page.getByRole("button", { name: "More", exact: true }).click();
    await page.waitForFunction(() => document.querySelector(".count")?.textContent.trim() === "4");
    await page.getByRole("button", { name: "More", exact: true }).click();
    await page.waitForFunction(() => document.querySelector(".count")?.textContent.trim() === "5");

    // Progressive form: the Lua submit handler runs the action over fetch and
    // renders its result in place (forms bridge + retained Lua callbacks).
    const bootId = await page.evaluate(() => window.__bootId);
    await page.fill("#name", "Ada");
    await page.route("**/actions/hello", async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 250));
      await route.continue();
    });
    await page.click("form button[type=submit]");
    assert.equal(await page.locator("form button[type=submit]").isDisabled(), true, "pending submission disables the button");
    await page.waitForFunction(() => document.querySelector(".result")?.textContent.includes("Hello, Ada"), null, { timeout: 15_000 });
    assert.equal(await page.locator('input[name="times"]').inputValue(), "5");
    assert.equal(await page.locator("form button[type=submit]").isDisabled(), false);
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


test("packaged SSR greeting form works without JavaScript", { skip: !baseUrl }, async () => {
  const browser = await chromium.launch();
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  try {
    await page.goto(`${baseUrl}/`);
    await page.fill("#name", "Ada");
    const [response] = await Promise.all([
      page.waitForResponse(r => r.request().method() === "POST" && r.url().endsWith("/actions/hello")),
      page.getByRole("button", { name: "Say hello", exact: true }).click(),
    ]);
    assert.equal(response.status(), 201);
    assert.equal(await page.locator(".result").textContent(), "Hello, Ada! Hello, Ada! Hello, Ada!");
    assert.equal(await page.locator("#name").inputValue(), "Ada");
    assert.equal(await page.locator(".count").textContent(), "3");
    await page.goto(`${baseUrl}/`);
    const [invalid] = await Promise.all([
      page.waitForResponse(r => r.request().method() === "POST"),
      page.getByRole("button", { name: "Say hello", exact: true }).click(),
    ]);
    assert.equal(invalid.status(), 422);
    assert.match(await page.locator(".result.error").textContent(), /Who should we say hello to/);
    assert.equal(await page.getByRole("link", { name: "Home", exact: true }).getAttribute("href"), "/");
  } finally { await browser.close(); }
});
