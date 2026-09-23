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
export function resolveDevOrigin(config: DevOriginConfig): string {
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
export function devCorsConfig(): true {
  return true;
}
