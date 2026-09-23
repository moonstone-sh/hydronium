// @hydronium/vite -- public entry point.
//
// The plugin body is real; see plugin.ts.
// in this file is wired into a real Vite config yet -- examples/islands-tailwind
// (M1) proves Vite 8 + Tailwind v4 work standalone, without this package.
// The real plugin body (hy_asset_ref resolution, dev-origin rewriting,
// dual-dev-server supervisor) is M2; the production manifest emission that
// feeds hydronium_ballad's site.lua merge is M3.
//
// Deliberately re-exported from separate modules (islands.ts, manifest.ts,
// dev-origin.ts) rather than one file, matching the layout in the plan's
// §3 so each concern gets its own gate-driven test file later.

export { hydronium, hydronium as default, type HydroniumPluginOptions } from "./plugin.js";
export { resolveIslandModule } from "./islands.js";
export { readViteManifest, manifestUrl, type ViteManifest } from "./manifest.js";
export { resolveDevOrigin, devCorsConfig } from "./dev-origin.js";
// supervisor.mjs is plain JS, not TS: it is meant to be run directly with
// `node` (no build step exists for this package yet -- see this
// package's own package.json description), not just type-checked. See
// its own header for why.
export { runDualDevServer } from "./supervisor.mjs";
