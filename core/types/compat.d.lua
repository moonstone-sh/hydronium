---@meta "hydronium-compat"

---@class HydroniumCompatPrimitives
---@field unpack fun(values: table, first?: integer, last?: integer): ...
---@field tointeger fun(value: any): integer|nil

---@class HydroniumCompatLoader
---@field load fun(source: string, chunkname?: string, environment?: table): function|nil, string|nil

---@class HydroniumCompatDiagnostics
---@field function_location fun(value: any): string|nil, integer|nil
---@field function_arity fun(value: any): integer|nil, boolean|nil

---@class HydroniumCompat: HydroniumCompatPrimitives, HydroniumCompatLoader, HydroniumCompatDiagnostics
