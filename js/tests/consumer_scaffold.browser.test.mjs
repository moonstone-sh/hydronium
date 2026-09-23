// The browser half of tests/e2e/consumer_scaffold.sh.  The shell harness owns
// packaging, registry materialization, and the service lifetime; this test
// makes the failure signals a blank page otherwise hides explicit.
import test from "node:test";
import assert from "node:assert/strict";
import { chromium } from "playwright";

const baseUrl = process.env.HYDRONIUM_CONSUMER_URL;

test("published islands scaffold renders and hydrates without browser failures", { skip: !baseUrl }, async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  const requestFailures = [];

  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => pageErrors.push(String(error)));
  page.on("requestfailed", (request) => requestFailures.push(`${request.url()}: ${request.failure()?.errorText}`));

  try {
    // The scaffold intentionally opens a long-lived SSE watch connection for
    // development reloads.  `networkidle` therefore never becomes true even
    // when the production document, assets, and island are healthy.
    const response = await page.goto(`${baseUrl}/`, { waitUntil: "domcontentloaded" });
    assert.equal(response?.status(), 200, "scaffolded server must return the document");
    await assert.doesNotReject(page.getByRole("heading", { name: "consumer-islands" }).waitFor());

    const counter = page.getByTestId("js-counter-btn");
    await assert.doesNotReject(counter.waitFor(), "SSR must contain the island root");
    await assert.doesNotReject(async () => assert.equal(await counter.textContent(), "Count: 10"));
    await counter.click();
    await assert.doesNotReject(async () => assert.equal(await counter.textContent(), "Count: 11"));

    assert.deepEqual(pageErrors, [], "no uncaught page errors");
    assert.deepEqual(consoleErrors, [], "no browser console errors");
    assert.deepEqual(requestFailures, [], "no failed asset or module requests");
  } finally {
    await browser.close();
  }
});
