# Hydronium Lab on Meteorite

This is the UX/DX delivery plan for turning the existing Lab primitives into a
component workbench that is as easy to enter as Ladle or Storybook. The target
authoring convention is `*.stories.lua` and `*.stories.luax`; Meteorite is the
default development host, not a dependency of the story model or Ink runtime.

## Product contract

The ordinary path should be:

```sh
# Once, in an existing Hydronium project
hydronium lab init

# Every day after that
moon run lab
```

`hydronium lab init` must use Moonstone commands to add dependencies and set the
script. It must not edit `.moonstone/env`, `moonstone.lock`, or hand-patch TOML.
It adds an example only when the project has no stories, and never edits the
application's `src/main.lua`.

`moon run lab` discovers colocated stories, starts a dedicated loopback
Meteorite Lab server (default port `6100`), prints its URL, opens it when an
interactive desktop session permits, and keeps the last good preview visible
through authoring errors. `--no-open`, `--host`, `--port`, `--ci`, and
`--config` are the complete first public flags. A normal project needs no
endpoint, asset, watcher, or registry wiring.

The dedicated server is deliberate. It prevents Lab routes from entering the
application's production graph, avoids port conflicts with `hydronium dev`, and
does not make every app carry a development UI. A later `hydronium dev --lab`
may mount the same plugin under the app server, but it must use the identical
plugin and protocol rather than a second implementation.

## Why this is a Meteorite development plugin

Yes: the integration should be a Hydronium/Meteorite plugin in the same sense
that Storybook and Ladle use a builder/dev-server integration. Story discovery,
watching, development assets, HTTP transport, lifecycle, and browser-session
isolation are host responsibilities.

Meteorite's current `app:use()` graph plugins are build-time graph mutation
passes. They are not the right lifecycle boundary for Lab. In optimized hybrid
mode Lua states are cached per worker thread; consecutive HTTP operations are
not guaranteed to reach the same state. An Ink session therefore cannot be
stored safely in an ordinary Lua route module or a module-global table.

Add a separate, dev-only Meteorite extension contract with these properties:

- loaded by `meteorite dev`, never by a release build unless explicitly
  requested by a future release-oriented feature;
- able to declare routes, package-owned assets, watch inputs, and startup /
  shutdown hooks before the server starts;
- able to register a **single-owner Lua service**: requests are serialized onto
  one owned Lua state, independent of HTTP worker selection;
- supervised by the same Clingy/Meteorite process group, so SIGINT, SIGTERM,
  build failure, and parent death close Lab sessions and reap the service;
- namespaced and deterministic: duplicate extension ids, route collisions, or
  asset mount collisions are fatal diagnostics before listening;
- visible in the structured dev event stream (`plugin_ready`, `plugin_error`,
  `plugin_reload`) without changing production request semantics.

The first consumer is `hydronium/meteorite`, which supplies the Lab plugin.
The API should remain general enough for other development tools; it must not
teach Meteorite about stories or Ink.

## Package boundaries

- `hydronium/lab` owns story/collection values, normalized catalog records,
  convention semantics, controls metadata, URL-safe args validation, and a
  host-neutral discovery planner over a supplied list of paths. It performs no
  filesystem enumeration and knows nothing about Meteorite or Ink.
- `hydronium/ink-lab` owns the Ink adapter, deterministic in-memory sessions,
  canonical frame snapshots, browser terminal surface, and Ink-specific size,
  color, input, paste, step, and interaction operations.
- `hydronium/meteorite` owns the Meteorite dev extension, portable filesystem
  enumeration supplied by the host, HTTP protocol, secure session service,
  packaged shell assets, and watch/HMR coordination. It consumes renderer
  adapters through a narrow Lab adapter contract rather than embedding Ink
  logic in the server plugin.
- `hydronium/cli` owns `hydronium lab`, `hydronium lab init`, process UX,
  browser opening, diagnostics, and Moonstone orchestration.
- `hydronium/create` may opt new Ink templates into Lab, but additive setup for
  an existing project remains the CLI's `lab init` operation.
- Meteorite owns only the generic dev-extension and single-owner-service
  primitives required by the plugin.

## Architecture checkpoint (2026-09-21)

The decoupling slice is implemented and intentionally stops short of inventing
Meteorite lifecycle primitives that do not exist yet:

- `hydronium/lab` owns the host-neutral story/discovery model, the versioned
  browser host contract, and the shared Workbench shell/assets.
- `hydronium/lab-cli` is a standalone Clingy executable with shell completion,
  portable containment-preserving enumeration, and an explicit adapter
  protocol. It performs no ambient plugin scanning.
- `hydronium/meteorite` implements that adapter, owns route registration via
  `lab.mount`, supports custom mount/config paths, and injects exact asset and
  transport URLs into the shell.
- `hydronium/ink-lab` is a renderer layer over the shared Workbench. Its
  virtual terminal, terminal controls, and renderer preferences remain
  specific to Ink.
- `hydronium lab` remains a compatibility delegate. Lab libraries/host adapters
  are development dependencies; launcher/server executables are tool
  dependencies.

The following are still forward TDs and are not implied by the current mount
adapter:

- [ ] Add `meteorite.dev-extension.v1` with collision-checked routes/assets,
  owned watches, startup/shutdown hooks, structured dev events, and one-time
  teardown.
- [ ] Move Lab session ownership from the current single-owner hybrid profile
  into a general supervised Meteorite service primitive with explicit queue,
  cap, TTL, and shutdown contracts.
- [ ] Emit fingerprinted Lab assets through a manifest-addressed Ballad closure
  rather than resolving exact package files at request time.
- [ ] Complete startup-token/cookie/CSRF security and explicit remote-bind
  acknowledgement before supporting non-loopback use.
- [ ] Make `lab init` transactional and refusal-safe for an existing conflicting
  script; add the optional starter story only when the project has none.

Keep the current explicit API working:

```lua
local runtime = require("hydronium_ink_lab").new(require("stories"))
runtime:request({ op = "catalog" })
```

That is the portable escape hatch for tests, custom HTTP servers, embedded
runtimes, and projects which do not use Meteorite.

## Story convention

### Discovery

The default config is equivalent to:

```lua
-- hydronium.lab.lua (optional)
return {
  roots = { "src" },
  include = { "**/*.stories.lua", "**/*.stories.luax" },
  exclude = { ".moonstone/**", ".ballad/**", ".meteorite/**", "dist/**", "vendor/**" },
  adapter = "ink",
}
```

The configuration accepts project-relative roots and portable `/`-separated
patterns only. Absolute paths, `..`, NUL/newlines, and symlink escapes are
rejected. Enumeration comes from Meteorite's host filesystem API, not `find`,
shell globs, or `io.popen`. Results are normalized and bytewise sorted before
loading so catalog order is stable on every platform.

Story files are a development overlay. They may import ordinary application
modules through the project's declared source topology, but they must not enter
the public client source manifest or a production Ballad closure merely because
they are colocated under `src`. The Lab inventory records them as private,
`target = "lab"` inputs. Production packaging tests must prove that no story,
Lab route, token, or Lab asset is shipped.

`.stories.luax` is compiled by the existing Hydronium LUAX compiler and uses the
same module ids, source maps, refresh transform, and dependency graph as the
rest of the project. `.stories.lua` is loaded as Lua. A new ad-hoc transform or
story-only module loader is out of scope.

### Canonical authoring shape

Add `lab.collection` for convention-based files:

```lua
local lab = require("hydronium_lab")
local Status = require("app.components.Status")

return lab.collection({
  title = "Components/Status",
  component = Status,
  controls = {
    state = { type = "select", options = { "healthy", "degraded", "down" } },
    label = { type = "text" },
  },
  stories = {
    default = { args = { state = "healthy", label = "api" } },
    degraded = {
      title = "Degraded",
      args = { state = "degraded", label = "payments" },
      sizes = { { name = "compact", columns = 40, rows = 12 } },
    },
  },
})
```

The file stem plus story key supplies the stable id. For
`src/components/Status.stories.luax`, the examples above become
`components/status--default` and `components/status--degraded`. The display
title is independent of the id, so reorganizing navigation text does not break
deep links or snapshots. A story may declare an explicit id when stability
across a source move matters.

`lab.collection` is additive. Convention loading also accepts the existing
`lab.story` and `lab.registry` values, but those retain their required explicit
ids. Arbitrary export tables and executable global registration are rejected;
one module has one returned Lab value.

Controls initially support JSON-shaped `text`, `number`, `boolean`, `select`,
and `color` values. Inference covers string/number/boolean defaults, while
select options, ranges, labels, and descriptions are explicit. Functions,
userdata, metatables, cyclic tables, and non-string object keys fail with a
source-located diagnostic rather than silently disappearing across HTTP.

### Collision and ordering rules

- Normalize separators to `/`, strip the configured root and
  `.stories.lua`/`.stories.luax`, then slug each path segment for the derived
  id. Never derive ids from absolute paths.
- A `.stories.lua` and `.stories.luax` with the same normalized stem are a
  fatal collision; neither extension wins.
- Story keys must match a portable lowercase slug grammar. Case-folded path,
  module-id, collection-title, and final story-id collisions are reported even
  on case-sensitive filesystems.
- Explicit ids share the same global namespace as derived ids. Duplicate ids
  are fatal and report both source paths and story keys.
- Catalog ordering is group/title, then story title, then id, all with a final
  bytewise-id tie-breaker. Filesystem order and Lua `pairs()` order are never
  observable.
- Adding/removing/renaming a story is a catalog revision. If the selected id
  still exists it remains selected; otherwise the UI chooses the next sibling,
  then previous sibling, then first story, and explains the change in status.

## Meteorite plugin and protocol

The Lab plugin should expose these dev-only routes under one reserved prefix:

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/__hydronium/lab/` | HTML shell and boot configuration |
| `GET` | `/__hydronium/lab/assets/:path*` | Content-hashed package assets |
| `GET` | `/__hydronium/lab/catalog` | Catalog, controls, revision and capabilities |
| `POST` | `/__hydronium/lab/sessions` | Create an isolated renderer session |
| `POST` | `/__hydronium/lab/sessions/:id/operations` | Apply a sequenced operation and return a frame/error |
| `DELETE` | `/__hydronium/lab/sessions/:id` | Close and dispose a session |
| `GET` | `/__hydronium/lab/events` | Client-paced SSE/poll for catalog/HMR/error revisions |

Use protocol envelopes with `protocol`, `session`, `requestId`, `sequence`,
`catalogRevision`, and `moduleRevision`. The server returns structured
`ok`, `frame`, `catalog_changed`, `stale_revision`, `compile_error`,
`render_error`, `session_expired`, and `rate_limited` outcomes. Sequence numbers
make double clicks and out-of-order fetch completions harmless. Protocol and
frame snapshot versions negotiate independently.

The single-owner service holds one `hydronium_ink_lab` runtime per browser
session. It enforces an idle TTL, a hard session cap, bounded request bodies,
bounded operation queues, and deterministic teardown. Closing a tab is best
effort; TTL cleanup is authoritative. Rebuild/restart invalidates server-side
sessions, and the browser transparently creates a new session and reopens the
selected story rather than sending an operation to stale state.

Do not add WebSocket as a prerequisite. Meteorite currently rejects WebSocket
routes, while Hydronium already has a proven client-paced SSE transport. Use
short SSE polls for server-to-browser invalidation and ordinary JSON requests
for operations. Keep the browser client behind the existing asynchronous
`request(message)` seam so another transport can replace this one.

## Security and asset serving

Lab is development software, but localhost is still reachable from hostile web
pages. The first release must enforce all of the following:

- bind to `127.0.0.1` by default; non-loopback `--host` requires an explicit
  acknowledgement and prints a prominent warning;
- generate a cryptographically random startup token, put it in the opened Lab
  URL fragment, exchange it once for a `HttpOnly`, `SameSite=Strict` session
  cookie, and never place it in logs or generated files;
- require same-origin `Origin`/`Host`, the Lab cookie, JSON content type, and a
  per-page CSRF header on mutating routes; emit no permissive CORS headers;
- use opaque random session ids unrelated to story ids or filesystem paths;
- reject path traversal after percent decoding, serve only an emitted asset
  manifest, and never expose project roots, `.moonstone`, source files, or a
  generic directory handler;
- ship CSP (`default-src 'self'`; no remote scripts), `nosniff`, no-referrer,
  no-store on HTML/catalog/API, and immutable caching only for content-hashed
  JS/CSS/font assets;
- redact absolute paths from browser-visible errors by default while retaining
  project-relative source locations and complete terminal diagnostics;
- require an explicit bearer token as well as the startup warning for remote
  binding; multi-user/remote collaboration remains out of scope.

Package assets are emitted by Ballad as a manifest-addressed closure. The
plugin resolves that closure from Moonstone package provenance; it must not
guess a checkout-relative `src/.../client` path. The HTML shell references only
fingerprinted URLs. User CSS may override documented custom properties, but is
loaded as an explicit configured asset rather than arbitrary inline text.

## HMR and failure behavior

Use the existing source topology, source inventory, module graph, HMR host, and
effect policy. The Lab plugin is a coordinator, not another module-replacement
engine.

1. Meteorite watches the private Lab inventory plus the ordinary source
   inventory. A stable revision names every source/metadata input.
2. A changed `.stories.*` file is compiled and evaluated transactionally. A
   successful value produces a new catalog revision; failure preserves the
   last good catalog.
3. A changed imported module is staged through the existing module graph. Safe
   and managed closures replace at the Ink session frame boundary. A restart
   effect boundary produces a typed `restart_required` event and remounts the
   affected story session.
4. Add/delete/rename changes discovery itself. Rescan only configured roots,
   build a complete candidate catalog, validate all collisions, and atomically
   publish it. Never expose a half-built catalog.
5. Browser clients compare revisions. They keep the last good frame under a
   visible stale/error banner until a valid update arrives, then clear the
   banner automatically. Runtime errors belong to one story/session and do not
   remove unrelated stories.

The server terminal shows a concise error with source location and keeps
running. The browser overlay provides summary, project-relative file/line,
component stack when available, expandable details, Retry, and Copy diagnostic.
Transport loss shows Reconnecting without erasing the preview. An empty catalog
shows a copyable `.stories.luax` example and the roots actually searched.

## Browser workbench UX

The canonical Ink frame remains the primary object of attention. The shell must
not parse ANSI or recalculate terminal layout.

Required first-release experience:

- a collapsible story tree grouped by collection title, with fuzzy search,
  recent stories, visible empty results, and `/` to focus search;
- deep links and correct Back/Forward behavior;
- preview toolbar for named size, draggable custom size, color capability,
  zoom, background, reset, and focus state, with dimensions and connection/HMR
  status always legible;
- controls panel generated from the story's control schema, Reset controls,
  per-control validation, and copyable current args;
- interactions panel with running/pass/fail state and deterministic replay;
- keyboard and paste reach the terminal only while its explicitly focusable
  surface is active; Escape returns focus to shell navigation;
- sidebar and controls drawer collapse at narrow widths; every action remains
  reachable without hover and has a visible focus treatment;
- semantic landmarks, labels, live regions for status/error changes, reduced
  motion support, and theme tokens which respect user overrides;
- loading, no-stories, no-search-results, disconnected, expired-session,
  compile-error, render-error, and incompatible-protocol states.

URL state is the shareable source of truth:

```text
/__hydronium/lab/?story=components/status--degraded&size=compact&color=truecolor&args=<canonical-base64url-json>
```

Story, size, capability, and JSON-shaped args go in the URL with canonical key
ordering and omission of defaults. Panel widths, collapsed sections, theme,
zoom, and recent stories are local preferences. Invalid URL state falls back
field-by-field, reports what was ignored, and never prevents the catalog from
opening.

## Generated project changes

`hydronium lab init` is additive, idempotent, and rollback-aware:

1. inspect `moonstone.toml` through `moon manifest export --json`;
2. preflight existing `lab` script and proposed generated files;
3. add missing packages through `moon add --no-sync` with valid Moonstone roles;
4. set `lab = "moon exec --dev hydronium lab"` through
   `moon manifest script set`, refusing to replace a different command;
5. create `hydronium.lab.lua` only when non-default configuration is needed;
6. create `src/App.stories.luax` only when no matching story exists and without
   overwriting any file;
7. run one `moon sync` after all manifest operations.

Before `moon sync`, failure restores the original manifest and removes only
files created by this invocation. A sync failure leaves a coherent pending
state and tells the user to rerun `moon sync`, matching the existing additive
LÖVE setup contract.

New Ink projects may include the packages, script, and one useful story from
the outset. Existing explicit `stories/init.lua` registries keep working and
can be referenced from `hydronium.lab.lua` during migration. No automated
rewrite is necessary.

## Versioning and compatibility

- Introduce `hydronium/meteorite` at `0.1.0` and keep the Meteorite dev
  extension API versioned separately (`meteorite.dev-extension.v1`).
- Bump `hydronium/lab` and `hydronium/ink-lab` minor versions for additive
  collection/discovery/control/protocol APIs. Do not change existing
  `lab.story`, `lab.registry`, or `inkLab.new` behavior.
- Catalog, operation protocol, and frame snapshot each carry an integer version
  and advertised capability list. Reject incompatible majors with a useful
  upgrade message; ignore unknown additive fields.
- Pin compatible package constraints in generated projects and test the oldest
  supported Meteorite against the newest compatible Hydronium plugin.
- Treat the `.stories.*` suffix, derived-id algorithm, URL encoding, collision
  rules, and asset prefix as public contracts once released.

## Phased delivery checklist

### Phase 0 — prove the Meteorite seam

- [ ] Specify and implement `meteorite.dev-extension.v1` separately from graph
  plugins.
- [ ] Add the supervised single-owner Lua service and prove session affinity
  across concurrent HTTP workers.
- [ ] Add extension route/asset/watch collision validation and structured dev
  events.
- [ ] Prove TERM, KILL/parent death, build failure, and restart leave no child or
  session process behind.

Exit criterion: a fixture increments independent state for two browser session
ids across requests deliberately distributed over multiple HTTP workers.

### Phase 1 — conventions without a server dependency

- [ ] Add `lab.collection`, normalized controls, source locations, and adapter
  metadata to `hydronium/lab`.
- [ ] Add the pure discovery planner and all path/id/collision rules.
- [ ] Add Lua and LUAX convention loading against an injected path inventory.
- [ ] Emit a private, revisioned Lab inventory and exclude it from production
  source/public/package manifests.
- [ ] Preserve explicit registries as a supported input.

Exit criterion: a host can provide an unordered path list and receive the same
validated catalog and ids on macOS, Linux, and Windows fixtures.

### Phase 2 — Meteorite host and secure protocol

- [ ] Create `hydronium/meteorite` and register the Lab dev extension.
- [ ] Serve the fingerprinted shell closure and implement catalog, session,
  operation, teardown, and event routes.
- [ ] Add token exchange, same-origin/CSRF checks, caps, TTL cleanup, revision
  checks, path hardening, headers, and remote-bind guardrails.
- [ ] Route every Ink session through the single-owner service.
- [ ] Reuse the existing client-paced SSE transport strategy.

Exit criterion: `hydronium lab` opens two isolated interactive sessions, and a
cross-origin page cannot read the catalog or mutate either one.

### Phase 3 — authoring loop and workbench UX

- [ ] Implement tree navigation, fuzzy search, deep links, Back/Forward, recent
  stories, responsive panels, and keyboard navigation.
- [ ] Implement controls, canonical URL args, reset/copy, interaction results,
  and toolbar preferences.
- [ ] Connect topology-backed HMR for story files and imported source modules.
- [ ] Implement last-good-frame error overlays, reconnect/session-recovery, and
  every empty/error state listed above.
- [ ] Keep canonical cell rendering and verify no ANSI/layout duplicate enters
  the browser shell.

Exit criterion: edit a component, edit a story, add a story, remove the active
story, introduce/fix a syntax error, resize, navigate history, and lose/recover
the server without manually refreshing the browser.

### Phase 4 — installation and release closure

- [ ] Add `hydronium lab` and idempotent `hydronium lab init` to the CLI.
- [ ] Add optional Lab scaffolding to the Ink create template.
- [ ] Build/publish all package artifacts and verify their Ballad closures.
- [ ] Write package-first registry READMEs and one end-to-end documentation
  page; keep maintainer details in repository docs.
- [ ] Migrate `PENDING_INK_LAB.md` deferred discovery/security items to done or
  link them to explicit later work.

Exit criterion: in a freshly scaffolded and an existing Ink project, the only
daily command is `moon run lab`, with no hand-written route or asset wiring.

### Phase 5 — parity beyond the first release

- [ ] Add browser-driven screenshot baselines and update/review workflow.
- [ ] Add accessibility audit automation for the shell.
- [ ] Add docs/notes panels and optional source links once source disclosure is
  explicitly enabled.
- [ ] Add CI catalog build and interaction runner (`hydronium lab test`) without
  requiring a visible browser.
- [ ] Evaluate a combined `hydronium dev --lab` only after the dedicated server
  is stable.

## Verification matrix

- Unit: pattern normalization, sorted discovery, derived ids, all collision
  classes, JSON-shaped args, control validation, canonical URL encoding, and
  catalog fallback selection.
- LUAX: `.stories.luax` compilation/source maps and imports use the same compiler
  and source topology as application modules.
- HMR: hot, managed, remount/restart, add/remove/rename, failed compile,
  failed render, stale revision, and recovery preserve the documented last-good
  state.
- Meteorite: multi-worker session affinity, plugin collision diagnostics,
  startup/restart/shutdown cleanup, bounded queues, TTL/cap eviction, SSE
  reconnect, and no release-mode routes.
- Security: hostile Origin, missing/invalid token, CSRF, malformed JSON,
  traversal including percent-encoded forms, oversized bodies, guessed session
  ids, remote bind without acknowledgement, and secret/path redaction.
- Browser: mouse and keyboard navigation, terminal focus/input/paste, resize,
  controls, URL history, narrow viewport, reduced motion, semantic roles/live
  regions, and every empty/error/reconnect state.
- Packaging: installed-package paths rather than checkout paths, content hashes
  and MIME types, offline startup after `moon sync`, and absence of Lab/story
  files from production Ballad output.
- Additive setup: fresh project, existing Moonstone project, existing matching
  setup, script conflict, file conflict, command failure rollback, sync failure
  pending state, and paths containing spaces.

The work is complete when a user can add one `*.stories.luax` beside a
component, run `moon run lab`, and get a secure, searchable, deep-linkable,
resizable, HMR-preserving Ink workbench without knowing how Meteorite routes,
assets, source inventories, or Lab transports are wired.
