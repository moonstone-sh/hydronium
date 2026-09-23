// Shared file list for sync-dom-client.mjs and check-dom-client-drift.mjs.
//
// This is the single source of truth for "what files make up the client
// runtime" -- both scripts import it so they can never silently drift from
// each other about which files matter.

// The 9 hand-written runtime files, moved byte-for-byte in M0 from
// dom/src/hydronium_dom/client/ into packages/dom-client/src/.
export const RUNTIME_FILES = [
  "mount.js",
  "dom_bridge.js",
  "bootstrap.js",
  "hmr.js",
  "dev_transport.js",
  "dev_reload.js",
  "priority.js",
  "boundary_registry.js",
  "forms.js",
  // Dev error overlay. Served like the rest so a dev page can import it
  // from /js/bootstrap/ without a bundler; it does nothing unless a host
  // explicitly calls installErrorOverlay().
  "overlay.js",
  // Source Map v3 reader backing the overlay's resolveFrame hook.
  "sourcemap.js",
];

// The hand-authored ESM wrapper around wasmoon's UMD bundle. Committed
// source (not npm-derived) -- see its own header comment for why it has
// to exist at all.
export const WASMOON_WRAPPER_FILE = "vendor/wasmoon/wasmoon.esm.js";

// Files derived from the real `wasmoon` npm dependency (M0: "replace the
// vendored client/vendor/wasmoon/ with a real wasmoon dependency"). Sourced
// from node_modules/wasmoon at sync time, not hand-copied.
export const WASMOON_NPM_FILES = [
  { from: "dist/index.js", to: "vendor/wasmoon/index.js" },
  { from: "dist/glue.wasm", to: "vendor/wasmoon/glue.wasm" },
  { from: "LICENSE", to: "vendor/wasmoon/LICENSE" },
];
