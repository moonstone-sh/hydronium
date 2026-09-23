# Pending HMR work

This release establishes the first safe, graph-informed HMR path for
Hydronium browser and Ink applications. It is intentionally not a claim that
every edit can be applied in place.

## Shipped in this release

- `hydronium.core.module_graph` observes real `require()` edges, including
  cache hits, and retains reverse-importer relationships, loaded generations,
  source-management coverage, and module revisions.
- The deterministic planner classifies a batch as `hot`, `installed`,
  `remount`, `restart`, or `rejected`. It invalidates reverse dependents,
  orders acyclic work dependency-first, and fails closed for cycles or opaque
  modules.
- HMR stages a source batch before committing it. Loader and
  `package.loaded` state are restored if staging fails. This cannot roll back
  arbitrary module side effects, so modules that need that guarantee remain a
  restart boundary.
- Component families are created only for exported functions that are actually
  mounted; plain function-valued utility exports do not become HMR boundaries.
  Mounted instances resolve the family's current definition rather than a
  stale function reference.
- `hydronium.core.hmr_host` provides a host-neutral queue/flush boundary.
  Browser updates are fetched as a batch, serialized, and committed once on
  `requestAnimationFrame`; Ink flushes from `onTick`.
- The browser transport accepts legacy single-module events as well as batches,
  suppresses duplicate revisions, and reloads the page for rejected, remount,
  restart, fetch, or refresh failures.
- Hydronium's Ballad client closure includes `hmr_host` and graph
  dependencies; generated SSR and Ink scaffolds include the required runtime
  modules.

Verified before release: the Hydronium Lua suite (899/899), browser client
suite (27/27), Create suite (18/18), focused core/HMR/Ink tests (9/9), LuaJIT
bytecode compilation for the client plugin and host, and `git diff --check`.

## Completed after v0.1.7 (pending the next release)

- **Revision-validated module snapshots.** The generated SSR app's module
  route now reads a source value between two whole-watch-set fingerprint
  checks. A request carrying an obsolete revision, or a source read racing a
  new save, receives `409` rather than a mixed batch; successful responses
  carry `X-Hydronium-Revision`. The browser rejects a mismatched response
  revision and reloads safely.
- **Forms typings reach consumers.** Form and action declarations now cover
  the public Form API, ship in `hydronium/core`, and are added to a generated
  project's LuaLS library path.
- **Explicit browser remount contract.** `mount()` now returns `remount()`.
  The HMR transport delegates a planner `remount` outcome to it instead of
  immediately reloading. A Lua app may opt into state transfer through
  `__hydronium_hmr_snapshot()` and `__hydronium_hmr_restore(value)`; absent
  hooks reset state safely rather than attempting to infer arbitrary tables.
- **Topology-backed Ink proof.** Generated Ink apps now declare roots and
  public entry aliases in `hydronium.sources.lua`, rather than assigning
  framework meaning to `views`, `components`, or `App`. The resolver checks
  path, logical-ID, overlap, and case-folding collisions; Ink consumes the
  resulting records and queues a multi-file update at `onTick`. LUAX refresh
  descriptors now use that logical ID rather than a physical filename.
- **Ballad topology adapter.** `hydronium_ballad.plugins.topology.classify`
  loads the same declaration and stamps ordinary Ballad source assets with
  normalized module ID, transform, target, update, tag, and origin metadata.
  Existing LUAX compilation and client resolution consume that metadata
  without adding Hydronium conventions to Ballad itself.
- **Public static module manifest.** The Ballad site manifest now emits a
  `modules` section with logical ID, target, transform, update policy, and
  revision. It intentionally omits physical origins and paths.
- **Dev topology registry.** DOM development loads the same explicit source
  inventory, produces a browser manifest, whitelists module-source requests,
  and derives its snapshot watch set from it. The SSR example and scaffold
  now derive browser preload URLs and HMR update policies from that manifest;
  changing the declaration itself is a reload boundary.

## Completed after the initial topology pass

- **Effect-safe module contracts.** A normalized record now declares
  `effects = "safe" | "managed" | "restart"`, defaulting to `restart`.
  The module planner checks every member of the changed module's reverse
  importer closure before staging code. Any undeclared, opaque, or restart-only
  member produces a controlled restart and evaluates no replacement source.
- **Private generated inventory.** Ballad's topology plugin emits revisioned
  `.hydronium/source-inventory.json` and dependency-free `.lua` artifacts with the complete normalized
  physical-path mapping. It is host-private metadata; the public site manifest
  still exposes only logical client semantics and never origins or paths.
- **Tag-based route adapter.** `hydronium_router.topology.routes(records)`
  lowers only explicit `tags.route` declarations. It accepts any source layout,
  validates route IDs and paths, and never treats a directory name as routing
  convention.
- **LÖVE update-loop adapter.** `hydronium.core.love_hmr` supplies a
  `love.update`-safe polling boundary over topology records. Its injected
  reader makes it testable, while `from_love` uses `love.filesystem.read` in a
  real LÖVE game.

## Remaining integration work

- **Real LÖVE-engine CI.** `hydronium/create --template love` now produces a
  topology-backed game and the generated content is validated in the Create
  suite. The adapter itself is unit-covered. A headless LÖVE binary fixture is
  still needed to exercise an actual engine loop in CI.
- **Ballad layout recipe.** The SSR scaffold now prefers
  `.hydronium/source-inventory.lua` when a Ballad build has produced it and
  falls back to its checked-in declaration for first-run source development.
  A documented, turnkey application partiture that emits that inventory is
  the remaining ergonomics work; the producer and host consumer are complete.
