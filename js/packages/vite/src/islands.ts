// Island module resolution -- STUB (M0 skeleton, real work is M2).
//
// M2 implements: given a `hy_asset_ref` (asset_id + specifier) recorded by
// dom/src/hydronium_dom/server/init.lua for an island's `raw_props.module`,
// resolve it to a real URL -- dev: the Vite dev-server origin
// (see dev-origin.ts), prod: the hashed path out of Vite's
// dist/.vite/manifest.json (see manifest.ts). Do not invent a parallel
// mechanism to `hy_asset_ref`; it is already specified in
// docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md:217,250.

/**
 * Placeholder shape for the `hy_asset_ref` Lua emits. Intentionally not
 * used anywhere yet -- typed here so M2 has a starting contract to refine
 * against the real Lua-side shape rather than inventing one blind.
 */
export interface HyAssetRef {
  asset_id: string;
  specifier: string;
}

/**
 * Not implemented until M2. Throws rather than silently returning a
 * plausible-looking URL, so an accidental early caller fails loudly.
 */

import { manifestUrl, type ViteManifest } from "./manifest.js";

/**
 * Resolves an island's module specifier to the URL the browser should import.
 *
 * Mirrors dom/src/hydronium_dom/server/vite_module.lua, which is the
 * authority at SSR time -- this exists for JS-side tooling and tests that
 * need the same answer without a Lua round trip. Dev points at Vite's own
 * origin (the page is on Meteorite's, so it must be absolute); prod resolves
 * through the build manifest to the content-hashed file.
 */
export function resolveIslandModule(
  specifier: string,
  options:
    | { mode: "dev"; origin: string }
    | { mode: "prod"; manifest: ViteManifest; base?: string }
): string {
  if (!specifier) throw new Error("@hydronium/vite: island specifier is required");
  if (options.mode === "dev") {
    if (!options.origin) {
      throw new Error("@hydronium/vite: dev island resolution requires an `origin`");
    }
    return (
      options.origin.replace(/\/+$/, "") + "/" + specifier.replace(/^\.?\/+/, "")
    );
  }
  const url = manifestUrl(options.manifest, specifier, options.base ?? "/");
  if (!url) {
    throw new Error(
      `@hydronium/vite: island "${specifier}" is not in the build manifest -- ` +
        "declare it in the plugin's `islands` option so Vite builds it"
    );
  }
  return url;
}
