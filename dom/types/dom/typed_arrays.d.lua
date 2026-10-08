---@meta
-- JavaScript binary data as host references: what WebGL buffers, WebGPU
-- buffers and ImageData hold. Lua cannot construct them (a Lua table crosses
-- as a plain Array); create them with `canvas.typed(kind, source)`
-- (hydronium_dom.canvas). Elements index from 0, as in JavaScript.

--- A raw byte buffer.
---@class ArrayBuffer
---@field byteLength integer
---@field slice fun(self: ArrayBuffer, begin?: integer, finish?: integer): ArrayBuffer

---@class SharedArrayBuffer : ArrayBuffer

--- A typed view over an ArrayBuffer. Index it from 0: `view[0]`.
---@class ArrayBufferView
---@field buffer ArrayBuffer
---@field byteLength integer
---@field byteOffset integer

---@class TypedArray : ArrayBufferView
---@field length integer
---@field BYTES_PER_ELEMENT integer
---@field [integer] number
---@field set fun(self: TypedArray, source: number[]|TypedArray, offset?: integer)
---@field fill fun(self: TypedArray, value: number, start?: integer, finish?: integer): TypedArray
---@field subarray fun(self: TypedArray, begin?: integer, finish?: integer): TypedArray

---@class Int8Array : TypedArray
---@class Uint8Array : TypedArray
---@class Uint8ClampedArray : TypedArray
---@class Int16Array : TypedArray
---@class Uint16Array : TypedArray
---@class Int32Array : TypedArray
---@class Uint32Array : TypedArray
---@class Float32Array : TypedArray
---@class Float64Array : TypedArray
---@class BigInt64Array : TypedArray
---@class BigUint64Array : TypedArray
---@class DataView : ArrayBufferView

---@alias TypedArrayKind "Int8Array"|"Uint8Array"|"Uint8ClampedArray"|"Int16Array"|"Uint16Array"|"Int32Array"|"Uint32Array"|"Float32Array"|"Float64Array"

---@alias BufferSource ArrayBuffer|ArrayBufferView
---@alias AllowSharedBufferSource ArrayBuffer|SharedArrayBuffer|ArrayBufferView

--- A JavaScript promise held in a property (not awaited). Host calls that
--- return promises suspend instead and return the settled value.
---@class HostPromise
