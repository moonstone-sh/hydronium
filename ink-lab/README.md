# Hydronium Ink Lab

Ink Lab combines `hydronium/lab` stories with Ink's native terminal host and
an xterm.js browser preview. Responses carry the host's actual ANSI output;
xterm forwards keyboard and paste bytes to the same Ink session. Canonical
styled snapshots and compact full/delta frames remain available for tests
and tooling. Explicit focus metadata connects field navigation to canvas
scrolling, while native inline viewports handle short terminal presets.

The browser bundle and stylesheet are shipped in the Lua package, so projects
need no CDN or JavaScript package install to open Lab. To rebuild them:

```sh
cd ink-lab
bun install --frozen-lockfile
bun run build
bun run check:ansi
```

Edit `client/controller.js`, `client/ink-source.css`, or
`scripts/xterm-entry.js`, then rebuild. `client/virtual_terminal.js` and
`client/ink.css` are generated assets. Zoom changes xterm's font size so
text and mouse selection retain their cell coordinates.

The Lua implementation lives under `src/hydronium_ink_lab`. Focused coverage:

```sh
moon exec -- luajit tests/runner.lua tests/host/ink_session_spec.lua tests/host/ink_lab_spec.lua tests/host/ink_lab_frame_spec.lua
bun test tests/client/ink_lab.test.mjs
```

See [`../docs/HYDRONIUM_INK_LAB.md`](../docs/HYDRONIUM_INK_LAB.md) for the
architecture and protocol. Build the registry artifact with `moon run package`.


The size menu groups story-specific dimensions (defaulting to 80×24), saved
user dimensions, and standard terminal presets: 80×24, 80×40, 100×30, 120×40,
and 160×50. Edit the zero-padded column and row counts directly; Enter or blur
commits, Escape cancels. Custom dimensions are saved per project.

Drag empty canvas space, enable the hand tool to drag over the preview, or
hold Space while the canvas is focused. Touch drags work over the preview;
trackpad scrolling pans and a pinch gesture zooms. Pointer cancellation ends
the drag cleanly. Ordinary mouse dragging on the terminal still selects text.

Wheel over a short inline preview scrolls the form; wheel over the canvas
pans it. Tab, Enter, arrows, j/k outside text fields, and section shortcuts
restore the focused control to view after manual scrolling.

Live controls, virtual playback and optional project-owned workbenches are documented in [Lab controls](../docs/LAB_CONTROLS.md).
