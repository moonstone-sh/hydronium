#!/usr/bin/env node
// Regenerates dom/'s served copy of the client runtime from the canonical
// source in packages/dom-client/src/, per M0 of
// docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md ("dom/ must keep serving the
// same files at the same paths ... use a generated sync copy plus a drift
// check").
//
// Two things happen here, in order:
//
//  1. The npm-managed wasmoon dist files (index.js, glue.wasm, LICENSE) are
//     copied from node_modules/wasmoon into
//     packages/dom-client/src/vendor/wasmoon/, sitting alongside the
//     hand-authored wasmoon.esm.js wrapper that imports them as siblings.
//     This is the "replace the vendored copy with a real wasmoon
//     dependency" step -- the files are now npm-provenanced (hashed in
//     the lockfile) rather than hand-pasted, even though bytes still end
//     up on disk next to the wrapper (the wrapper needs real sibling
//     files to import, whether or not a bundler is in the picture -- see
//     dom-client's package description).
//
//  2. packages/dom-client/src/ (the 9 runtime files + the vendor/wasmoon/
//     directory, now fully populated) is copied verbatim into
//     dom/src/hydronium_dom/client/, which is what Meteorite's
//     `meteorite.dir(...)` calls in examples/*/src/main.lua and
//     create/src/create/templates/*.lua actually serve. Those call sites
//     are NOT changed by this plan -- they keep pointing at
//     dom/src/hydronium_dom/client, and this script is what keeps that
//     path's contents equal to the new canonical source.
//
// Run with: node js/scripts/sync-dom-client.mjs (from anywhere; paths are
// resolved relative to this file, not cwd).

import { existsSync, mkdirSync, copyFileSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  RUNTIME_FILES,
  WASMOON_WRAPPER_FILE,
  WASMOON_NPM_FILES,
} from "./lib-dom-client-files.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const JS_ROOT = join(__dirname, "..");
const REPO_ROOT = join(JS_ROOT, "..");

const DOM_CLIENT_PKG = join(JS_ROOT, "packages/dom-client");
const DOM_CLIENT_SRC = join(DOM_CLIENT_PKG, "src");
// pnpm installs each workspace package's own dependencies into that
// package's own node_modules (not hoisted to the workspace root unless
// the root itself depends on it), so resolve wasmoon there.
const WASMOON_NODE_MODULES = join(DOM_CLIENT_PKG, "node_modules/wasmoon");
const DOM_SERVED_CLIENT = join(REPO_ROOT, "dom/src/hydronium_dom/client");

function ensureDir(path) {
  mkdirSync(dirname(path), { recursive: true });
}

function copy(from, to, label) {
  if (!existsSync(from)) {
    throw new Error(`sync-dom-client: missing source file for ${label}: ${from}`);
  }
  ensureDir(to);
  copyFileSync(from, to);
  // npm-derived files (notably wasmoon's dist/glue.wasm, seen in the
  // wild coming out of the npm cache as 0755) should not flip file mode
  // vs. what was previously hand-vendored (0644) -- normalize so `git
  // diff` only ever shows real content changes.
  chmodSync(to, 0o644);
}

// Step 1: populate packages/dom-client/src/vendor/wasmoon/ from the real
// npm dependency.
if (!existsSync(WASMOON_NODE_MODULES)) {
  throw new Error(
    "sync-dom-client: packages/dom-client/node_modules/wasmoon not found -- run " +
      "`pnpm install` in hydronium/js first (wasmoon is a real dependency of " +
      "@hydronium/dom-client now, not a hand-vendored file)."
  );
}
for (const { from, to } of WASMOON_NPM_FILES) {
  copy(join(WASMOON_NODE_MODULES, from), join(DOM_CLIENT_SRC, to), `wasmoon npm file ${from}`);
}

// Step 2: copy the full canonical src/ tree into dom/'s served copy.
const filesToSync = [...RUNTIME_FILES, WASMOON_WRAPPER_FILE, ...WASMOON_NPM_FILES.map((f) => f.to)];

let copied = 0;
for (const rel of filesToSync) {
  const from = join(DOM_CLIENT_SRC, rel);
  const to = join(DOM_SERVED_CLIENT, rel);
  copy(from, to, rel);
  copied += 1;
}

console.log(`sync-dom-client: synced ${copied} files into ${DOM_SERVED_CLIENT}`);
