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

## Still pending

1. **Meteorite source snapshots.** Meteorite serves individual module-source
   routes. The client commits fetched content atomically, but a file can change
   while a multi-module fetch is underway. Add a revision-addressed snapshot
   endpoint so one batch always names one immutable source set.
2. **State-preserving remount.** The current mount API has no remount handle or
   state-transfer contract, so a planner `remount` outcome reloads the page.
3. **Multi-file Ink delivery.** Generated Ink projects currently watch
   `src/App.luax`. The runtime accepts batches; file discovery and a
   file-to-module delivery contract are still required to exercise it.
4. **Public build-manifest delivery.** Ballad emits module records at build
   time, but the live browser VM does not yet receive that seed manifest.
   Runtime observations therefore remain the active graph source.
5. **LÖVE adapter.** `hmr_host` is host-neutral, but no LÖVE file watcher and
   update-loop adapter has been implemented.
6. **Effect-safe module contracts.** Staged loader rollback cannot undo
   arbitrary side effects performed by a module while it evaluates. Define the
   module lifecycle contract or classify such modules as restart-only.
