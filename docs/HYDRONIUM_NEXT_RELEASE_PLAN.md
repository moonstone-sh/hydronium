# Next Hydronium release: readiness and gates

Draft, 2026-09-28. No versions, tags or registry entries have been changed by this plan.

## What is supported by current evidence

The corrected local SSR + Vite + Tailwind + Bun development path was exercised in `coso` during this work: startup, hydration, Lua component refresh, CSS updates and production assets. A fresh `bun run build` also succeeds today. The project uses local Hydronium path dependencies and a vendored Vite adapter; this is evidence for working source, not for the currently published registry/npm closure.

Recent focused checks include 14 Ink Lab client tests, 21 Ink session/Lab Lua tests, native ANSI/headless-xterm parity, live browser animation/selection/zoom/focus/wheel checks, and the Ink Lab source artifact's bundled JS/CSS/licenses. Earlier generator and HMR regressions passed in this session. The full current release CI and fresh artifact consumer matrix still have to run together before a release claim.

Ordinary recognized LUAX setup signals preserve state across compatible component refreshes. Structural changes, unsupported signal declaration shapes or unsafe refreshes may require a remount/full reload. Describe that boundary; do not promise every source edit preserves arbitrary state.

Tailwind scans source text, including explicitly registered Lua/LUAX sources. Complete class names work; dynamically constructing fragments such as `bg-` plus a color plus `-500` cannot be inferred. Reference: https://tailwindcss.com/docs/detecting-classes-in-source-files

## Release train

Latest public release verified: `v0.3.1`. The `v0.3.2` candidate is committed and its packaged gates are running before publication. Member packages have independent versions; the train tag is not their version number.

Inventory changed packages and bump only those whose shipped contents changed. Candidate versions include core/luax 0.2.2, dom 0.3.1, cli 0.4.1, create 0.5.2, ink 0.5.1 and ink-lab 0.3.1. The remaining exported packages also receive patches because their shipped locks and dependency metadata changed. The browser-client canonical source and its generated DOM copy both changed. Account for the npm adapter packages as a separate release surface. Choose patch/minor numbers from actual public API changes and published metadata, not just working-tree version strings.

Do not rebuild changed bytes under an already published immutable version. The release workflow deliberately skips existing-version conflicts; failing to bump a changed member could silently leave its fix unpublished.

Update dependency constraints and locks through Moonstone commands. Build/sync the versioned closure in dependency order, export it with the root Ballad partiture, and verify artifact contents before publishing.

## Required gates

- Core/compiler/DOM/Ink/generator/CLI suites, client tests, adapter tests and DOM-client drift checks.
- Install Ink Lab's pinned Bun dependencies, rebuild JS/CSS, assert no generated-asset drift, and run ANSI tests. CI and release now rebuild this pinned Bun bundle and check generated-asset drift. CI also runs native ANSI parity.
- Build all source/native registry artifacts and confirm xterm assets/licenses are self-contained. Exercise native targets supported by CI; local macOS results do not establish Linux success.
- Generate a fresh SSR + Tailwind project from candidate packaged `hydronium/create`. Use registry/artifact dependencies, not sibling paths or developer caches. If the Vite adapter is vendored, prove that it came from the shipped artifact, not a manual local repair.
- Run with Bun. Confirm correct server/CSS URLs, clean hydration, real browser interactivity, and that one dev command supervises both Vite and Meteorite.
- Increment a component counter, edit component logic, and assert the value survives and the browser VM/page identity does not change for a compatible edit.
- Add a new Tailwind utility in a `.luax` file, then add/rename/remove a view. Assert CSS updates without resetting state, and source discovery follows the module graph.
- Introduce a syntax error, verify diagnostics, repair it, and verify recovery. Build/start production output and confirm hashed CSS, correct mounting, and no development-only bridge.
- Check generator command adaptation for Bun/npm/pnpm/yarn. Bun is the primary live smoke test for this work; the other managers need their own release matrix evidence.

Existing CI already has consumer, Meteorite/Vite production and dual-HMR gates. Extend those gates for the repaired generated SSR + Tailwind path rather than using example-only success as a substitute.

## Publishing surfaces

The tag-driven `.github/workflows/release.yml` exports Moonstone registry packages with Ballad, uploads mirrored GitHub release assets and invokes each package's publish script. It supports rerunning an existing tag after publish failure.

That workflow does not publish `@hydronium-js/dom-client` or `@hydronium-js/vite` to npm. Either publish/version their changed contents separately, or explicitly ship the required adapter closure in the generator artifacts. Verify public package resolution and registry visibility from a fresh consumer before announcing availability.

The workflow comments also document a visibility follow-up for first-time registry packages and its existing-version skip behavior. Verify actual release outcomes rather than assuming a successful upload makes every package usable anonymously.

The fixes and versioned closure are committed for release. The user explicitly authorized bumps, packaged consumer/HMR gates, adapter verification and publication. Publish the tag only after final-commit CI passes, then verify public registry and npm resolution.

## Assessment

Closer to a coherent development release: yes. The main user-facing loop now works locally and the regression fixes are concrete. Ready to claim that any fresh public install has the same experience: not until the artifact/npm/registry consumer gates above pass. DevTools and richer story controls should be a follow-on feature train, not an indefinite blocker for delivering the current fixes.
