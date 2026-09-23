// M1 gate (docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md): "a Playwright run
// proves `vite dev` HMR patches an edited island without a full page
// reload (assert a `window.__bootId` set once at boot is unchanged -- the
// assertion that distinguishes HMR from live reload)."
//
// Real `vite dev` process (spawned as a child), real Chromium (via
// playwright), real file edit on disk, real HMR round trip over Vite's
// own websocket -- nothing here is mocked. See ../src/main.js for where
// `window.__bootId` is set (once, at initial module evaluation) and where
// `import.meta.hot.accept("./counter-island.js", ...)` lives (the HMR
// boundary that makes this a patch instead of a reload).
//
// Run with: node --test js/examples/islands-tailwind/tests/hmr.test.mjs
// (must run `pnpm install` + `pnpm exec playwright install chromium` in
// hydronium/js first).

import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXAMPLE_ROOT = join(__dirname, "..");
const ISLAND_FILE = join(EXAMPLE_ROOT, "src/counter-island.js");
const PORT = 5199;
const URL = `http://localhost:${PORT}/`;

function waitForServer(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      fetch(url)
        .then((res) => {
          if (res.ok) resolve();
          else retryOrFail();
        })
        .catch(retryOrFail);
    };
    const retryOrFail = () => {
      if (Date.now() > deadline) reject(new Error(`vite dev server did not come up at ${url} in time`));
      else setTimeout(attempt, 150);
    };
    attempt();
  });
}

test("vite dev HMR-patches an edited island without a full page reload", async (t) => {
  const originalIslandSource = readFileSync(ISLAND_FILE, "utf8");
  assert.match(originalIslandSource, /Count: \$\{count\}/, "fixture assumption: island renders 'Count: N'");

  const viteBin = join(EXAMPLE_ROOT, "node_modules/.bin/vite");
  const devServer = spawn(viteBin, ["--port", String(PORT), "--strictPort"], {
    cwd: EXAMPLE_ROOT,
    stdio: "pipe",
  });

  let devServerOutput = "";
  devServer.stdout.on("data", (d) => (devServerOutput += d));
  devServer.stderr.on("data", (d) => (devServerOutput += d));

  let browser;
  t.after(async () => {
    // Always restore the island file, even if an assertion throws.
    writeFileSync(ISLAND_FILE, originalIslandSource);
    if (browser) await browser.close();
    devServer.kill();
  });

  await waitForServer(URL, 20_000);

  browser = await chromium.launch();
  const page = await browser.newPage();

  const consoleErrors = [];
  page.on("pageerror", (err) => consoleErrors.push(String(err)));

  await page.goto(URL, { waitUntil: "networkidle" });

  const initialText = await page.textContent("#app-root");
  assert.equal(initialText, "Count: 0");

  const bootIdBefore = await page.evaluate(() => window.__bootId);
  assert.equal(typeof bootIdBefore, "string");
  assert.ok(bootIdBefore.length > 0);

  // Edit the island's source on disk: change the visible label. If Vite's
  // HMR boundary in main.js works, only counter-island.js's module gets
  // re-evaluated and re-hydrated -- main.js's top-level `window.__bootId`
  // assignment does NOT re-run. If Vite instead falls back to a full page
  // reload (e.g. because the HMR boundary were missing or broken), the
  // whole page -- including main.js -- re-executes and __bootId changes.
  const editedSource = originalIslandSource.replace(/Count: \$\{count\}/g, "Clicks: ${count}");
  assert.notEqual(editedSource, originalIslandSource, "the replace must actually have matched something");
  writeFileSync(ISLAND_FILE, editedSource);

  await page.waitForFunction(
    () => document.querySelector("#app-root")?.textContent === "Clicks: 0",
    null,
    { timeout: 10_000 }
  );

  const bootIdAfter = await page.evaluate(() => window.__bootId);

  assert.equal(
    bootIdAfter,
    bootIdBefore,
    `window.__bootId changed (${bootIdBefore} -> ${bootIdAfter}) -- this means the page did a full reload, ` +
      `not an HMR patch. vite dev output:\n${devServerOutput}`
  );

  // The click handler should also still work after the HMR-hydrated
  // re-mount, proving the island is fully alive, not just visually
  // updated.
  await page.click("#app-root");
  await page.waitForFunction(() => document.querySelector("#app-root")?.textContent === "Clicks: 1");

  assert.deepEqual(consoleErrors, [], "no uncaught page errors during the HMR round trip");
});
