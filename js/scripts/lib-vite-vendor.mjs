// Shared generation logic for sync-vite-vendor.mjs and
// check-vite-vendor-drift.mjs -- ONE implementation of "turn
// js/packages/vite/dist/ + its package.json into the Lua source
// create/src/create/vite_vendor.lua embeds", so the two scripts cannot
// drift from each other the way a hand-duplicated copy could. See
// sync-vite-vendor.mjs's own header for the full "why vendor at all"
// reasoning.

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/** Picks a Lua long-bracket level that cannot collide with `content`. */
function longBracketLevel(content) {
  let level = 0;
  const re = /]=*]/g;
  let m;
  while ((m = re.exec(content))) {
    const eqCount = m[0].length - 2;
    if (eqCount >= level) level = eqCount + 1;
  }
  return level;
}

function luaLongString(content) {
  const level = longBracketLevel(content);
  const eq = "=".repeat(level);
  // A long bracket that opens right before a newline eats that first
  // newline -- prefix one blank newline so byte-for-byte content survives
  // even when it starts with one (matches Lua's own documented rule).
  return `[${eq}[\n${content}]${eq}]`;
}

/**
 * @param {string} viteDist absolute path to js/packages/vite/dist
 * @param {string} vitePkgJsonPath absolute path to js/packages/vite/package.json
 * @returns {string} the full generated create/src/create/vite_vendor.lua source
 */
export function generateViteVendorLua(viteDist, vitePkgJsonPath) {
  if (!existsSync(viteDist)) {
    throw new Error(`${viteDist} does not exist -- run \`pnpm build\` in js/packages/vite first.`);
  }

  const distFiles = readdirSync(viteDist).sort();
  const fullPkg = JSON.parse(readFileSync(vitePkgJsonPath, "utf8"));

  // Trimmed package.json: only what a CONSUMER needs to resolve/import the
  // vendored package -- not devDependencies, scripts, or publishConfig,
  // which describe how THIS monorepo builds/publishes it.
  const vendoredPkg = {
    name: fullPkg.name,
    version: fullPkg.version,
    type: fullPkg.type,
    main: fullPkg.main,
    types: fullPkg.types,
    exports: fullPkg.exports,
    peerDependencies: fullPkg.peerDependencies,
  };
  const vendoredPkgJson = JSON.stringify(vendoredPkg, null, 2) + "\n";

  const entries = [];
  for (const name of distFiles) {
    entries.push([`dist/${name}`, readFileSync(join(viteDist, name), "utf8")]);
  }
  entries.push(["package.json", vendoredPkgJson]);

  const lines = [];
  lines.push("-- GENERATED FILE. Do not edit by hand.");
  lines.push("-- Regenerate with: node js/scripts/sync-vite-vendor.mjs (after `pnpm build` in js/packages/vite)");
  lines.push("-- Checked for drift by: node js/scripts/check-vite-vendor-drift.mjs");
  lines.push("--");
  lines.push(`-- Vendored from @hydronium-js/vite@${fullPkg.version} (js/packages/vite/dist/ + a trimmed`);
  lines.push("-- package.json). See this file's generator (js/scripts/sync-vite-vendor.mjs) for why");
  lines.push("-- create/ vendors the built package instead of depending on it from npm.");
  lines.push("");
  lines.push("return {");
  for (const [relPath, content] of entries) {
    lines.push(`  [${JSON.stringify(relPath)}] = ${luaLongString(content)},`);
  }
  lines.push("}");

  return lines.join("\n") + "\n";
}
