// M1 gate (docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md): "a Tailwind class used
// only inside a .luax file is present in the built CSS (proves @source
// works), while a class used nowhere is absent (proves the scan is still
// pruning)."
//
// Runs a real `vite build` (no mocking) and inspects the real dist/
// output. `bg-fuchsia-600` appears ONLY in ../fixtures/Widget.luax --
// nowhere in index.html or src/**/*.js -- and is only reachable to
// Tailwind's scanner because ../src/styles.css declares
// `@source "../fixtures/**/*.luax"` explicitly (styles.css also disables
// Tailwind's own automatic project-wide detection via
// `@import "tailwindcss" source(none);`, so there is no other way this
// class could end up in the build). `bg-emerald-900` is not written
// anywhere in this example's scanned sources on purpose, as the negative
// control.
//
// Run with: node --test js/examples/islands-tailwind/tests/tailwind-source.test.mjs
// (must run `pnpm install` in hydronium/js first so `vite` resolves).

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXAMPLE_ROOT = join(__dirname, "..");

test("vite build emits a real manifest with hashed JS + CSS, and Tailwind's @source picks up .luax but not unused classes", () => {
  rmSync(join(EXAMPLE_ROOT, "dist"), { recursive: true, force: true });

  execFileSync(join(EXAMPLE_ROOT, "node_modules/.bin/vite"), ["build"], {
    cwd: EXAMPLE_ROOT,
    stdio: "pipe",
  });

  const manifestPath = join(EXAMPLE_ROOT, "dist/.vite/manifest.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const entry = manifest["index.html"];
  assert.ok(entry, "manifest must have an index.html entry");
  assert.match(entry.file, /^assets\/index-.+\.js$/, "entry JS must be hashed");
  assert.ok(Array.isArray(entry.css) && entry.css.length === 1, "entry must reference exactly one CSS file");
  assert.match(entry.css[0], /^assets\/index-.+\.css$/, "entry CSS must be hashed");

  const cssFiles = readdirSync(join(EXAMPLE_ROOT, "dist/assets")).filter((f) => f.endsWith(".css"));
  assert.equal(cssFiles.length, 1);
  const css = readFileSync(join(EXAMPLE_ROOT, "dist/assets", cssFiles[0]), "utf8");

  assert.match(
    css,
    /\.bg-fuchsia-600\{/,
    "class used only inside fixtures/Widget.luax must be present -- proves @source scans .luax"
  );
  assert.doesNotMatch(
    css,
    /bg-emerald-900/,
    "class used nowhere in this example's scanned sources must be absent -- proves the scan still prunes"
  );
});
