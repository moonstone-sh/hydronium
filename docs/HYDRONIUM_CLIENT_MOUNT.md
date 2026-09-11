# hydronium.client.mount -- a Real, Reusable Client Bootstrap

Closes two items from `docs/HMR_DOM_HOST.md`'s gap list (H1 and H4,
plus fixing H5): before this, `d.lua.mount(<App/>)` was documented to
work but didn't (both `Reconciler:mount` and `:hydrate` unconditionally
`error()`ed on every ISLAND-kind vnode), and the only real proof of the
DOM host (`examples/meteorite_ssr/hmr_demo/dom_host_proof.html`)
hand-inlined the wasmoon boot, the DOM bridge, and a 110KB hand-pasted
JSON blob of every required module's source, per page -- a real,
correct verification technique, not a shippable API.

## What's new

- **`src/hydronium/core/reconciler.lua`**: an ISLAND-kind vnode whose
  descriptor has `interpreter == "lua"` is now treated transparently,
  like a Fragment, across `mount`/`hydrate`/`reconcile`/`unmount`/
  `getHostNode`/`getAllHostNodes` -- there's no cross-language boundary
  left to cross once already inside the Lua VM running the reconciler
  itself. A `interpreter == "js"` island is unchanged and still refused
  (js-island hydration is a genuinely different code path,
  `bootstrap.js`'s dynamic `import()`, never this reconciler). Native
  proof: `tests/core/lua_mount_spec.lua` (mount, hydrate, a real state
  update reaching the DOM, unmount/disposal, and a control case for the
  js-island refusal staying intact).
- **`src/hydronium/host/dom.lua`**: the `__dom_*` bridge is no longer
  bare, unguarded globals -- `createDomHost(bridge)` now accepts an
  explicit bridge table (falling back to the `__dom_*` globals when
  omitted, unchanged for every existing real-browser caller) and
  validates it eagerly, erroring with a named list of what's missing
  instead of a bare `attempt to call a nil value`. This is also what
  makes native testing possible without touching `_G`: **`tests/host/dom_spec.lua`**,
  15 specs against a real (not mocked) in-memory fake bridge, covering
  prop/attribute/event diffing, listener replacement, and a real
  `Reconciler.mount`/`:reconcile` integration -- this module had zero
  test coverage of any kind before.
- **`tools/gen_client_manifest.lua`**: derives the client runtime's
  module list from the ACTUAL `require()` graph (by wrapping the global
  `require` and recording every module id it resolves while requiring a
  given set of entry modules) instead of a hand-maintained list --
  applying this codebase's own established HMR rule (`family_loader`'s
  own doc comment: "never maintain manual source lists when the
  runtime/compiler already knows the require graph") to the client
  manifest problem. `luajit tools/gen_client_manifest.lua <entry ids...>`
  emits a flat JSON `{module_id: relative_path}` map.
- **`src/hydronium/client/dom_bridge.js`**: the real `__dom_*` bridge
  implementation, extracted into an actual importable module (`createDomBridge()`).
  Carries forward two real bugs found the hard way building the
  original inline version (documented in its own comments): Chromium's
  wasmoon marshalling mishandling a bare `null` return (fixed by
  returning `undefined`), and `set_listener`'s REPLACE semantics
  (required by `hydronium.host.dom`'s own contract).
- **`src/hydronium/client/mount.js`**: `mount({ hydroniumBaseUrl,
  manifestUrl, appModuleId, appModuleUrl, container, props, hydrate })`
  -- boots wasmoon, installs the DOM bridge, fetches every manifest-listed
  module plus the app's own entry module over real HTTP (not embedded),
  and mounts (or hydrates) through `dom.lua.mount` + the ordinary
  reconciler. Props cross the JS/Lua boundary as a real Lua table-
  constructor source string evaluated via `load()`, not wasmoon's
  built-in object marshaller -- found live that the latter does not
  reliably deep-marshal a plain JS object into something Lua can index
  (`lua.global.set("props", {initial: 10})` produced a value
  `props.initial` read back as `nil`).

## What this is NOT

- **Not a bundler.** Every runtime module is its own real HTTP request
  (confirmed live: 21 separate fetches for the framework plus 2 for the
  manifest/app entry in the verification proof below). `docs/BUNDLING.md`
  describes what a real single-file amalgamation would still need to
  do (minification, caching, a build step) -- none of that exists yet.
  This is deliberately scoped smaller: "derive the real list from the
  real graph and fetch each file for real," not "produce one optimized
  bundle."
- **No SSR-to-client hydrate round trip exercised through `mount.js`
  itself yet** -- `mount()`'s `hydrate: true` option calls the same real
  `Reconciler:hydrateRoot` already proven directly in
  `dom_host_proof.html`, but no proof in this pass drives it through
  `mount.js`'s own fetch-based loading against real SSR-rendered markup
  end to end. The verification below uses `hydrate: false` (client-only
  mount).
- **No router.** Still nothing anywhere in this codebase resembling
  client-side navigation.

## Verified for real

`examples/meteorite_ssr/client_mount_demo/` (`index.html` + `app.lua` +
a `client_manifest.json` generated by the tool above), served by the
real compiled Meteorite binary, driven by Playwright/Chromium:

- 25 real HTTP requests observed (via a `window.fetch` wrapper the page
  installs on itself): the manifest, 21 real hydronium runtime module
  files, the wasmoon WASM binary, and the app's own entry module --
  zero embedded source blobs anywhere in the page.
- The real initial prop (`{ initial: 10 }`) reached the mounted
  component: `Count: 10` on first paint.
- Two real DOM clicks drove state through the ordinary reconciler to
  `Count: 12`.

5/5 assertions passed. Full native suite: 384/384 (`luajit tests/runner.lua`).
