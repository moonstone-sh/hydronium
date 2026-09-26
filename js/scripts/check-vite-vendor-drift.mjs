#!/usr/bin/env node
// Fails (non-zero exit) if create/src/create/vite_vendor.lua has drifted
// from a fresh `pnpm build` of js/packages/vite -- the M0-style drift
// check for STEP 2's vendoring decision (see sync-vite-vendor.mjs's own
// header for the full "why vendor at all" reasoning).
//
// Read-only: computes what the generator WOULD write and diffs it against
// the committed file, without touching it -- so this is safe to run in CI
// and also catches "someone forgot to run sync-vite-vendor.mjs after
// editing js/packages/vite".
//
// Run with: node js/scripts/check-vite-vendor-drift.mjs (after `pnpm
// build` in js/packages/vite, exactly like the sync script).

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { generateViteVendorLua } from "./lib-vite-vendor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const JS_ROOT = join(__dirname, "..");
const REPO_ROOT = join(JS_ROOT, "..");

const VITE_DIST = join(JS_ROOT, "packages/vite/dist");
const VITE_PKG_JSON = join(JS_ROOT, "packages/vite/package.json");
const VENDOR_FILE = join(REPO_ROOT, "create/src/create/vite_vendor.lua");

if (!existsSync(VENDOR_FILE)) {
  console.error(`check-vite-vendor-drift: ${VENDOR_FILE} does not exist -- run \`node js/scripts/sync-vite-vendor.mjs\`.`);
  process.exit(1);
}

const expected = generateViteVendorLua(VITE_DIST, VITE_PKG_JSON);
const actual = readFileSync(VENDOR_FILE, "utf8");

if (expected !== actual) {
  console.error(
    "check-vite-vendor-drift: create/src/create/vite_vendor.lua does not match a fresh build of " +
      "js/packages/vite -- run `node js/scripts/sync-vite-vendor.mjs` and commit the result."
  );
  process.exit(1);
}

console.log("check-vite-vendor-drift: create/src/create/vite_vendor.lua matches js/packages/vite/dist/, no drift.");
