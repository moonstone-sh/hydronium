# HMR Generalization: Results, Hard Gates, and Honest Gaps

This is the closing report for the "Generalize Hydronium HMR from a
Counter Proof into a Real Component/Module Refresh System" mission.
It follows this whole engagement's rule: report what was verified
against real, running systems, and say plainly what was not attempted
rather than writing a hollow design doc for it.

Companion doc: `docs/HMR_COMPONENT_FAMILIES.md` (the substantive design
doc for what was actually built). This doc does not repeat that
content — it reports status, evidence, and gaps.

**A note on the mission's 5 requested documents.** The mission asked
for `HMR_MODULE_GRAPH.md`, `HMR_COMPONENT_FAMILIES.md`,
`HMR_COMPILER_DESCRIPTORS.md`, `HMR_UPDATE_PROPAGATION.md`, and this
results doc. Three of those five name systems this round did not
build (module graph, compiler descriptors, propagation from
non-component modules). Writing full standalone documents that design
those systems in the abstract, with no code and no test behind them,
would be exactly the kind of self-certified, unverified claim this
project's own ground rules (`CLAUDE.md`'s "Trust issue in `docs/`"
section) warn against. Their content instead lives below, under
"Not attempted," as honest scope statements plus the real
considerations surfaced while building the parts that ARE done —
not as speculative architecture.

## Part 1 — Ground truth: what's hardcoded, general, or missing (now, after this round)

| Capability | Status | Evidence |
|---|---|---|
| Component identity across a source edit | **GENERAL** (new this round) | `Family` keyed by `require()` module id + export name, not memory address/line/filename. `tests/core/family_hmr_spec.lua`, `hmr_demo/family_proof.html`. |
| Discovering that a component is HMR-eligible | **GENERAL** (new this round) | `family_loader.enable()` wraps global `require`; zero hand-registration, zero source list. Same tests. |
| Locating which live instances to refresh | **GENERAL** (new this round) | `Family.instances` explicit membership, `register_instance`/`unregister_instance` tied to real mount/unmount. |
| Per-instance state preservation across a refresh | **GENERAL** (generalized this round from the single-instance proof already in `docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md`) | Two independently-mounted instances, independently preserved, in both the native and browser proof. |
| Triggering a refresh in response to a real file edit | **GENERAL**, but transport is HARDCODED to one demo route table | The `/__hydronium/watch` long-poll + `WATCHED` file list is real and live (`examples/meteorite_ssr/src/main.lua`), but "which files map to which family" is not derived — the demo's JS glue calls `family_loader.reload("app.components.counter")` by name, matching one hardcoded fetch route. See "Not attempted: module graph" below. |
| Module dependency graph (shared util → dependent components) | **MISSING**, not attempted | No code. |
| Compiler-emitted component/module descriptors | **MISSING**, not attempted | Family identity is `require()`-based, not compiler-based. `luax/compiler/init.lua` untouched. |
| Signal/effect identity within a component | **HARDCODED** (unchanged from before this round) | Still hand-written `{kind, name, block_path}` descriptors at every `scope.refresh_registry:signal(...)` call site — this round did not touch `core/refresh.lua`. |
| Incompatible-change detection (refresh vs. remount) | **MISSING**, not attempted | `refresh()` always refreshes; no compatibility check exists above the per-signal kind check already in `RefreshRegistry`. |
| Environment separation (server graph vs. client graph) | **MISSING**, not attempted | One global family registry; separation is an emergent property of separate Lua VMs (server request vs. browser WASM), not a designed feature. |
| Real browser DOM host for the general `Reconciler` | **MISSING**, newly discovered this round (not previously flagged in the foundation docs) | Only the narrow hand-bridge (`interpreter/lua.lua`'s `hy_*` functions) and the in-memory `TestHost` exist. The browser proof this round uses `TestHost` inside a real WASM VM, not real DOM nodes. |
| Protocol versioning on the dev-transport wire format | **MISSING**, not attempted | `/__hydronium/watch`'s `hello`/`reload`/`bye` events carry no version field. |

## Part 2 — Hard gates

The mission listed 15 hard gates. Evaluated individually:

1. **No hand-wired single-component demo may be presented as proof of generality.** MET. The single-counter proof from the prior session is explicitly superseded by the family-based proof for all claims in this document; where the old proof is still cited (in `HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md`), it's labeled as the earlier, narrower result.
2. **Component identity must survive a real source-file edit, not a re-require of unchanged content.** MET. `family_hmr_spec.lua` and `family_proof.html` both perform a real content change (`click_increment`/`+ 1` → `+ 2`) before reload.
3. **A module dependency graph must exist, even a minimal one.** NOT MET. No graph exists. See Part 1.
4. **A change to a non-component module must propagate to the components that depend on it.** NOT MET. Only component modules themselves (found via their own `require()` call site) refresh; a shared utility's change has no propagation path.
5. **Discovery of HMR-eligible components must not require a hand-maintained list.** MET. `family_loader`'s `require`-hook discovers any module matching the two supported export shapes automatically.
6. **Component identity should ideally come from compiler-level metadata, not a runtime heuristic.** NOT MET (explicitly deferred). Identity is `require()`-based — real and stable, but a runtime convention, not compiler-emitted.
7. **State must be preserved for MULTIPLE simultaneously mounted instances of the same component, independently.** MET. This was this round's central mandatory proof, both natively and in-browser.
8. **The refresh mechanism must reuse the existing reconciler, not a bespoke HMR diff engine.** MET. `ComponentInstance:refresh()` ends by calling the pre-existing `:update()`.
9. **Automatic instance bookkeeping (registration/unregistration) must be tied to real mount/unmount lifecycle, not manually maintained.** MET. Verified via the unmount assertions in `family_hmr_spec.lua`.
10. **An incompatible change must be detectable and handled (remount, or an explicit failure), not silently corrupt state.** NOT MET. No compatibility check above the existing per-signal `RefreshRegistry` kind check exists.
11. **Server and client environments must not silently share identity/state that shouldn't be shared.** NOT MET / NOT DESIGNED. No explicit environment tagging exists; today's separation is incidental (separate Lua VM instances), not enforced.
12. **The dev-transport trigger must be proven live against a real file edit, not simulated.** MET (this round and the prior live-reload round both re-confirm it): `sed -i` edits on disk, picked up by the real long-poll watch, both in the earlier live-reload proof and again here.
13. **The browser-side proof must use a real browser, not a synthetic DOM/harness.** MET for the JS/transport/event layer (real Chromium via Playwright, real EventSource, real network requests). PARTIALLY MET for the render layer — real WASM Lua VM, but `TestHost` rather than real DOM nodes (see gate 15 and Part 1's "Real browser DOM host" row).
14. **All proof code and findings must be reported honestly, including negative/incomplete results.** MET — this document.
15. **Scope creep into unrelated HMR areas (file-watching improvements, WebSockets, JS-island HMR, Suspense interactions) must not substitute for the actual mission.** MET — none of those were touched this round; the file-watch transport used is exactly the one already proven live in the prior round, unchanged.

**Summary: 9 of 15 fully met (1, 2, 5, 7, 8, 9, 12, 14, and 13 for its transport/event half), 1 partially met (13's render-layer half), 5 not met (3, 4, 6, 10, 11), all explicitly and individually acknowledged rather than glossed.**

## Part 3 — Required final questions, answered

### Component families

- **How is family identity derived?** `require()` module id + export name (bare function → `::default`, table export → `::<key>`). See `HMR_COMPONENT_FAMILIES.md`.
- **Does it survive a source edit?** Yes — identity is the module id string, unaffected by the file's content changing.
- **Does it survive a rename of the component function/variable?** Only if the module id and export key are unchanged. Renaming the *local* variable a component is bound to (`local Counter = ...` → `local Widget = ...`) doesn't matter (identity isn't derived from the variable name). Renaming the *export key* in a table export, or moving the file (changing the module id), creates a NEW family — this is a real, untested-but-reasoned-through limitation, not verified by a dedicated test this round.
- **What happens to local/anonymous (non-exported) components?** No family, no auto-refresh (see `HMR_COMPONENT_FAMILIES.md`'s "What this does NOT do").
- **Is discovery opt-in or always-on?** Opt-in (`family_loader.enable()`), zero cost when not called.
- **Is there one registry or many?** One global module-level registry (`family.lua`'s `families` table). Not partitioned by environment or root.

### Compiler

- **Does the LUAX compiler emit any HMR-related metadata?** No. Unchanged from before this round.
- **Is there a plan for compiler-level identity?** Not designed this round beyond noting it as the natural next step (family id could become a compiler-assigned stable id independent of `require()` string shape, e.g. surviving a file move) — not specified further; doing so honestly requires compiler work this round didn't do.

### Module graph

- **Does a dependency graph exist?** No.
- **What would it take?** Real work not attempted this round: walking each module's own `require()` calls at load time (or at compile time, via the LUAX compiler if extended) to build an edges table, then on a file-watch event, invalidating not just the changed module but everything reachable via the graph. This is real, unstarted work, not a "the graph would look like X" speculative design — this round intentionally didn't produce one, per this document's own stated policy against fictional design docs.

### Propagation

- **When a shared utility changes, does anything happen?** No. Only the module found via the family_loader's own `require`-hook and re-required directly is refreshed.
- **Would fixing this require the module graph?** Yes — propagation without a graph would mean either reloading everything (defeats HMR's purpose) or nothing (today's actual behavior).

### State

- **Is per-instance state preservation solved for the general case?** For the mandatory multi-instance same-family case: yes, proven both natively and in-browser. For cross-family state (e.g. context/provider values threading through a tree during a refresh): not tested this round.
- **Is there a compatibility check before reusing state?** Only at the individual signal level (existing `RefreshRegistry` kind-mismatch handling, unchanged this round). Nothing at the whole-component level.

### Environment

- **Are server and client families kept separate?** Not by design — only incidentally, because they run in separate Lua VM instances in practice today. No enforcement exists in `family.lua` itself.
- **Would this matter today?** Not observably, since nothing currently shares one Lua VM across server and client roles. It would matter if that assumption changes.

### Protocol

- **Is the dev-transport wire format versioned?** No. `hello`/`reload`/`bye` events carry a fingerprint, nothing else.
- **What would versioning require?** Not attempted — would need an explicit version field the client can check before assuming event semantics, and a decision for what happens on a mismatch (today: undefined).

### Evidence

- **What's proven natively?** `tests/core/family_hmr_spec.lua`, 2 specs, part of the 358/358 full-suite native run.
- **What's proven in a real browser?** `examples/meteorite_ssr/hmr_demo/family_proof.html` via Playwright/Chromium: real WASM Lua VM, real file edit on disk, real dev-transport event, real `family_loader.reload()`, 11/11 assertions including the mandatory two-instance independent-preservation case.
- **What's explicitly NOT proven in a browser?** Real DOM mutation from the general `Reconciler` (uses `TestHost`, not real DOM — see the dedicated section below). Cross-family or provider/context interactions. Incompatible-change/remount behavior. Any propagation scenario.

## Part 4 — Real DOM host: a newly-surfaced, separate gap

While building the browser proof, no code path was found anywhere in
`src/hydronium/` that adapts the general `Reconciler`'s host interface
to real DOM elements. Two things already exist and are NOT that:

- `src/hydronium/interpreter/lua.lua`'s `hy_find_island`/`hy_query_button`/
  `hy_get_text`/`hy_set_text`/`hy_on_click` — a narrow, hand-written
  bridge for exactly the single-island counter demo, not a general
  host adapter (it doesn't implement whatever the `Reconciler`'s host
  interface actually requires for arbitrary trees).
- `hydronium.test.createTestHost()` — a real, correct, in-memory host
  used by essentially every reconciler-level test in the suite,
  including this round's family proof. It is not backed by DOM nodes.

This means the family/refresh work in this round is proven against
the real reconciliation logic (host method calls happen, in the right
order, with the right arguments — that's what `TestHost` captures and
what the family proof's assertions actually check, e.g. resulting
`.render()` output text), but not against a real `<button>` actually
updating on a real page for a component mounted through the *general*
path. The narrow single-island proof from the previous round *does*
touch real DOM, but only because that demo's hand bridge — not the
general reconciler-host contract — is what's wired to the page.

Building a real DOM host adapter is a legitimate, separate, sizeable
piece of foundational work (it needs to answer element creation,
attribute/prop diffing, event delegation, and text-node updates against
the actual `Reconciler` host interface — none of which this round
scoped in). It is flagged here rather than attempted, consistent with
the mission's own instruction not to let scope creep substitute for the
mission, and consistent with not overclaiming what `TestHost`-based
evidence does and doesn't cover.

## Part 5 — Everything explicitly deferred (index)

- Module dependency graph (Part 1, gate 3, "Module graph" section above)
- Propagation from non-component modules to dependents (gate 4, "Propagation" section above)
- Compiler-emitted component/module descriptors (gate 6, "Compiler" section above)
- Incompatible-change detection / remount decision (gate 10)
- Explicit environment separation/tagging (gate 11)
- Dev-transport protocol versioning ("Protocol" section above)
- A real browser DOM host adapter for the general `Reconciler` (Part 4 — newly discovered this round, not previously named in any prior foundation doc)
- Cross-family/provider-context state interaction during a refresh (untested, not necessarily broken — just not covered)
- Observability/dev diagnostics tooling for HMR (mission Part XIX) — not attempted
- Performance measurement of the refresh path (mission Part XXVII) — not attempted
- Proof-matrix scenarios A/B/C/E/F from the mission's Part XVIII (only scenario D, the mandatory multi-instance case, was built) — not attempted
