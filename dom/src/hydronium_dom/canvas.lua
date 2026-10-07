--[[
  hydronium_dom.canvas -- the Canvas API from Lua components.

  Canvas elements and their contexts are ordinary host references in the
  browser, so drawing is plain method calls:

    local canvas = require("hydronium_dom.canvas")
    local ref = H.createRef()            ---@type Ref<HTMLCanvasElement>
    canvas.frame(function(t)
      local ctx = canvas.context(ref)    -- CanvasRenderingContext2D
      if not ctx then return end
      ctx:clearRect(0, 0, 300, 150)
      ctx.fillStyle = "tomato"
      ctx:fillRect(20 + 40 * math.sin(t / 500), 20, 80, 80)
    end)
    return <d.canvas ref={ref} width={300} height={150} />

  This module adds what host references cannot do (constructors, frame loops
  that stop with the component, image loading, device pixel ratio, resize
  observation) through the `canvas@1` host capability. On the server there is
  no canvas: every helper returns nil and frame/observe do nothing, so a
  component renders its <canvas> markup and starts drawing once hydrated.

  Types: dom/types/dom/canvas.d.lua (the MDN Canvas API: HTMLCanvasElement,
  CanvasRenderingContext2D, Path2D, ImageData, CanvasGradient, CanvasPattern,
  TextMetrics, DOMMatrix, ImageBitmap, OffscreenCanvas).
--]]

local hosts = require("hydronium.runtime.hosts")
local scope = require("hydronium.core.scope")

local M = {}

---@return table|nil
local function host()
  return hosts.get("canvas", 1)
end

--- The element behind a ref (or the element itself).
---@param target HTMLCanvasElement|OffscreenCanvas|Ref<HTMLCanvasElement>|nil
---@return HTMLCanvasElement|OffscreenCanvas|nil
local function element(target)
  -- A ref (H.createRef) is a plain table; elements are host references.
  if type(target) == "table" and getmetatable(target) == nil then
    ---@cast target Ref<HTMLCanvasElement>
    return target.current
  end
  return target
end

--- True in a browser with the canvas capability installed.
---@return boolean
function M.available()
  return host() ~= nil
end

--- `canvas:getContext(kind, options)`, from an element or a ref.
---@overload fun(target: HTMLCanvasElement|Ref<HTMLCanvasElement>|nil, kind?: "2d", options?: CanvasRenderingContext2DSettings): CanvasRenderingContext2D|nil
---@overload fun(target: HTMLCanvasElement|Ref<HTMLCanvasElement>|nil, kind: "bitmaprenderer", options?: table): ImageBitmapRenderingContext|nil
---@overload fun(target: HTMLCanvasElement|Ref<HTMLCanvasElement>|nil, kind: "webgl"|"webgl2", options?: table): WebGLContext|nil
---@param target HTMLCanvasElement|OffscreenCanvas|Ref<HTMLCanvasElement>|nil
---@param kind? CanvasContextKind
---@param options? table
---@return any
function M.context(target, kind, options)
  local el = element(target)
  if not el or not host() then return nil end
  if options ~= nil then return el:getContext(kind or "2d", options) end
  return el:getContext(kind or "2d")
end

--- `new Path2D(svgPathData?)` (or a copy of another path).
---@param init? string|Path2D
---@return Path2D|nil
function M.path(init)
  local h = host()
  return h and h.path(init) or nil
end

--- `new ImageData(width, height)`, or from RGBA bytes (a 0..255 array).
---@overload fun(width: integer, height: integer): ImageData|nil
---@param bytes integer[]
---@param width integer
---@param height? integer
---@return ImageData|nil
function M.image_data(bytes, width, height)
  local h = host()
  if not h then return nil end
  if type(bytes) == "number" then return h.image_data(bytes, width) end
  return h.image_data_from(bytes, width, height)
end

--- `new DOMMatrix(init?)`: a CSS transform string or 6 / 16 numbers.
---@param init? string|number[]
---@return DOMMatrix|nil
function M.matrix(init)
  local h = host()
  return h and h.matrix(init) or nil
end

--- `new OffscreenCanvas(width, height)`.
---@param width integer
---@param height integer
---@return OffscreenCanvas|nil
function M.offscreen(width, height)
  local h = host()
  return h and h.offscreen(width, height) or nil
end

--- Loads and decodes an image for `ctx:drawImage`. Suspends the calling Lua
--- task until it is ready (call it from an event handler or a frame).
---@param src string
---@param crossOrigin? "anonymous"|"use-credentials"
---@return HTMLImageElement|nil
function M.load_image(src, crossOrigin)
  local h = host()
  return h and h.load_image(src, crossOrigin) or nil
end

--- `createImageBitmap(source, ...)`.
---@param source HTMLImageElement|HTMLCanvasElement|OffscreenCanvas|ImageData|ImageBitmap
---@return ImageBitmap|nil
function M.bitmap(source, ...)
  local h = host()
  return h and h.bitmap(source, ...) or nil
end

--- `window.devicePixelRatio` (1 on the server).
---@return number
function M.pixel_ratio()
  local h = host()
  return h and h.device_pixel_ratio() or 1
end

--- Calls `draw(timeMs, deltaMs)` every animation frame until it returns
--- false or the returned stop function is called. Inside a component it also
--- stops when the component unmounts. Does nothing on the server.
---@param draw fun(time: number, delta: number): boolean|nil
---@return fun() stop
function M.frame(draw)
  local h = host()
  if not h then return function() end end
  local stop = h.frame_loop(draw)
  scope.onCleanup(stop)
  return stop
end

--- Calls `resized(width, height)` (CSS pixels) whenever the element's box
--- changes, and once at start. Stops with the component, or when the
--- returned function is called.
---@param target HTMLCanvasElement|Ref<HTMLCanvasElement>
---@param resized fun(width: number, height: number)
---@return fun() stop
function M.observe_resize(target, resized)
  local h, el = host(), element(target)
  if not h or not el then return function() end end
  local stop = h.observe_resize(el, resized)
  scope.onCleanup(stop)
  return stop
end

--- Sizes the canvas backing store for the display: `width`/`height` become
--- the CSS size times the device pixel ratio, and the 2D context is scaled
--- so drawing code keeps using CSS pixels. Returns the context and the CSS
--- size, or nil on the server.
---@param target HTMLCanvasElement|Ref<HTMLCanvasElement>
---@param cssWidth? number defaults to the element's clientWidth
---@param cssHeight? number defaults to the element's clientHeight
---@return CanvasRenderingContext2D|nil ctx, number|nil width, number|nil height
function M.fit(target, cssWidth, cssHeight)
  local el = element(target) --[[@as HTMLCanvasElement?]]
  if not el or not host() then return nil end
  local ratio = M.pixel_ratio()
  local w = cssWidth or el.clientWidth
  local h = cssHeight or el.clientHeight
  el.width = math.floor(w * ratio + 0.5)
  el.height = math.floor(h * ratio + 0.5)
  local ctx = el:getContext("2d")
  if ctx then ctx:setTransform(ratio, 0, 0, ratio, 0, 0) end
  return ctx, w, h
end

return M
