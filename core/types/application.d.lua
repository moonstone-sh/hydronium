---@meta "hydronium-core-application"

---@class HydroniumConfigField
---@field env? string
---@field kind? "string"|"boolean"|"integer"
---@field default? string|boolean|integer
---@field required? boolean
---@field min? number Integer bounds only
---@field max? number Integer bounds only
---@field values? any[]
---@field schema? table Standard Schema v1 validator, including Valua

---@class HydroniumConfigIssue
---@field field string
---@field env string
---@field message string

---@class HydroniumConfigModule
---@field read fun(fields: table<string, HydroniumConfigField>, environment?: table|fun(name: string): any): table|nil, HydroniumConfigIssue[]|nil
---@field require fun(fields: table<string, HydroniumConfigField>, environment?: table|fun(name: string): any): table

