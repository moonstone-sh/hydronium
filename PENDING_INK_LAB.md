# Hydronium Ink Lab

The Lab is a Hydronium-native component workbench. Ink remains the renderer;
the Lab drives an Ink app without a TTY and presents its canonical cell frame
in a browser. ANSI text is never used as the interchange format.

## Delivery checklist

- [x] Extract a deterministic, in-memory Ink session with explicit mount,
  input, paste, resize, clock-step, frame, cursor, exit, and teardown APIs.
- [x] Keep the blocking terminal renderer and the Lab on the same session
  semantics so hooks do not gain a second implementation.
- [x] Define a small story contract with stable ids, args, terminal sizes,
  color capability, and scripted interactions. Reject ambiguous registries.
- [x] Add frame snapshot serialization that preserves grapheme cells, palette
  colors, absolute sRGB colors, text attributes, cursor state, and dimensions.
- [x] Ship a browser virtual terminal that renders frame cells directly,
  supports live resizing, keyboard and paste input, and capability selection.
- [x] Provide a Hydronium DOM Lab shell so a normal Hydronium client entry can
  host the terminal surface and story controls without Storybook.
- [x] Add focused Lua and browser tests for session interaction, story
  validation, frame serialization, resize, styles, and input forwarding.
- [x] Document package boundaries, authoring examples, transport expectations,
  and the intentionally deferred pieces.

## Package boundary

`hydronium/lab` owns host-neutral story metadata and registry rules.
`hydronium/ink-lab` owns Ink sessions, frame snapshots, the DOM shell, and the
browser cell-grid renderer. `hydronium/ink` owns terminal layout and behavior.

The first browser transport is deliberately injectable: an application may
connect it to HTTP, WebSocket, Meteorite, or an in-page Lua VM. The Lab protocol
is plain request/response data and does not couple Ink to one server framework.

## Deferred after the first complete slice

- Filesystem convention-based story discovery. Lua cannot portably enumerate
  modules, so the first version uses explicit `lab.registry({...})` composition.
- Screenshot baselines and a browser automation runner.
- Multi-session collaboration and remote authentication.
- Running Yoga itself in browser WASM. Frames are currently produced by the
  native Ink session and consumed by the browser.
