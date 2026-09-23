#!/usr/bin/env node
// Fails (non-zero exit) if dom/src/hydronium_dom/client/ has diverged from
// its canonical source in packages/dom-client/src/ (+ the npm-derived
// wasmoon files). This is the M0 gate's drift check: "the drift check
// fails when a file is deliberately edited on one side only."
//
// Does NOT run sync -- it only compares what's already on disk, so it
// also catches "someone forgot to run sync after editing the source."
//
// Run with: node js/scripts/check-dom-client-drift.mjs

import { existsSync, readFileSync } from "node:fs";
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

const DOM_CLIENT_SRC = join(JS_ROOT, "packages/dom-client/src");
const DOM_SERVED_CLIENT = join(REPO_ROOT, "dom/src/hydronium_dom/client");

const filesToCheck = [...RUNTIME_FILES, WASMOON_WRAPPER_FILE, ...WASMOON_NPM_FILES.map((f) => f.to)];

const mismatches = [];

for (const rel of filesToCheck) {
  const srcPath = join(DOM_CLIENT_SRC, rel);
  const servedPath = join(DOM_SERVED_CLIENT, rel);

  const srcExists = existsSync(srcPath);
  const servedExists = existsSync(servedPath);

  if (!srcExists && !servedExists) {
    mismatches.push(`${rel}: missing on BOTH sides`);
    continue;
  }
  if (!srcExists) {
    mismatches.push(`${rel}: missing from canonical source (${srcPath})`);
    continue;
  }
  if (!servedExists) {
    mismatches.push(`${rel}: missing from dom/'s served copy (${servedPath}) -- run sync-dom-client.mjs`);
    continue;
  }

  const srcBuf = readFileSync(srcPath);
  const servedBuf = readFileSync(servedPath);
  if (!srcBuf.equals(servedBuf)) {
    mismatches.push(`${rel}: content differs between ${srcPath} and ${servedPath} -- run sync-dom-client.mjs`);
  }
}

if (mismatches.length > 0) {
  console.error(`check-dom-client-drift: ${mismatches.length} file(s) drifted:\n`);
  for (const m of mismatches) console.error(`  - ${m}`);
  console.error("\nRun `node js/scripts/sync-dom-client.mjs` and commit the result.");
  process.exit(1);
}

console.log(`check-dom-client-drift: ${filesToCheck.length} files checked, no drift.`);
