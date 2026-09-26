-- GENERATED FILE. Do not edit by hand.
-- Regenerate with: node js/scripts/sync-vite-vendor.mjs (after `pnpm build` in js/packages/vite)
-- Checked for drift by: node js/scripts/check-vite-vendor-drift.mjs
--
-- Vendored from @hydronium-js/vite@0.1.0 (js/packages/vite/dist/ + a trimmed
-- package.json). See this file's generator (js/scripts/sync-vite-vendor.mjs) for why
-- create/ vendors the built package instead of depending on it from npm.

return {
  ["dist/dev-origin.d.ts"] = [[
export interface DevOriginConfig {
    host?: string;
    port: number;
    /** Defaults to "http" -- set "https" for a TLS-terminated dev proxy. */
    protocol?: "http" | "https";
}
/**
 * Composes the origin URL string Vite's dev server is reachable at, in the
 * exact shape `hydronium_dom.server.vite_module.configure({ mode = "dev",
 * vite_origin = ... })` expects: no trailing slash, a real protocol, no
 * path. This is the single source of truth an app's dev supervisor (or
 * its own main.lua) should use rather than hand-assembling the string,
 * so a host/port/protocol change can't drift between the JS and Lua
 * sides of one dev session.
 */
export declare function resolveDevOrigin(config: DevOriginConfig): string;
/**
 * The `server.cors` value a Vite config should pass for dual-dev-server
 * mode: SSR HTML served from Meteorite's origin references modules and
 * assets hosted on Vite's origin, so a browser treats every such request
 * as cross-origin and Vite must say yes explicitly. `true` (Vite's own
 * "reflect the request's Origin" mode) rather than a literal origin
 * string: the SSR origin is a dev-time value the app owns (Meteorite's
 * configured host/port), not something this package should hardcode or
 * require duplicating into vite.config.
 */
export declare function devCorsConfig(): true;
]],
  ["dist/dev-origin.js"] = [[
// Dev-origin / CORS config -- M2 of docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md.
//
// Meteorite cannot serve websockets (deliberately --
// meteorite/src/core/app.lua errors `unsupported_websocket`), so Vite's
// HMR socket must reach Vite's own origin directly rather than being
// proxied through Meteorite. That forces the §2.5 topology: two real
// processes, Meteorite serving SSR + API on its own port, Vite serving
// JS/CSS + its HMR socket on its own (default 5173) with
// `server.cors` enabled, and SSR HTML referencing Vite's origin directly
// in dev. This module is the small, real piece of that: the origin-URL
// string SSR needs to hand to `hydronium_dom.server.vite_module.configure`
// (Lua side), and the matching Vite `server.cors` config for the JS side.
// The Lua-side resolver itself lives in
// dom/src/hydronium_dom/server/vite_module.lua, not here -- this package
// has no business reaching into a Lua process's config.
/**
 * Composes the origin URL string Vite's dev server is reachable at, in the
 * exact shape `hydronium_dom.server.vite_module.configure({ mode = "dev",
 * vite_origin = ... })` expects: no trailing slash, a real protocol, no
 * path. This is the single source of truth an app's dev supervisor (or
 * its own main.lua) should use rather than hand-assembling the string,
 * so a host/port/protocol change can't drift between the JS and Lua
 * sides of one dev session.
 */
export function resolveDevOrigin(config) {
    if (!config || typeof config.port !== "number" || !Number.isFinite(config.port)) {
        throw new Error("@hydronium-js/vite: resolveDevOrigin requires a numeric `port`");
    }
    const protocol = config.protocol ?? "http";
    const host = config.host ?? "localhost";
    return `${protocol}://${host}:${config.port}`;
}
/**
 * The `server.cors` value a Vite config should pass for dual-dev-server
 * mode: SSR HTML served from Meteorite's origin references modules and
 * assets hosted on Vite's origin, so a browser treats every such request
 * as cross-origin and Vite must say yes explicitly. `true` (Vite's own
 * "reflect the request's Origin" mode) rather than a literal origin
 * string: the SSR origin is a dev-time value the app owns (Meteorite's
 * configured host/port), not something this package should hardcode or
 * require duplicating into vite.config.
 */
export function devCorsConfig() {
    return true;
}
]],
  ["dist/index.d.ts"] = [[
export { hydronium, hydronium as default, type HydroniumPluginOptions } from "./plugin.js";
export { resolveIslandModule } from "./islands.js";
export { readViteManifest, manifestUrl, type ViteManifest } from "./manifest.js";
export { resolveDevOrigin, devCorsConfig } from "./dev-origin.js";
export { runDualDevServer } from "./supervisor.mjs";
]],
  ["dist/index.js"] = [[
// @hydronium-js/vite -- public entry point.
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
export { hydronium, hydronium as default } from "./plugin.js";
export { resolveIslandModule } from "./islands.js";
export { readViteManifest, manifestUrl } from "./manifest.js";
export { resolveDevOrigin, devCorsConfig } from "./dev-origin.js";
// supervisor.mjs is plain JS, not TS: it is meant to be run directly with
// `node` (no build step exists for this package yet -- see this
// package's own package.json description), not just type-checked. See
// its own header for why.
export { runDualDevServer } from "./supervisor.mjs";
]],
  ["dist/islands.d.ts"] = [[
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
import { type ViteManifest } from "./manifest.js";
/**
 * Resolves an island's module specifier to the URL the browser should import.
 *
 * Mirrors dom/src/hydronium_dom/server/vite_module.lua, which is the
 * authority at SSR time -- this exists for JS-side tooling and tests that
 * need the same answer without a Lua round trip. Dev points at Vite's own
 * origin (the page is on Meteorite's, so it must be absolute); prod resolves
 * through the build manifest to the content-hashed file.
 */
export declare function resolveIslandModule(specifier: string, options: {
    mode: "dev";
    origin: string;
} | {
    mode: "prod";
    manifest: ViteManifest;
    base?: string;
}): string;
]],
  ["dist/islands.js"] = [[
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
 * Not implemented until M2. Throws rather than silently returning a
 * plausible-looking URL, so an accidental early caller fails loudly.
 */
import { manifestUrl } from "./manifest.js";
/**
 * Resolves an island's module specifier to the URL the browser should import.
 *
 * Mirrors dom/src/hydronium_dom/server/vite_module.lua, which is the
 * authority at SSR time -- this exists for JS-side tooling and tests that
 * need the same answer without a Lua round trip. Dev points at Vite's own
 * origin (the page is on Meteorite's, so it must be absolute); prod resolves
 * through the build manifest to the content-hashed file.
 */
export function resolveIslandModule(specifier, options) {
    if (!specifier)
        throw new Error("@hydronium-js/vite: island specifier is required");
    if (options.mode === "dev") {
        if (!options.origin) {
            throw new Error("@hydronium-js/vite: dev island resolution requires an `origin`");
        }
        return (options.origin.replace(/\/+$/, "") + "/" + specifier.replace(/^\.?\/+/, ""));
    }
    const url = manifestUrl(options.manifest, specifier, options.base ?? "/");
    if (!url) {
        throw new Error(`@hydronium-js/vite: island "${specifier}" is not in the build manifest -- ` +
            "declare it in the plugin's `islands` option so Vite builds it");
    }
    return url;
}
]],
  ["dist/manifest.d.ts"] = [[
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
export declare function readViteManifest(manifestPath: string): ViteManifest;
/**
 * The built, content-hashed URL for a source path, as the Lua side needs it.
 * Returns null when the manifest does not carry that source -- a caller must
 * decide whether that is a build misconfiguration or simply a dev-only module.
 */
export declare function manifestUrl(manifest: ViteManifest, source: string, base?: string): string | null;
]],
  ["dist/manifest.js"] = [[
import { readFileSync } from "node:fs";
/**
 * Not implemented until M3. Throws rather than returning `{}`, so a caller
 * that expects real data fails loudly instead of silently doing nothing.
 */
export function readViteManifest(manifestPath) {
    const raw = readFileSync(manifestPath, "utf8");
    const parsed = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        throw new Error(`@hydronium-js/vite: ${manifestPath} is not a Vite manifest object`);
    }
    return parsed;
}
/**
 * The built, content-hashed URL for a source path, as the Lua side needs it.
 * Returns null when the manifest does not carry that source -- a caller must
 * decide whether that is a build misconfiguration or simply a dev-only module.
 */
export function manifestUrl(manifest, source, base = "/") {
    const entry = manifest[source];
    if (!entry || typeof entry.file !== "string")
        return null;
    return base.replace(/\/+$/, "") + "/" + entry.file.replace(/^\/+/, "");
}
]],
  ["dist/plugin.d.ts"] = [[
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
export declare function hydronium(options?: HydroniumPluginOptions): any;
export default hydronium;
]],
  ["dist/plugin.js"] = [[
// The @hydronium-js/vite plugin.
//
// Everything here exists because a Hydronium page is served by Meteorite and
// only *references* Vite's output -- Vite never serves the HTML. That single
// fact is what the four behaviours below follow from.
import { existsSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { dirname, resolve as resolvePath } from "node:path";
import { resolveDevOrigin, devCorsConfig } from "./dev-origin.js";
const DEFAULT_ORIGIN_FILE = ".hydronium/vite-dev.json";
/** Normalizes Rollup's several accepted `input` shapes into one record. */
function inputAsRecord(input) {
    if (input == null)
        return {};
    if (typeof input === "string")
        return { [input]: input };
    if (Array.isArray(input)) {
        const out = {};
        for (const entry of input)
            if (typeof entry === "string")
                out[entry] = entry;
        return out;
    }
    if (typeof input === "object")
        return { ...input };
    return {};
}
export function hydronium(options = {}) {
    const islands = options.islands ?? [];
    let root = process.cwd();
    let originFileAbs = null;
    return {
        name: "hydronium",
        config(userConfig) {
            const existing = inputAsRecord(userConfig?.build?.rollupOptions?.input);
            const merged = { ...existing };
            // Vite's implicit default input is <root>/index.html. Setting `input`
            // at all replaces that default, so re-add it or declaring one island
            // would silently stop the page itself from being built.
            if (Object.keys(existing).length === 0) {
                const indexHtml = resolvePath(userConfig?.root ?? process.cwd(), "index.html");
                if (existsSync(indexHtml))
                    merged.index = "index.html";
            }
            for (const island of islands)
                merged[island] = island;
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
                                preserveEntrySignatures: "exports-only",
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
        configResolved(resolved) {
            root = resolved.root ?? root;
        },
        configureServer(server) {
            if (options.devOriginFile === false)
                return;
            const rel = options.devOriginFile ?? DEFAULT_ORIGIN_FILE;
            const publish = () => {
                const address = server.httpServer?.address?.();
                const port = address && typeof address === "object" ? address.port : undefined;
                if (typeof port !== "number")
                    return;
                const origin = resolveDevOrigin({
                    host: options.host,
                    port,
                    protocol: options.protocol,
                });
                originFileAbs = resolvePath(root, rel);
                mkdirSync(dirname(originFileAbs), { recursive: true });
                // The Lua server reads this to configure vite_module, so the port
                // lives in exactly one place -- whatever Vite actually bound.
                writeFileSync(originFileAbs, JSON.stringify({ origin, port, mode: "dev" }, null, 2) + "\n");
            };
            server.httpServer?.once("listening", publish);
            const cleanup = () => {
                if (!originFileAbs)
                    return;
                // A stale file would point the Lua server at a dead port and the
                // failure would look like a broken island, not a stopped dev server.
                try {
                    rmSync(originFileAbs, { force: true });
                }
                catch {
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
]],
  ["dist/supervisor.d.mts"] = [[
export type ProcessSpec = {
    /**
     * Short label used to prefix merged log lines.
     */
    name: string;
    command: string;
    args?: string[];
    cwd?: string;
    /**
     * Merged over `process.env`, not replacing it.
     */
    env?: NodeJS.ProcessEnv;
};
/**
 * @typedef {object} ProcessSpec
 * @property {string} name Short label used to prefix merged log lines.
 * @property {string} command
 * @property {string[]} [args]
 * @property {string} [cwd]
 * @property {NodeJS.ProcessEnv} [env] Merged over `process.env`, not replacing it.
 */
/**
 * @param {ProcessSpec[]} processes
 * @param {object} [options]
 * @param {(name: string, line: string) => void} [options.onLog] Called
 *   once per merged, newline-split output line (stdout and stderr both),
 *   prefixed by which process it came from. Defaults to a plain
 *   `[name] line` console.log -- pass your own to capture instead of
 *   printing (this is what the test suite does).
 * @param {string[]} [options.signals] Signals this process listens for
 *   and forwards to every child. Defaults to SIGINT and SIGTERM.
 * @param {boolean} [options.forwardProcessSignals] Set false to skip
 *   installing `process.on(signal, ...)` handlers entirely -- for tests,
 *   or for a caller that wants to drive `stop()` itself instead.
 * @returns {{
 *   children: import("node:child_process").ChildProcess[],
 *   stop: (signal?: string) => void,
 *   exited: Promise<{ name: string, code: number|null, signal: string|null }[]>,
 *   dispose: () => void,
 * }}
 */
export declare function runDualDevServer(processes: ProcessSpec[], options?: {
    onLog?: (name: string, line: string) => void;
    signals?: string[];
    forwardProcessSignals?: boolean;
}): {
    children: import("node:child_process").ChildProcess[];
    stop: (signal?: string) => void;
    exited: Promise<{
        name: string;
        code: number | null;
        signal: string | null;
    }[]>;
    dispose: () => void;
};
]],
  ["dist/supervisor.mjs"] = [[
// Dual dev-server supervisor -- M2, item 3 of
// docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md ("a supervisor that starts
// Meteorite dev + vite dev together, forwards signals, and merges logs").
//
// Plain JS (.mjs), not TypeScript: this package has no build step yet
// (see its own package.json description -- M0/M1 left @hydronium-js/vite as
// a type-checked skeleton with nothing compiling it), and this file is
// meant to be run directly with `node`, e.g. as the actual dev entry
// point for an app that wired both a Meteorite backend and a Vite
// frontend together (§2.5 of the plan: two real processes, forced,
// because Meteorite cannot serve websockets and Vite's HMR socket must
// reach Vite's own origin directly).
//
// Generic over "N named child processes", not hardcoded to exactly
// "meteorite" and "vite" -- keeps this file trivially testable against
// two plain `node` one-liners instead of needing a real Meteorite/Vite
// project on disk, and nothing about the merge/signal-forwarding logic
// below is actually specific to either tool.
import { spawn } from "node:child_process";
/**
 * @typedef {object} ProcessSpec
 * @property {string} name Short label used to prefix merged log lines.
 * @property {string} command
 * @property {string[]} [args]
 * @property {string} [cwd]
 * @property {NodeJS.ProcessEnv} [env] Merged over `process.env`, not replacing it.
 */
/**
 * @param {ProcessSpec[]} processes
 * @param {object} [options]
 * @param {(name: string, line: string) => void} [options.onLog] Called
 *   once per merged, newline-split output line (stdout and stderr both),
 *   prefixed by which process it came from. Defaults to a plain
 *   `[name] line` console.log -- pass your own to capture instead of
 *   printing (this is what the test suite does).
 * @param {string[]} [options.signals] Signals this process listens for
 *   and forwards to every child. Defaults to SIGINT and SIGTERM.
 * @param {boolean} [options.forwardProcessSignals] Set false to skip
 *   installing `process.on(signal, ...)` handlers entirely -- for tests,
 *   or for a caller that wants to drive `stop()` itself instead.
 * @returns {{
 *   children: import("node:child_process").ChildProcess[],
 *   stop: (signal?: string) => void,
 *   exited: Promise<{ name: string, code: number|null, signal: string|null }[]>,
 *   dispose: () => void,
 * }}
 */
export function runDualDevServer(processes, options = {}) {
    if (!Array.isArray(processes) || processes.length === 0) {
        throw new Error("runDualDevServer: `processes` must be a non-empty array of process specs");
    }
    const { onLog = defaultOnLog, signals = ["SIGINT", "SIGTERM"], forwardProcessSignals = true } = options;
    const entries = processes.map((spec) => {
        if (!spec || typeof spec.name !== "string" || typeof spec.command !== "string") {
            throw new Error("runDualDevServer: every process spec needs a string `name` and `command`");
        }
        const child = spawn(spec.command, spec.args ?? [], {
            cwd: spec.cwd,
            env: spec.env ? { ...process.env, ...spec.env } : process.env,
            stdio: ["ignore", "pipe", "pipe"],
        });
        attachLineForwarding(child.stdout, spec.name, onLog);
        attachLineForwarding(child.stderr, spec.name, onLog);
        return { name: spec.name, child };
    });
    let stopping = false;
    /** @param {string} [signal] */
    function stop(signal = "SIGTERM") {
        if (stopping)
            return;
        stopping = true;
        for (const { child } of entries) {
            if (child.exitCode === null && child.signalCode === null) {
                child.kill(signal);
            }
        }
    }
    // One process dying is not a state anyone wants the other left running
    // in -- a half-alive dev session (Vite up, Meteorite gone, or vice
    // versa) silently serves stale/broken pages instead of failing loudly.
    for (const { name, child } of entries) {
        child.on("exit", (code, signal) => {
            onLog("supervisor", `${name} exited (code=${code ?? "null"} signal=${signal ?? "null"})`);
            stop();
        });
    }
    const installed = [];
    if (forwardProcessSignals) {
        for (const sig of signals) {
            const handler = () => stop(sig);
            process.on(sig, handler);
            installed.push([sig, handler]);
        }
    }
    const exited = Promise.all(entries.map(({ name, child }) => new Promise((resolve) => {
        child.on("exit", (code, signal) => resolve({ name, code, signal }));
    })));
    return {
        children: entries.map((e) => e.child),
        stop,
        exited,
        dispose() {
            for (const [sig, handler] of installed)
                process.off(sig, handler);
        },
    };
}
function defaultOnLog(name, line) {
    console.log(`[${name}] ${line}`);
}
function attachLineForwarding(stream, name, onLog) {
    if (!stream)
        return;
    let buffer = "";
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => {
        buffer += chunk;
        let index;
        while ((index = buffer.indexOf("\n")) !== -1) {
            const line = buffer.slice(0, index).replace(/\r$/, "");
            buffer = buffer.slice(index + 1);
            onLog(name, line);
        }
    });
    stream.on("end", () => {
        if (buffer.length > 0) {
            onLog(name, buffer);
            buffer = "";
        }
    });
}
]],
  ["package.json"] = [[
{
  "name": "@hydronium-js/vite",
  "version": "0.1.0",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "default": "./dist/index.js"
    }
  },
  "peerDependencies": {
    "vite": "^8.0.0"
  }
}
]],
}
