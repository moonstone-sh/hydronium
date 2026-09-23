// The @hydronium-js/vite plugin.
//
// Everything here exists because a Hydronium page is served by Meteorite and
// only *references* Vite's output -- Vite never serves the HTML. That single
// fact is what the four behaviours below follow from.

import { existsSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { dirname, resolve as resolvePath } from "node:path";
import { resolveDevOrigin, devCorsConfig } from "./dev-origin.js";

export interface HydroniumPluginOptions {
  /**
   * Island entry modules, relative to the Vite root.
   *
   * REQUIRED for production or your islands will not be built at all. A JS
   * island is fetched at runtime by dom/src/hydronium_dom/client/bootstrap.js
   * from a URL in the page's client plan -- no module in Vite's own graph
   * imports it, so Rollup has no reason to emit it. Declaring islands here
   * adds them as real build inputs.
   */
  islands?: string[];
  /**
   * Where to publish the resolved dev origin so the Lua server can read it
   * instead of hardcoding a port. Relative to the Vite root. `false` disables.
   * Default: ".hydronium/vite-dev.json".
   */
  devOriginFile?: string | false;
  /** Host advertised to the browser. Default "localhost". */
  host?: string;
  /** Protocol advertised to the browser. Default "http". */
  protocol?: "http" | "https";
}

const DEFAULT_ORIGIN_FILE = ".hydronium/vite-dev.json";

/** Normalizes Rollup's several accepted `input` shapes into one record. */
function inputAsRecord(input: unknown): Record<string, string> {
  if (input == null) return {};
  if (typeof input === "string") return { [input]: input };
  if (Array.isArray(input)) {
    const out: Record<string, string> = {};
    for (const entry of input) if (typeof entry === "string") out[entry] = entry;
    return out;
  }
  if (typeof input === "object") return { ...(input as Record<string, string>) };
  return {};
}

export function hydronium(options: HydroniumPluginOptions = {}): any {
  const islands = options.islands ?? [];
  let root = process.cwd();
  let originFileAbs: string | null = null;

  return {
    name: "hydronium",

    config(userConfig: any) {
      const existing = inputAsRecord(userConfig?.build?.rollupOptions?.input);
      const merged: Record<string, string> = { ...existing };

      // Vite's implicit default input is <root>/index.html. Setting `input`
      // at all replaces that default, so re-add it or declaring one island
      // would silently stop the page itself from being built.
      if (Object.keys(existing).length === 0) {
        const indexHtml = resolvePath(userConfig?.root ?? process.cwd(), "index.html");
        if (existsSync(indexHtml)) merged.index = "index.html";
      }
      for (const island of islands) merged[island] = island;

      return {
        build: {
          // hydronium_ballad.plugins.vite_assets ingests dist/.vite/manifest.json
          // and re-emits each entry as an hy_asset for site.lua's merge.
          manifest: true,
          ...(Object.keys(merged).length > 0
            ? {
                rollupOptions: {
                  input: merged,
                  // Without this an island builds to an EMPTY file. Vite's app
                  // mode sets preserveEntrySignatures: false, so Rollup is free
                  // to tree-shake an entry's exports when nothing in the graph
                  // imports them -- and nothing does import an island, which is
                  // the whole reason it needs declaring. The chunk is still
                  // emitted and still appears in the manifest, so the failure
                  // surfaces only in production, as an island whose `hydrate`
                  // is undefined.
                  preserveEntrySignatures: "exports-only" as const,
                },
              }
            : {}),
        },
        server: {
          // The page lives on Meteorite's origin and imports from Vite's, so
          // every module request is cross-origin. Meteorite cannot serve
          // websockets, which is why Vite keeps its own origin at all.
          cors: devCorsConfig(),
        },
      };
    },

    configResolved(resolved: any) {
      root = resolved.root ?? root;
    },

    configureServer(server: any) {
      if (options.devOriginFile === false) return;
      const rel = options.devOriginFile ?? DEFAULT_ORIGIN_FILE;

      const publish = () => {
        const address = server.httpServer?.address?.();
        const port =
          address && typeof address === "object" ? address.port : undefined;
        if (typeof port !== "number") return;

        const origin = resolveDevOrigin({
          host: options.host,
          port,
          protocol: options.protocol,
        });
        originFileAbs = resolvePath(root, rel);
        mkdirSync(dirname(originFileAbs), { recursive: true });
        // The Lua server reads this to configure vite_module, so the port
        // lives in exactly one place -- whatever Vite actually bound.
        writeFileSync(
          originFileAbs,
          JSON.stringify({ origin, port, mode: "dev" }, null, 2) + "\n"
        );
      };

      server.httpServer?.once("listening", publish);

      const cleanup = () => {
        if (!originFileAbs) return;
        // A stale file would point the Lua server at a dead port and the
        // failure would look like a broken island, not a stopped dev server.
        try {
          rmSync(originFileAbs, { force: true });
        } catch {
          /* best effort -- never fail shutdown over this */
        }
        originFileAbs = null;
      };
      server.httpServer?.once("close", cleanup);
      process.once("exit", cleanup);
    },
  };
}

export default hydronium;
