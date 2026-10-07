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
  `ImageBitmapRenderingContext`. WebGL and WebGPU are typed too (below).
- **`hydronium_dom.canvas`** adds what host references cannot do:
  `context(target, kind?, options?)`, `path(svg?)`, `image_data(bytes|w, w|h, h?)`,
  `matrix(init?)`, `offscreen(w, h)`, `load_image(src)` (suspends until
  decoded), `bitmap(source)`, `pixel_ratio()`, `frame(draw)`,
  `observe_resize(target, fn)`, `fit(target, w?, h?)`, `typed(kind, source)`,
  `webgpu()`. `target` is an element or a ref.
- **`canvas@1`** is the host capability behind it
  (`js/packages/dom-client/src/canvas_bridge.js`), installed by `mount()` next
  to `dom@1`; `hydronium_dom.host.canvas_contract` declares it to the bundler.
- **On the server** there is no canvas: helpers return nil and `frame` /
  `observe_resize` do nothing, so a component renders `<canvas>` and starts
  drawing once hydrated.

## WebGL and WebGPU

`webgl.d.lua` (WebGL 1 and 2) and `webgpu.d.lua` are generated from the
specifications' WebIDL by `dom/webidl/generate.mjs` (IDL vendored from
`@webref/idl`, see `dom/webidl/idl/SOURCE.md`); a client test fails when they
are stale. Interfaces are classes (methods take `self`: call them with `:`),
constants and attributes are fields, dictionaries are table shapes and enums
string unions, so descriptors are checked field by field.

```lua
local gl = canvas.context(ref, "webgl2")          -- WebGL2RenderingContext|nil
local shader = assert(gl:createShader(gl.VERTEX_SHADER))  -- nil after context loss
gl:bufferData(gl.ARRAY_BUFFER, canvas.typed("Float32Array", { 0, 0.5, -0.5, -0.5, 0.5, -0.5 }), gl.STATIC_DRAW)

local webgpu = canvas.webgpu()                     -- nil without WebGPU (or on the server)
local device = webgpu.gpu:requestAdapter():requestDevice()   -- each call suspends until resolved
local context = canvas.context(ref, "webgpu")      -- GPUCanvasContext|nil
context:configure({ device = device, format = webgpu.gpu:getPreferredCanvasFormat() })
local buffer = device:createBuffer({ size = 24, usage = webgpu.BufferUsage.VERTEX | webgpu.BufferUsage.COPY_DST })
local pass = encoder:beginRenderPass({ colorAttachments = { { view = context:getCurrentTexture():createView(), loadOp = "clear", storeOp = "store" } } })
pass["end"](pass)                                  -- `end` is a Lua keyword
```

- A host call returning a promise suspends the calling Lua task, so
  `requestAdapter()` returns the adapter. A promise held in a property (such
  as `device.lost`) is a `HostPromise`, not awaited.
- Buffers take typed arrays, which Lua cannot construct: `canvas.typed(kind,
  source)` builds one from a Lua sequence or a length; index it from 0
  (`typed_arrays.d.lua`). Lists such as `uniform4fv` values also accept
  plain Lua sequences.
- WebGL contexts have about 450 members, more than LuaLS's default
  `completion.maxSuggestCount` (100), above which it withholds member
  completion until a prefix is typed. Hydronium's playground and VS Code
  extension raise it to 1000; set `"completion.maxSuggestCount": 1000` in
  `.luarc.json` elsewhere.
- `typed` and `webgpu` are optional `canvas@1` functions (the client in hydronium/dom 0.3.9 and later).

Tests: `tests/host/canvas_spec.lua`, `tests/client/canvas_bridge.test.mjs`,
`js/tests/canvas.browser.test.mjs` (pixels read back in Chromium, Firefox and
WebKit), `tests/client/webidl_types.test.mjs`, and the browser LuaLS gate
(`luax/editor/luals-web/test.mjs`: WebGL2 and WebGPU completion).
