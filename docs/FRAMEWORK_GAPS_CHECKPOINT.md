# Framework integration checkpoint

Updated 2026-10-11. This is local verification, not a publication record.

| Area | Evidence | Remaining release gate |
| --- | --- | --- |
| Configuration | Explicit decoder; both Moonstone entrypoints exercise the candidate API | Roll forward package dependencies |
| Auth flow | Separate `hydronium/auth` package, cancellation/stale/duplicate guards, installed Registry integration and browser failure stories | Publish package and replace Registry local path dependency |
| Forms | Existing Standard Schema form API accepts Valua; Registry boundary checks pass | Keep server authorization authoritative |
| Remote grids | Query/Table adapter; authorized Registry search, sorting, totals and pagination; retry and shrinking-page tests | Update API and framework packages together |
| Interop | Deterministic schema generation check; seven TS/Lua wire fixtures agree | Expand contracts when new endpoints acquire stable DTOs |
| Lab | 72 stories render; Vite stylesheet and fonts shared with Registry | Sign-in keyboard/360px/1280px checks and Lab error interactions passed; broader accessibility audit remains |
| CSS Modules | Actual Vite build and dev tests; stable names preserve ordinary CSS HMR | Real Chromium link-update regression preserves draft and focus; composition/export changes intentionally reload |
| Package closure | Core/Auth/Query/Table isolated artifacts and normal Moonstone-installed consumer; seven artifacts exported with new coordinates | Publication and application upgrades |

## Linux pipeline measurements

Used the existing `moonstone-ci-linux:local` Docker image, network disabled,
read-only source mounts and an ephemeral `/tmp` fixture. No image downloads,
production accesses or full server compilation were involved. Measurements use
Python's monotonic clock around actual Ballad inventory/client/assets pipelines.

| Run | Elapsed |
| --- | ---: |
| Cold | 1.082 s |
| Warm | 0.659 s |
| CSS edit | 0.611 s |
| Lua edit | 0.846 s |

Warm and CSS-only runs reused compile/minify/bundle nodes. The CSS edit retained
the Lua client manifest; the Lua edit changed it. Reproduce the fixture with
`sh tests/build/benchmark_incremental.sh`; supply `HYDRONIUM_FRAMEWORK_ROOT`
when the installed source closure lives outside the workspace environment.
These timings do not establish full Docker image rebuild or native server
performance. Those remain release measurements.

## Browser checks

`bun tests/css-hmr.browser.mjs` from `js/packages/vite` launches Chromium and
verifies that a real stylesheet-link update changes the color while preserving
the document, unsaved input and keyboard focus.

Registry's `scripts/verify-browser.mjs --lab` checks island boot, sign-in
and registration keyboard order, feedback/stepper semantics and overflow at 360px/1280px, then exercises fake expired-code
and transport-error transports in the live Lab. Set `PLAYWRIGHT_MODULE` to an
installed Playwright module if it is outside that application's dependencies.
These are targeted interaction checks, not a complete accessibility audit.

## Version reconciliation and rollout

The public API was rechecked on 2026-10-10: Core 0.2.11, DOM 0.3.12,
LUAX 0.2.13, Ballad plugin 0.2.7, Query 0.2.2 and Table 0.2.3 were the latest
published coordinates; Auth returned 404. Source manifests now prepare Core
0.2.12, Auth 0.1.0, DOM 0.3.13, LUAX 0.2.14, Ballad plugin 0.2.8, Query
0.2.3 and Table 0.2.4, plus Create 0.5.22 (latest published Create was 0.5.21). Exported path dependencies derive their minimums from
these manifests. These coordinates are not reserved or published.

Registry consumes `hydronium_auth` directly and no longer keeps a second auth
controller. Its manifest/lock use `path:../../../hydronium/auth` for local
integration; the other framework dependencies remain published packages.
The production Docker context does not include that sibling checkout. Before
building a deployable image, publish Auth, replace the path dependency with
`hydronium/auth@^0.1.0` through Moonstone, update the remaining framework
minimums, and regenerate the application's lock with Moonstone. Do not deploy
this development path dependency.

Publication belongs to the Hydronium monorepo release workflow, using its
CI secret; a local publication token is unnecessary. No package or application
was deployed. Real GitHub OAuth, email delivery, physical passkey and installed
CLI handoff still need provider/device verification. Full native image timing
and the broader accessibility audit remain open; targeted auth accessibility
and failure-state checks passed.

## Fresh scaffold verification

`sh tests/test_candidate_scaffold.sh` runs the actual Create CLI with Bun,
registers a temporary file registry, installs seven exported candidate packages,
renders a component using standalone Auth through the installed SSR runtime,
builds the production browser bundle, checks Auth is included, and verifies
the generated lock. It passed. This is not yet an HTTP/native image or
browser hydration proof for the fresh scaffold.

The check exposed dynamic fallback `require(id)` calls in the generated App;
these now resolve exclusively from explicit literal module maps. Create's Vite
vendor was regenerated with the canonical tool, and generated Vite configs
activate `luaStyles()` so optional Lua CSS imports participate in the build.
Generated dependency floors match the framework candidate versions. Existing
Registry sign-in and registration still pass real browser boot and failure
interaction checks. Core's archive is explicitly checked not to contain Auth.

## CI/CD publication

The `Publish Hydronium` workflow calls the reusable `Hydronium CI` workflow
against the exact release tag before its publish job may run. Both validation
jobs check out that ref, including manual retries using `release_tag`. Auth is
an orbit member and part of the normal root export, so it follows the same
artifact upload and publication path as the other packages. The exported data
primitives consumer installs Auth explicitly and verifies cancellation/stale
reply behavior without source paths. The web job runs the Lua stylesheet
adapter tests and the Chromium draft/focus preservation check.

Use the monorepo's normal `v*` tag release; use workflow dispatch with that
existing tag for retries. Keep registry publishing credentials in CI. The
existing first-publication visibility follow-up documented by the release
workflow still applies to new coordinates such as Auth.
