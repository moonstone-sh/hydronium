// The browser half of the React island gate (tests/e2e/consumer_scaffold.sh
// with HYDRONIUM_CONSUMER_PREPARE=tests/e2e/react_island_prepare.sh): a
// Hydronium SSR page whose island is a React component built by the user's
// own Vite + @vitejs/plugin-react. Proves React hydrates the server markup
// (no mismatch, no console errors) and owns the interaction afterwards.
import test from "node:test";
import assert from "node:assert/strict";
import { chromium } from "playwright";

const baseUrl = process.env.HYDRONIUM_CONSUMER_URL;

test("a React component hydrates as a Hydronium island", { skip: !baseUrl }, async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  page.on("console", (message) => { if (message.type() === "error") consoleErrors.push(message.text()); });
  page.on("pageerror", (error) => pageErrors.push(String(error)));
  try {
    const response = await page.goto(`${baseUrl}/`, { waitUntil: "domcontentloaded" });
    assert.equal(response?.status(), 200, "server must return the document");

    const counter = page.getByTestId("js-counter-btn");
    await counter.waitFor();
    assert.equal(await counter.textContent(), "Count: 10", "SSR renders the island's initial state");

    // Set in a React effect: only a real hydrateRoot commit can produce it.
    await page.waitForFunction(() => document.documentElement.dataset.reactIsland, null, { timeout: 15000 });
    const reactVersion = await page.evaluate(() => document.documentElement.dataset.reactIsland);
    assert.match(reactVersion, /^19\./, "the island is React 19");

    await counter.click();
    await page.waitForFunction(() => document.querySelector('[data-testid="js-counter-btn"]')?.textContent === "Count: 11");
    await counter.click();
    await page.waitForFunction(() => document.querySelector('[data-testid="js-counter-btn"]')?.textContent === "Count: 12");
    assert.equal(await page.locator('[data-testid="js-counter-btn"]').count(), 1, "React hydrated in place (no duplicate button)");

    // React reports hydration mismatches through console.error.
    assert.deepEqual(consoleErrors, [], "no console errors (incl. hydration mismatches)");
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser.close();
  }
});
