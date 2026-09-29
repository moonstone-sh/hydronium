# Live controls and playback

Lab works with defaults: declare `args` and `controls` in an ordinary
`.stories.lua` or `.stories.luax` file and the browser workbench creates fields.
No custom shell or extra loader calls are required.

```lua
local lab = require("hydronium_lab")
local H = require("hydronium")
local ink = require("hydronium_ink")

return lab.collection({
  title = "Examples/Label",
  component = function()
    local args = lab.useStoryArgs()
    return function() return H.h(ink.Text, nil, args().label) end
  end,
  controls = {
    label = { type = "text", label = "Label" },
    count = { type = "number", min = 0, max = 20, step = 1 },
    enabled = { type = "boolean" },
    mode = { type = "select", options = {
      { label = "Compact", value = "compact" },
      { label = "Expanded", value = "expanded" },
    } },
  },
  stories = { default = { args = { label = "Hello", count = 1, enabled = true, mode = "compact" } } },
})
```

Editing controls patches the current story's reactive args; it does not reopen
or remount the preview. Component signals, focus and input state survive.
`Reset controls` restores declared story defaults without resetting component
state. A control may provide `default` when its argument is absent.

`lab.useStoryArgs()` returns an args getter, a patch setter and a reset function.
`lab.usePlayback()` returns a getter for `{ nowMs, frame, playing, intervalMs }`.
These hooks require `lab.state.Context.Provider`; the Ink adapter supplies it.
Other renderer adapters can use `lab.state.new(args, controls)` and the same
provider. State contains JSON-shaped values; callbacks/signals stay in
components rather than traveling over JSON transport.

## Virtual playback

The Ink adapter owns virtual time, starting at zero and priming animation
tickers before displaying the first frame. Play advances that timeline; pause
holds it fixed. Inputs, control edits and resizing still work while paused.

- **Step** pauses and advances by the chosen frame interval in milliseconds.
- **Restart** remounts the story at zero, keeps current args, size and color,
  and leaves it paused. It resets component state.
- `labClient.seek(nowMs)` pauses and advances to an exact timestamp.
  Backward seeking is rejected: restart and advance again. This is not a
  recording/replay system and does not reverse arbitrary component effects.

The displayed frame counter counts explicit timeline advances. It is separate
from an individual component's animation frame counter and the transport's
frame sequence. Browser scheduling and virtual frame intervals are also
separate: the chosen interval controls inspection steps, not browser FPS.

Runtime operations are `args`, `resetArgs`, `playback` (`playing`, `intervalMs`),
`advance`, `seek` (`nowMs`) and `restart`. Every emitted frame includes
`lab.args` and `lab.playback` alongside the existing terminal frame protocol.

## Custom controls inside stories

A collection or individual story can declare `controls_view`, an ordinary DOM
component. Keep its inputs bound by argument name:

```luax
local H = require("hydronium")
local lab = require("hydronium_lab")

local function Controls()
  return <div style={{ display = "flex", gap = "12px" }}>
    <label>Label <input data-lab-control="label" aria-label="Label" /></label>
    <button type="button" data-lab-reset-args>Reset</button>
  </div>
end

return lab.collection({
  component = require("components.Label"),
  controls = { label = { type = "text" } },
  controls_view = Controls,
  stories = { default = { args = { label = "Hello" } } },
})
```

The browser shows the selected story's custom outlet instead of generated
fields. The same schema validates both. Custom checkbox/select inputs use
`change`; text/number inputs use `input`. Custom selects use option values
matching the string form of their declared scalar values. Generated selects
also preserve numeric and boolean values.

These DOM views are rendered by the HTTP host. Named input bindings work
without hydrating the shell. Arbitrary Lua event callbacks in a custom
server-rendered control view are not browser callbacks. For additional browser
behavior, use the observable JS store or mount a hydrated DOM view around it.
Reload the page after changing custom shell or outlet markup.

## Optional editable workbench

After `hydronium-lab init`, run:

```sh
moon exec --dev -- hydronium-lab customize
```

This creates `.lab/Workbench.luax`, a small entry importing default components.
Lab discovers it automatically and adds `.lab` to its module search roots. It
never overwrites existing customization. To own the default markup too:

```sh
moon exec --dev -- hydronium-lab customize --copy-shell
```

Run this instead of the small-entry command: it copies the Ink document into
`.lab/Workbench.luax` and shared shell into `.lab/LabChrome.luax`. These files
are project-owned and do not receive automatic upstream markup updates. The
runtime, controller and terminal renderer remain library imports.

Public Lua components:

- `hydronium_lab.workbench`: `Workbench`/`Shell`, `Icon`, `Controls`, `Control`, `Timeline`.
- `hydronium_lab.controls`: `Controls`, `Control`, `Timeline`.
- `hydronium_ink_lab.components`: `Document`, `Shell`, `InkControls`, `InkPreferences`.

The workbench accepts `controls`, `timeline`, `renderer_controls`, `preview`,
`metrics`, `preferences`, and `story_controls` slots. The Ink document forwards
its corresponding overrides and `class`. Keep required named surfaces such as
`data-lab-terminal` when replacing the Ink preview. Existing
`hydronium_ink_lab.dom` remains the default document entry.

An explicit `document = "MyWorkbench"` in `hydronium.lab.lua` overrides the
convention. Add the module's directory to `module_roots`.

The served `workbench.js` exports `createStoryStore` and `bindStoryControls`.
`createInkLab` exposes its store as `client.state`, plus `setArgs`, `play`,
`pause`, `advance`, `seek`, and `restart`. The store has `getSnapshot()`,
`subscribe(callback)` (returns unsubscribe), `setArgs`, `resetArgs`, `play`,
`pause`, `setInterval`, `advance`, `seek`, and `restart`. Subscriptions receive
copies of confirmed state. Empty `Controls` outlets get default fields;
populated outlets keep user markup. Browser operations are serialized.
