import { readFileSync } from "node:fs";

// Vite production manifest ingestion -- STUB (M0 skeleton, real work is M3).
//
// M3 implements: read Vite's `dist/.vite/manifest.json` (the file M1's gate
// proves `vite build` actually emits, via `build.manifest: true`) and
// re-emit each entry as a plain `hy_asset` matching exactly the shape
// `build/src/hydronium_ballad/plugins/assets.lua` already produces
// (`kind = "hy_asset"`, `metadata.hydronium = { source, url, integrity }`).
// That belongs in a new Lua plugin (`vite_assets.lua`), not here -- this
// module is only the JS-side read of the manifest shape, for whichever
// side ends up calling it (open question in the plan; M3 decides).
//
// Hazard #1 applies transitively: nothing that imports this module may be
// reachable from the root partiture.lua, since CI has no node/npm step.

export interface ViteManifestEntry {
  file: string;
  src?: string;
  isEntry?: boolean;
  css?: string[];
  assets?: string[];
  imports?: string[];
}

export type ViteManifest = Record<string, ViteManifestEntry>;

/**
 * Not implemented until M3. Throws rather than returning `{}`, so a caller
 * that expects real data fails loudly instead of silently doing nothing.
 */
export function readViteManifest(manifestPath: string): ViteManifest {
  const raw = readFileSync(manifestPath, "utf8");
  const parsed = JSON.parse(raw) as unknown;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(
      `@hydronium/vite: ${manifestPath} is not a Vite manifest object`
    );
  }
  return parsed as ViteManifest;
}

/**
 * The built, content-hashed URL for a source path, as the Lua side needs it.
 * Returns null when the manifest does not carry that source -- a caller must
 * decide whether that is a build misconfiguration or simply a dev-only module.
 */
export function manifestUrl(
  manifest: ViteManifest,
  source: string,
  base = "/"
): string | null {
  const entry = manifest[source];
  if (!entry || typeof entry.file !== "string") return null;
  return base.replace(/\/+$/, "") + "/" + entry.file.replace(/^\/+/, "");
}
