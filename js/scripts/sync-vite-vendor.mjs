#!/usr/bin/env node
// Regenerates create/src/create/vite_vendor.lua from the built
// @hydronium-js/vite package (js/packages/vite/dist/ + its package.json),
// per STEP 2 of docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md.
//
// WHY THIS EXISTS. @hydronium-js/vite is not published to npm yet (its
// own package.json's `publishConfig` says "when it is", not "it is").
// hydronium-create (`create/`) is a Lua moonstone package: a real
// end-user's materialized copy of it has no sibling `js/` directory at
// all (moonstone packages export exactly `src/**` from their own
// directory -- see the root partiture.lua's `package_orbit` helper), so
// a generated project cannot reach back into this monorepo's checkout
// for the adapter package the way create/vite.lua's OWN header already
// documents this codebase avoiding for the Lua side ("a generated
// project resolves its Hydronium modules through Moonstone
// dependencies", not a source symlink).
//
// THE CHOSEN INTERIM (documented in docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md
// STEP 2, decided 2026-09-25): vendor the BUILT package -- dist/*.js,
// dist/*.d.ts, dist/supervisor.mjs, and a trimmed package.json -- as real
// content INSIDE create's own moonstone package
// (create/src/create/vite_vendor.lua, which every consumer -- registry
// install or local checkout -- actually gets, since it's under `src/**`).
// create/src/create/vite.lua writes those bytes into a scaffolded
// project's own vendor/hydronium-js-vite/ directory, and its package.json
// references `"@hydronium-js/vite": "file:./vendor/hydronium-js-vite"` --
// a real, resolvable npm local-directory dependency, no symlink outside
// the project, no reliance on a sibling hydronium checkout existing.
// Exactly the same "vendor byte-for-byte, add a drift check" method M0
// already established for dom/'s served client-JS copy
// (js/scripts/sync-dom-client.mjs) -- just emitting Lua string literals
// instead of copying a real directory tree, because create's scaffolded
// files come from an in-memory `files[path] = content` table, not disk.
//
// ONCE @hydronium-js/vite IS PUBLISHED: replace the `file:` dependency
// with a real semver range and delete this vendoring; the provider
// CONTRACT (hydronium_dom.assets) does not change either way.
//
// Run with: node js/scripts/sync-vite-vendor.mjs (after `pnpm build` in
// js/packages/vite -- this script does not build, only vendors what's
// already in dist/).

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { generateViteVendorLua } from "./lib-vite-vendor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const JS_ROOT = join(__dirname, "..");
const REPO_ROOT = join(JS_ROOT, "..");

const VITE_DIST = join(JS_ROOT, "packages/vite/dist");
const VITE_PKG_JSON = join(JS_ROOT, "packages/vite/package.json");
const OUT_FILE = join(REPO_ROOT, "create/src/create/vite_vendor.lua");

const content = generateViteVendorLua(VITE_DIST, VITE_PKG_JSON);
writeFileSync(OUT_FILE, content);
console.log(`sync-vite-vendor: wrote ${OUT_FILE} (${content.length} bytes)`);
