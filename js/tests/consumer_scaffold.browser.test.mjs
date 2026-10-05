// The browser half of tests/e2e/consumer_scaffold.sh (islands template).
// The shell harness owns packaging, registry materialization, and the
// service lifetime; this test makes the failure signals a blank page
// otherwise hides explicit.
import test from "node:test";
import assert from "node:assert/strict";
import * as playwright from "playwright";

// HYDRONIUM_BROWSER=firefox|webkit runs the same gate in another engine.
const browserType = playwright[process.env.HYDRONIUM_BROWSER || "chromium"];
const baseUrl = process.env.HYDRONIUM_CONSUMER_URL;

test("published islands scaffold renders, hydrates its island and posts the form", { skip: !baseUrl }, async () => {
  const browser = await browserType.launch();
  const page = await browser.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  const requestFailures = [];

  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => pageErrors.push(String(error)));
  page.on("requestfailed", (request) => {
    const failure = request.failure()?.errorText;
    // Development watch requests are cancellable long polls, not assets.
    if (new URL(request.url()).pathname === "/__hydronium/watch" && failure === "net::ERR_ABORTED") return;
    requestFailures.push(`${request.url()}: ${failure}`);
  });

  try {
    // The scaffold keeps a long-lived SSE watch connection open in
    // development, so `networkidle` never settles.
    const response = await page.goto(`${baseUrl}/`, { waitUntil: "domcontentloaded" });
    assert.equal(response?.status(), 200, "scaffolded server must return the document");
    assert.match(await page.locator(".brand").textContent(), /consumer-islands/);
    assert.equal(await page.locator(".foot code").textContent(), "src/views/App.luax");

    // The counter is a JS island: server-rendered, then hydrated.
    const counter = page.getByTestId("js-counter");
    await counter.waitFor();
    assert.equal(await counter.locator("output").textContent(), "3");
    await page.getByRole("button", { name: "More" }).click();
    await page.waitForFunction(() => document.querySelector('[data-testid="js-counter"] output')?.textContent === "4");
    assert.equal(await page.locator('input[name="times"]').inputValue(), "4", "the island keeps the form field in step");

    // A plain HTML post: the server answers with the page and the greeting.
    await page.fill("#name", "Ada");
    await Promise.all([page.waitForURL("**/hello"), page.getByRole("button", { name: "Say hello" }).click()]);
    assert.equal(await page.locator(".result").textContent(), "Hello, Ada! Hello, Ada! Hello, Ada! Hello, Ada!");
    assert.equal(await page.locator("#name").inputValue(), "Ada", "the posted name is kept");

    await Promise.all([page.waitForURL("**/about"), page.getByRole("link", { name: "About" }).click()]);
    assert.equal(await page.locator('nav a[aria-current="page"]').textContent(), "About");

    assert.deepEqual(pageErrors, [], "no uncaught page errors");
    assert.deepEqual(consoleErrors, [], "no browser console errors");
    assert.deepEqual(requestFailures, [], "no failed asset or module requests");
  } finally {
    await browser.close();
  }
});
