# Canvas

The Canvas API from Lua components, typed (`dom/types/dom/canvas.d.lua`) and
running in the browser through `hydronium_dom.canvas`.

```lua
local H = require("hydronium.core.element")
local d = require("hydronium_dom").d
local refs = require("hydronium.core.ref")
local canvas = require("hydronium_dom.canvas")

local function Spinner()
  ---@type Ref<HTMLCanvasElement>
  local target = refs.createRef()
  canvas.frame(function(t)                 -- stops when the component unmounts
    local ctx, w, h = canvas.fit(target)   -- device-pixel-ratio sizing
    if not ctx then return end
    ctx:clearRect(0, 0, w, h)
    ctx:save()
    ctx:translate(w / 2, h / 2)
    ctx:rotate(t / 400)
    ctx.fillStyle = "tomato"
    ctx:fillRect(-20, -20, 40, 40)
    ctx:restore()
  end)
  return function() return <d.canvas ref={target} style="width: 120px; height: 120px" /> end
end
```

## What is where

- **Drawing** is plain method calls on host references: the element
  (`HTMLCanvasElement`), its `CanvasRenderingContext2D`, gradients, patterns,
  `TextMetrics`, `ImageData` (`data` is indexed from 0). Types cover MDN's
  Canvas API, including `OffscreenCanvas`, `ImageBitmap` and
  `ImageBitmapRenderingContext`. WebGL contexts are untyped host references.
- **`hydronium_dom.canvas`** adds what host references cannot do:
  `context(target, kind?, options?)`, `path(svg?)`, `image_data(bytes|w, w|h, h?)`,
  `matrix(init?)`, `offscreen(w, h)`, `load_image(src)` (suspends until
  decoded), `bitmap(source)`, `pixel_ratio()`, `frame(draw)`,
  `observe_resize(target, fn)`, `fit(target, w?, h?)`. `target` is an element
  or a ref.
- **`canvas@1`** is the host capability behind it
  (`js/packages/dom-client/src/canvas_bridge.js`), installed by `mount()` next
  to `dom@1`; `hydronium_dom.host.canvas_contract` declares it to the bundler.
- **On the server** there is no canvas: helpers return nil and `frame` /
  `observe_resize` do nothing, so a component renders `<canvas>` and starts
  drawing once hydrated.

Tests: `tests/host/canvas_spec.lua`, `tests/client/canvas_bridge.test.mjs`,
`js/tests/canvas.browser.test.mjs` (pixels read back in Chromium, Firefox and
WebKit).
