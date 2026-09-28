# Hydronium story controls, inspection clock, and DevTools

Draft, 2026-09-28. This proposes APIs; it does not claim they already exist.

## Current implementation

A `.stories.luax` file is ordinary LUAX compiled by `hydronium_luax.loader`, discovered by its suffix. It must return `lab.collection`, `lab.story`, or `lab.registry`; returning only a component is insufficient. Components inside it can use the ordinary setup/render lifecycle, signals and hooks. Hooks must run inside mounted components, not in the collection factory.

`lab.collection` and `lab.story` accept JSON-safe control schemas: text, number, boolean, select and color. Discovery merges collection and variant controls. The catalog exposes these schemas, but Ink Lab currently has no generic controls panel or live args update operation. `Runtime:open` copies args and mounts a new session. Reopening with changed args resets story state. Existing interactions can dispatch to that session but are named commands, not a live controls bridge.

Signals/getters/setters can exist inside the Lua story, but they cannot be sent as JSON args/control metadata across the browser/native boundary. Send serializable values; bind them to signals inside the target session.

Ink sessions already accept `step(nowMs)`. Lab automatically advances them using browser performance time. There is no public pause, seek, or frame-history UI. An external clock is a foundation for inspection, not yet a time-travel debugger.

The LUAX compiler already emits refresh descriptors for recognized setup signal declarations. The old `HYDRONIUM_DEV_HMR_ROADMAP.md` predates that implementation and must not be treated as today's readiness assessment. State preservation remains bounded by the transform's recognition rules and compatible component identity.

## Ownership and boundaries

| Layer | Responsibility |
| --- | --- |
| Hydronium core | Component/scope/signal lifecycle, reconciliation, refresh instrumentation |
| Shared Lab | Stories, args/control schemas, domain control views, inspection clock and interaction history |
| Ink Lab | xterm surface, physical cell dimensions, terminal palette/font/input, terminal-specific inspection |
| Other Lab renderer adapters | Their preview surface and renderer-specific controls |
| DevTools backend and protocol | Root discovery, tree/state snapshots, events, profiling, supported edits |
| DevTools frontend | Components, Signals, Timeline, Errors and HMR panels |

Stories author their own domain controls. Ink Lab must not accumulate diorama, game, audio or other product-specific controllers. Shared Lab mounts those controls in header/sidebar slots. DevTools works with ordinary apps that do not use stories or Lab.

## Story controls API direction

Preserve existing `args` and `controls`. First render schema-driven controls automatically. Add a proposed `args.patch` operation with validation, session/generation identifiers and revision checks. A change updates session-owned signals in a batch; it must not reopen the story or reset unrelated state.

The story receives stable reactive accessors through a proposed story context. For example, `context.args.label()` reads the current value; `context.args.patch({label = 'Hello'})` updates it. A story can pass an accessor as a reactive prop to components that support that convention, or read values during rendering and pass ordinary props. Do not replace a setup-captured props table and assume existing closures become reactive.

Allow custom controls authored as normal Hydronium DOM `.luax` components. A proposed `controlView = {module = 'lab.controls.Diorama', export = 'DioramaControls', slot = 'header'}` identifies the view; its context exposes args, clock, interaction commands, validation and pending/error state. Only module/export identifiers cross the wire, never functions. Shared Lab bundles/loads the browser-safe module closure using the normal LUAX/DOM pipeline.

Co-location of a browser controls export in a native `.stories.luax` module is desirable, but requires export isolation: a browser must not execute top-level native Ink/FFI imports. Initially use a separate normal `.luax` controls view. Add safe same-file exports only once compilation/loading can isolate their dependencies. In-preview Ink controls can already be ordinary Ink components and own local signals.

Acceptance: schema controls and a custom LUAX header both update the same mounted story; local counter state survives edits; stale responses cannot overwrite newer args; invalid values show an actionable error; HMR refreshes both views without duplicate subscriptions.

## Inspection clock and frame navigation

Introduce a session-owned logical clock, separate from profiling's monotonic wall clock. Proposed commands: play, pause, advance by milliseconds, next frame, reset, and select a recorded frame. Frame duration is explicit; frame 42 at 60fps means a defined logical timestamp, not whichever animation tick happens to arrive.

While paused, dimension/color changes, args edits and snapshot requests must not advance logical time. A manual step advances once, flushes work, and returns its frame number/time. Resume rebases elapsed wall time so a long pause causes no jump. Pause automatic polling before sending a manual step; one authoritative clock owns advancement.

Selecting a recorded frame freezes its captured display and metadata. Moving the *live app state* backward is a different capability: reopen from initial args/seed and replay recorded inputs and time advances. Never pass a decreasing timestamp and pretend arbitrary timers, effects or network activity were undone. Deterministic replay requires injected randomness and controlled external effects; otherwise expose recorded-frame inspection only.

Browser CSS animations, audio clocks, network requests and a LÖVE game loop need adapter-specific clock capabilities. A generic clock panel must advertise what it can control.

Acceptance: the diorama freezes at a reproducible frame, steps exactly once, stays frozen during prop/layout inspection, and resumes without a large time jump. Replaying a recorded deterministic input sequence yields the same canonical Ink frame.

## DevTools for any Hydronium app

Build an optional development backend in core with narrow observer hooks for root/component mount, update, dispose, hydration, signal/computed/effect relationships, scheduler commits, errors and family refresh. Begin with a read-only component/scope tree, props, signal values, source locations and HMR events.

Use session/root epochs plus stable component IDs; distinguish a refresh from a remount. Signal debug records should retain setters by opaque IDs inside the runtime. Cross-process inspection serializes bounded values with cycle detection; functions, userdata and inaccessible internals remain opaque. Inspecting a value must not establish reactive dependencies or execute getters/effects just to discover state. Release observers and references when roots/scopes dispose.

Renderer adapters supply host-node mappings, bounds and highlighting. DOM/WASM can use an in-page bridge and DOM overlays. Native Ink can use a local sidecar transport and cell/Yoga bounds. LÖVE and future hosts can expose the same core tree while advertising their additional capabilities. Request-scoped SSR roots are short-lived inspection snapshots, distinct from the persistent hydrated client root.

A proposed versioned protocol advertises capabilities, serves a full snapshot plus sequenced events, and requests resync after gaps. Start with a standalone/in-page frontend so native and browser apps share it. A browser extension is a later packaging option. Keep registration and transports development-only, bounded and isolated per session.

After read-only inspection, add prop/signal editing through registered runtime setters, render-cause tracing, commit/refresh timings, and an HMR/hydration diagnostics panel. Profiling should explain render reasons as well as duration. Generic historical state rewind is not an MVP promise.

The React DevTools frontend/backend separation is a useful reference, not a protocol to copy: https://github.com/react/react/blob/main/packages/react-devtools/OVERVIEW.md

## Delivery sequence

1. Release the existing startup, hydration, refresh, Tailwind, loader, CLI and Ink Lab fixes after artifact consumer gates.
2. Implement shared live args/schema controls and a normal LUAX custom controls view.
3. Add the inspection clock and recorded-frame navigation; use the isolated diorama as the acceptance story.
4. Add optional core observers and a read-only shared DevTools frontend for DOM and Ink.
5. Add state editing, profiling and renderer adapters; only then evaluate a browser extension and deterministic replay.

Clock/controls can ship independently of the complete DevTools interface. DevTools is not a prerequisite for the bug-fix release.
