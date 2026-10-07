---@meta
--[[
  The Canvas API (MDN "Canvas API"), as Lua sees it in the browser.

  Elements and contexts are host references: properties read and write
  through (`ctx.fillStyle = "red"`), and methods are called with `:`
  (`ctx:fillRect(0, 0, 10, 10)`). Constructors, frame loops and image loading
  come from hydronium_dom.canvas. Lua tables passed where the API takes an
  array (setLineDash, DOMMatrix init) arrive as JS arrays.
--]]

-- ---------------------------------------------------------------- refs

--- An object ref (`H.createRef()`): its element after mount, nil before.
---@class Ref<T>
---@field current T?

-- ---------------------------------------------------------------- element

---@alias CanvasContextKind "2d"|"bitmaprenderer"|"webgl"|"webgl2"

---@class CanvasRenderingContext2DSettings
---@field alpha? boolean
---@field colorSpace? "srgb"|"display-p3"
---@field desynchronized? boolean
---@field willReadFrequently? boolean

--- WebGL is a separate API; contexts are untyped host references.
---@alias WebGLContext table

---@class HTMLCanvasElement : HTMLElement
---@field width integer Backing store width in pixels.
---@field height integer Backing store height in pixels.
---@field clientWidth number CSS width.
---@field clientHeight number CSS height.
---@field getContext (fun(self: HTMLCanvasElement, kind: "2d", options?: CanvasRenderingContext2DSettings): CanvasRenderingContext2D|nil) | (fun(self: HTMLCanvasElement, kind: "bitmaprenderer", options?: table): ImageBitmapRenderingContext|nil) | (fun(self: HTMLCanvasElement, kind: "webgl"|"webgl2", options?: table): WebGLContext|nil)
---@field toDataURL fun(self: HTMLCanvasElement, type?: string, quality?: number): string
---@field toBlob fun(self: HTMLCanvasElement, callback: fun(blob: any), type?: string, quality?: number)
---@field captureStream fun(self: HTMLCanvasElement, frameRate?: number): any MediaStream
---@field transferControlToOffscreen fun(self: HTMLCanvasElement): OffscreenCanvas

---@class HTMLCanvasProps
---@field ref? Ref<HTMLCanvasElement> | (fun(element: HTMLCanvasElement))

-- (src, alt, width, height: html.d.lua)
---@class HTMLImageElement : HTMLElement
---@field naturalWidth integer
---@field naturalHeight integer
---@field complete boolean
---@field crossOrigin string?
---@field decode fun(self: HTMLImageElement): any Promise

-- ---------------------------------------------------------------- 2D context

---@alias CanvasImageSource HTMLImageElement|HTMLCanvasElement|OffscreenCanvas|ImageBitmap|any
---@alias CanvasFillRule "nonzero"|"evenodd"
---@alias CanvasLineCap "butt"|"round"|"square"
---@alias CanvasLineJoin "bevel"|"round"|"miter"
---@alias CanvasTextAlign "start"|"end"|"left"|"right"|"center"
---@alias CanvasTextBaseline "top"|"hanging"|"middle"|"alphabetic"|"ideographic"|"bottom"
---@alias CanvasDirection "ltr"|"rtl"|"inherit"
---@alias CanvasFontKerning "auto"|"normal"|"none"
---@alias CanvasFontStretch "ultra-condensed"|"extra-condensed"|"condensed"|"semi-condensed"|"normal"|"semi-expanded"|"expanded"|"extra-expanded"|"ultra-expanded"
---@alias CanvasFontVariantCaps "normal"|"small-caps"|"all-small-caps"|"petite-caps"|"all-petite-caps"|"unicase"|"titling-caps"
---@alias CanvasTextRendering "auto"|"optimizeSpeed"|"optimizeLegibility"|"geometricPrecision"
---@alias ImageSmoothingQuality "low"|"medium"|"high"
---@alias GlobalCompositeOperation "source-over"|"source-in"|"source-out"|"source-atop"|"destination-over"|"destination-in"|"destination-out"|"destination-atop"|"lighter"|"copy"|"xor"|"multiply"|"screen"|"overlay"|"darken"|"lighten"|"color-dodge"|"color-burn"|"hard-light"|"soft-light"|"difference"|"exclusion"|"hue"|"saturation"|"color"|"luminosity"
---@alias CanvasStyle string|CanvasGradient|CanvasPattern

---@class DOMMatrix2DInit
---@field a? number
---@field b? number
---@field c? number
---@field d? number
---@field e? number
---@field f? number

---@class ImageDataSettings
---@field colorSpace? "srgb"|"display-p3"

---@class CanvasRenderingContext2D
---@field canvas HTMLCanvasElement
--- State
---@field save fun(self: CanvasRenderingContext2D)
---@field restore fun(self: CanvasRenderingContext2D)
---@field reset fun(self: CanvasRenderingContext2D)
---@field isContextLost fun(self: CanvasRenderingContext2D): boolean
---@field getContextAttributes fun(self: CanvasRenderingContext2D): CanvasRenderingContext2DSettings
--- Transformations
---@field scale fun(self: CanvasRenderingContext2D, x: number, y: number)
---@field rotate fun(self: CanvasRenderingContext2D, angle: number)
---@field translate fun(self: CanvasRenderingContext2D, x: number, y: number)
---@field transform fun(self: CanvasRenderingContext2D, a: number, b: number, c: number, d: number, e: number, f: number)
---@field setTransform (fun(self: CanvasRenderingContext2D, a: number, b: number, c: number, d: number, e: number, f: number)) | (fun(self: CanvasRenderingContext2D, matrix?: DOMMatrix|DOMMatrix2DInit))
---@field getTransform fun(self: CanvasRenderingContext2D): DOMMatrix
---@field resetTransform fun(self: CanvasRenderingContext2D)
--- Compositing
---@field globalAlpha number
---@field globalCompositeOperation GlobalCompositeOperation
--- Image smoothing
---@field imageSmoothingEnabled boolean
---@field imageSmoothingQuality ImageSmoothingQuality
--- Fill and stroke styles
---@field fillStyle CanvasStyle
---@field strokeStyle CanvasStyle
---@field createLinearGradient fun(self: CanvasRenderingContext2D, x0: number, y0: number, x1: number, y1: number): CanvasGradient
---@field createRadialGradient fun(self: CanvasRenderingContext2D, x0: number, y0: number, r0: number, x1: number, y1: number, r1: number): CanvasGradient
---@field createConicGradient fun(self: CanvasRenderingContext2D, startAngle: number, x: number, y: number): CanvasGradient
---@field createPattern fun(self: CanvasRenderingContext2D, image: CanvasImageSource, repetition: "repeat"|"repeat-x"|"repeat-y"|"no-repeat"|nil): CanvasPattern|nil
--- Shadows
---@field shadowOffsetX number
---@field shadowOffsetY number
---@field shadowBlur number
---@field shadowColor string
--- Filters
---@field filter string CSS filter, e.g. "blur(4px)".
--- Rectangles
---@field clearRect fun(self: CanvasRenderingContext2D, x: number, y: number, w: number, h: number)
---@field fillRect fun(self: CanvasRenderingContext2D, x: number, y: number, w: number, h: number)
---@field strokeRect fun(self: CanvasRenderingContext2D, x: number, y: number, w: number, h: number)
--- Drawing paths
---@field beginPath fun(self: CanvasRenderingContext2D)
---@field fill (fun(self: CanvasRenderingContext2D, fillRule?: CanvasFillRule)) | (fun(self: CanvasRenderingContext2D, path: Path2D, fillRule?: CanvasFillRule))
---@field stroke (fun(self: CanvasRenderingContext2D)) | (fun(self: CanvasRenderingContext2D, path: Path2D))
---@field clip (fun(self: CanvasRenderingContext2D, fillRule?: CanvasFillRule)) | (fun(self: CanvasRenderingContext2D, path: Path2D, fillRule?: CanvasFillRule))
---@field isPointInPath (fun(self: CanvasRenderingContext2D, x: number, y: number, fillRule?: CanvasFillRule): boolean) | (fun(self: CanvasRenderingContext2D, path: Path2D, x: number, y: number, fillRule?: CanvasFillRule): boolean)
---@field isPointInStroke (fun(self: CanvasRenderingContext2D, x: number, y: number): boolean) | (fun(self: CanvasRenderingContext2D, path: Path2D, x: number, y: number): boolean)
--- Focus
---@field drawFocusIfNeeded (fun(self: CanvasRenderingContext2D, element: HTMLElement)) | (fun(self: CanvasRenderingContext2D, path: Path2D, element: HTMLElement))
--- Text
---@field fillText fun(self: CanvasRenderingContext2D, text: string, x: number, y: number, maxWidth?: number)
---@field strokeText fun(self: CanvasRenderingContext2D, text: string, x: number, y: number, maxWidth?: number)
---@field measureText fun(self: CanvasRenderingContext2D, text: string): TextMetrics
--- Line styles
---@field lineWidth number
---@field lineCap CanvasLineCap
---@field lineJoin CanvasLineJoin
---@field miterLimit number
---@field lineDashOffset number
---@field setLineDash fun(self: CanvasRenderingContext2D, segments: number[])
---@field getLineDash fun(self: CanvasRenderingContext2D): number[]
--- Text styles
---@field font string CSS font shorthand.
---@field textAlign CanvasTextAlign
---@field textBaseline CanvasTextBaseline
---@field direction CanvasDirection
---@field letterSpacing string
---@field wordSpacing string
---@field fontKerning CanvasFontKerning
---@field fontStretch CanvasFontStretch
---@field fontVariantCaps CanvasFontVariantCaps
---@field textRendering CanvasTextRendering
--- Paths (CanvasPath)
---@field closePath fun(self: CanvasRenderingContext2D)
---@field moveTo fun(self: CanvasRenderingContext2D, x: number, y: number)
---@field lineTo fun(self: CanvasRenderingContext2D, x: number, y: number)
---@field quadraticCurveTo fun(self: CanvasRenderingContext2D, cpx: number, cpy: number, x: number, y: number)
---@field bezierCurveTo fun(self: CanvasRenderingContext2D, cp1x: number, cp1y: number, cp2x: number, cp2y: number, x: number, y: number)
---@field arcTo fun(self: CanvasRenderingContext2D, x1: number, y1: number, x2: number, y2: number, radius: number)
---@field rect fun(self: CanvasRenderingContext2D, x: number, y: number, w: number, h: number)
---@field roundRect fun(self: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, radii?: number|number[])
---@field arc fun(self: CanvasRenderingContext2D, x: number, y: number, radius: number, startAngle: number, endAngle: number, counterclockwise?: boolean)
---@field ellipse fun(self: CanvasRenderingContext2D, x: number, y: number, radiusX: number, radiusY: number, rotation: number, startAngle: number, endAngle: number, counterclockwise?: boolean)
--- Drawing images
---@field drawImage (fun(self: CanvasRenderingContext2D, image: CanvasImageSource, dx: number, dy: number)) | (fun(self: CanvasRenderingContext2D, image: CanvasImageSource, dx: number, dy: number, dw: number, dh: number)) | (fun(self: CanvasRenderingContext2D, image: CanvasImageSource, sx: number, sy: number, sw: number, sh: number, dx: number, dy: number, dw: number, dh: number))
--- Pixel manipulation
---@field createImageData (fun(self: CanvasRenderingContext2D, width: integer, height: integer, settings?: ImageDataSettings): ImageData) | (fun(self: CanvasRenderingContext2D, imageData: ImageData): ImageData)
---@field getImageData fun(self: CanvasRenderingContext2D, sx: integer, sy: integer, sw: integer, sh: integer, settings?: ImageDataSettings): ImageData
---@field putImageData (fun(self: CanvasRenderingContext2D, imageData: ImageData, dx: integer, dy: integer)) | (fun(self: CanvasRenderingContext2D, imageData: ImageData, dx: integer, dy: integer, dirtyX: integer, dirtyY: integer, dirtyWidth: integer, dirtyHeight: integer))

-- ---------------------------------------------------------------- 2D objects

---@class CanvasGradient
---@field addColorStop fun(self: CanvasGradient, offset: number, color: string)

---@class CanvasPattern
---@field setTransform fun(self: CanvasPattern, matrix?: DOMMatrix|DOMMatrix2DInit)

--- `hydronium_dom.canvas.path(svgPathData?)`. Has the CanvasPath methods.
---@class Path2D
---@field addPath fun(self: Path2D, path: Path2D, transform?: DOMMatrix|DOMMatrix2DInit)
---@field closePath fun(self: Path2D)
---@field moveTo fun(self: Path2D, x: number, y: number)
---@field lineTo fun(self: Path2D, x: number, y: number)
---@field quadraticCurveTo fun(self: Path2D, cpx: number, cpy: number, x: number, y: number)
---@field bezierCurveTo fun(self: Path2D, cp1x: number, cp1y: number, cp2x: number, cp2y: number, x: number, y: number)
---@field arcTo fun(self: Path2D, x1: number, y1: number, x2: number, y2: number, radius: number)
---@field rect fun(self: Path2D, x: number, y: number, w: number, h: number)
---@field roundRect fun(self: Path2D, x: number, y: number, w: number, h: number, radii?: number|number[])
---@field arc fun(self: Path2D, x: number, y: number, radius: number, startAngle: number, endAngle: number, counterclockwise?: boolean)
---@field ellipse fun(self: Path2D, x: number, y: number, radiusX: number, radiusY: number, rotation: number, startAngle: number, endAngle: number, counterclockwise?: boolean)

--- RGBA pixels. `data` is a Uint8ClampedArray host reference: index it from
--- 0 (`data[0]` is the first pixel's red); `#data` is its length.
---@class ImageData
---@field width integer
---@field height integer
---@field data table<integer, integer>
---@field colorSpace "srgb"|"display-p3"

---@class TextMetrics
---@field width number
---@field actualBoundingBoxLeft number
---@field actualBoundingBoxRight number
---@field actualBoundingBoxAscent number
---@field actualBoundingBoxDescent number
---@field fontBoundingBoxAscent number
---@field fontBoundingBoxDescent number
---@field emHeightAscent number
---@field emHeightDescent number
---@field hangingBaseline number
---@field alphabeticBaseline number
---@field ideographicBaseline number

--- `hydronium_dom.canvas.matrix(init?)`.
---@class DOMMatrix : DOMMatrix2DInit
---@field a number
---@field b number
---@field c number
---@field d number
---@field e number
---@field f number
---@field m11 number
---@field m12 number
---@field m13 number
---@field m14 number
---@field m21 number
---@field m22 number
---@field m23 number
---@field m24 number
---@field m31 number
---@field m32 number
---@field m33 number
---@field m34 number
---@field m41 number
---@field m42 number
---@field m43 number
---@field m44 number
---@field is2D boolean
---@field isIdentity boolean
---@field multiply fun(self: DOMMatrix, other: DOMMatrix|DOMMatrix2DInit): DOMMatrix
---@field translate fun(self: DOMMatrix, tx?: number, ty?: number, tz?: number): DOMMatrix
---@field scale fun(self: DOMMatrix, sx?: number, sy?: number, sz?: number, ox?: number, oy?: number, oz?: number): DOMMatrix
---@field rotate fun(self: DOMMatrix, rotX?: number, rotY?: number, rotZ?: number): DOMMatrix
---@field skewX fun(self: DOMMatrix, sx?: number): DOMMatrix
---@field skewY fun(self: DOMMatrix, sy?: number): DOMMatrix
---@field inverse fun(self: DOMMatrix): DOMMatrix
---@field flipX fun(self: DOMMatrix): DOMMatrix
---@field flipY fun(self: DOMMatrix): DOMMatrix
---@field transformPoint fun(self: DOMMatrix, point?: { x?: number, y?: number, z?: number, w?: number }): { x: number, y: number, z: number, w: number }
---@field multiplySelf fun(self: DOMMatrix, other: DOMMatrix|DOMMatrix2DInit): DOMMatrix
---@field translateSelf fun(self: DOMMatrix, tx?: number, ty?: number, tz?: number): DOMMatrix
---@field scaleSelf fun(self: DOMMatrix, sx?: number, sy?: number, sz?: number, ox?: number, oy?: number, oz?: number): DOMMatrix
---@field rotateSelf fun(self: DOMMatrix, rotX?: number, rotY?: number, rotZ?: number): DOMMatrix
---@field invertSelf fun(self: DOMMatrix): DOMMatrix
---@field toString fun(self: DOMMatrix): string

-- ---------------------------------------------------------------- bitmaps, offscreen

---@class ImageBitmap
---@field width integer
---@field height integer
---@field close fun(self: ImageBitmap)

---@class ImageBitmapRenderingContext
---@field canvas HTMLCanvasElement|OffscreenCanvas
---@field transferFromImageBitmap fun(self: ImageBitmapRenderingContext, bitmap: ImageBitmap|nil)

--- `hydronium_dom.canvas.offscreen(width, height)`.
---@class OffscreenCanvas
---@field width integer
---@field height integer
---@field getContext (fun(self: OffscreenCanvas, kind: "2d", options?: CanvasRenderingContext2DSettings): OffscreenCanvasRenderingContext2D|nil) | (fun(self: OffscreenCanvas, kind: "bitmaprenderer", options?: table): ImageBitmapRenderingContext|nil) | (fun(self: OffscreenCanvas, kind: "webgl"|"webgl2", options?: table): WebGLContext|nil)
---@field transferToImageBitmap fun(self: OffscreenCanvas): ImageBitmap
---@field convertToBlob fun(self: OffscreenCanvas, options?: { type?: string, quality?: number }): any Promise<Blob>

--- The 2D context of an OffscreenCanvas: the same drawing API, without the
--- element-only members (drawFocusIfNeeded).
---@class OffscreenCanvasRenderingContext2D : CanvasRenderingContext2D
---@field canvas OffscreenCanvas
