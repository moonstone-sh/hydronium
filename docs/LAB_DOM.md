# DOM and mixed renderer Lab

Lab uses one catalog and workbench for DOM and Ink stories. Each selected story runs in an isolated preview: a browser Lua VM for DOM, or a native terminal session for Ink. Stories using the same renderer share a preview adapter; switching stories replaces the story component and its effects. Switching renderer prepares the next preview before disposing the previous adapter. This is one selected preview, rather than two simultaneous render surfaces.

Install and start the development tools:

```sh
moon add --tool hydronium/lab-cli
moon exec -- hydronium-lab init --renderer mixed
moon run lab
```

Use `--renderer dom` for a DOM project. Existing untyped stories default to Ink; the DOM project default changes them to DOM. In a mixed project, declare the renderer on each collection or story:

```lua
local lab = require("hydronium_lab")
return lab.collection({
  renderer = "dom",
  component = require("Button"),
  args = { label = "Hello" },
  controls = { label = { type = "text" } },
  stories = { default = {} },
})
```

An Ink story declares `renderer = "ink"`. A variant can override its collection's renderer. Keep renderer-specific imports in separate story modules: a DOM module is evaluated in the browser and cannot import native Ink/FFI modules. Shared pure Lua modules can be used by both renderers. Ordinary `.luax` component imports are compiled automatically.

The workbench controls update story args without remounting the component. DOM components can also use `lab.useStoryArgs()`. `controls_view` and `ControlsOutlet` let you supply ordinary inputs with `data-lab-control="label"`; `DefaultControls` is an opt-in convenience. The outer workbench renders these outlets on the server; arbitrary Lua click handlers there are not browser-hydrated. Interactive component logic belongs inside the DOM preview.

Configure compiled project CSS, including Tailwind output:

```lua
-- hydronium.lab.lua
return {
  renderer = "mixed",
  roots = { "src" },
  module_roots = { "src" },
  styles = { "public/app.css" },
}
```

Lab serves these project-relative files inside the DOM preview and reloads them when their contents change. Run your CSS compiler/watch command separately. DOM component updates use Hydronium's component-family HMR; compatible development-compiled signal declarations preserve state. Compilation errors retain the last working preview. Newly introduced framework dependencies may require restarting the preview. Module bodies should keep external side effects in component-owned effects with cleanup; the development closure declares project modules eligible for hot evaluation.

Ink keeps its virtual playback controls. DOM uses the real browser clock: the Lab does not freeze arbitrary browser timers or animation frames. Restart resets the selected story; switching renderer creates a new preview. Zoom, canvas centering, and drag panning belong to the shared workbench.

To edit the shell locally:

```sh
moon exec -- hydronium-lab customize
# Or copy the complete shared shell:
moon exec -- hydronium-lab customize --copy-shell
```

DOM and mixed configurations use `hydronium_lab.dom_document.Document`; Ink uses its existing document. The generated `.lab/Workbench.luax` is ordinary project code. The underlying DOM preview controller is available as `hydronium_lab.dom_preview`.

## Terminal size and playback in the mixed Lab

Ink stories get a size preset picker (story `sizes`, then the standard sizes, then your saved sizes) and a **Size** menu with custom columns and rows; **Save size** keeps the current size as a preset for the project (`terminalSizes` in the Lab preferences). The timeline (Restart, −1, Play/Pause, Step, frame and time) follows the Ink preview's virtual playback: the preview reports its state about ten times a second.

The Lab polls the catalog. It re-selects the current story only when the story's definition changed (compared with key-order-independent JSON), so editing a control keeps focus; in release builds every poll is answered by a fresh Lua state whose table order differs.

## Ink stories in the browser

By default an Ink story runs as a session on the Lab host (`POST /lab/sessions`), which needs the native Yoga library and keeps one Lua session per viewer. A host can run those sessions in the viewer's browser instead: set `ink_transport` in the Lab config to a same-origin module URL (a path, optionally with a query for cache busting).

```lua
-- .hydronium/lab/config.lua
return { renderer = "mixed", paths = { ... }, ink_transport = "/assets/ink-lab-transport.js?v=3f2a" }
```

The Ink preview imports that module and calls its `createInkTransport({ basePath, catalogUrl })`, which returns `{ createSession(), operation(session, envelope), close(session) }` with the same JSON shapes as the HTTP endpoints. `GET <base>/ink/modules` returns the sources it needs: the Ink stories (registered as `hydronium_lab.ink_stories`), their project modules, and the Ink and Ink Lab runtime, without the native modules (`hydronium_ink.yoga_ffi`, `tty_ffi`, `clock`, `terminal_background`, `render`), which the transport provides. A transport typically runs `require("hydronium_ink_lab.service").new(require("hydronium_lab.ink_stories"), {...})` in a Web Worker on lua-wasm with Yoga compiled to WebAssembly. The catalog stays on the host.

The catalog's `generation` is the stories' content fingerprint, so a host that gives each request a fresh Lua state (Meteorite release builds) reports the same catalog on every poll.

## DOM viewport and color inspection

Declare `viewports = { { name = "Card", width = 480, height = 640 } }` on a story or collection. The picker groups Story-specific, Standard, then User-defined sizes; editable pixel inputs and Save viewport add local project presets. Ink keeps cell dimensions and ANSI/truecolor in its own toolbar.

DOM color targets are sRGB, Display P3, and Rec. 2020 where CSS parsing supports them. The target is exposed as `data-lab-color-space`, `--lab-color-space`, and the reactive accessor from `require("hydronium_lab.dom_preview").useEnvironment()`. Components can use it to choose their own authored colors. This does not convert every CSS color or override `color-gamut` media queries. The toolbar reports the browser/display gamut separately. Display P3 is the CSS web color space; DCI-P3 is a different cinema encoding.

Protanopia, deuteranopia, tritanopia, and grayscale previews apply a linear RGB SVG color matrix inside the DOM frame. They are inspection approximations; wide gamut content is processed through the filter color pipeline. The simulations do not change stored colors or outer workbench controls.

There is no hardware bit-depth picker: browser APIs do not expose a reliable universal maximum. `screen.colorDepth`/`pixelDepth` are specified to return 24 for compatibility and cannot verify a 10-bit display pipeline. See the [CSSOM View specification](https://www.w3.org/TR/cssom-view/) and [color-gamut media feature](https://www.w3.org/TR/mediaqueries-4/#color-gamut).

Canvas rulers use pixels for DOM and columns/rows for Ink. Zero defaults to the story's top-left; resizing keeps that corner stationary and ruler spacing independent of the preview box. Preferences → Canvas navigation can instead use the canvas top-left or center as zero, saved per project. Rulers stay in the canvas chrome while their marks follow viewport pan and zoom. Dragging gently snaps to the canvas center and edges; Alt bypasses snapping. Trackpad panning settles onto nearby guides after the gesture. Toggle rulers and snapping in Preferences → Canvas navigation; choices are saved per project. Ink zoom scales the world layer without changing terminal font metrics or logical dimensions.

Drag from the top ruler for a horizontal guide, the left ruler for a vertical guide, or their corner for both. Placed guides use canvas coordinates and stay fixed while you move the story viewport; pixel and terminal-cell guides are stored separately for each project. Drag guides to reposition them. Alt-click, Ctrl/Command-click, Delete/Backspace on a focused guide, or drag back to the ruler corner to remove one. Select a guide and use Preferences → Guide color to recolor it. New guides use the last chosen color. Configure center, edge, and placed-guide snapping independently and adjust its screen-pixel distance. Temporary alignment indicators disappear at the end of the gesture.

Playback and story controls live in the selected-story sidebar, leaving the canvas at full height. The story catalog and inspector scroll independently. R toggles rulers and H toggles canvas hints when focus is in Lab chrome; neither shortcut intercepts text fields or the running story. Preferences contains both visibility toggles.
