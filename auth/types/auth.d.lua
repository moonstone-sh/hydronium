---@meta "hydronium-auth"

---@class HydroniumAuthState
---@field step string
---@field pending boolean
---@field error? string
---@field message? string
---@field data? any

---@class HydroniumAuthFlowOptions
---@field initial_step? string
---@field steps? table<string, boolean>
---@field validate? fun(operation: string, payload: any): boolean, string|nil
---@field transport fun(operation: string, payload: any, done: fun(error?: any, result?: {step?: string, data?: any, message?: string})): fun()|nil

---@class HydroniumAuthFlow
---@field state fun(): HydroniumAuthState Read as flow.state(), without a colon
---@field reset fun(self: HydroniumAuthFlow, step?: string)
---@field submit fun(self: HydroniumAuthFlow, operation: string, payload?: any): boolean
---@field dispose fun(self: HydroniumAuthFlow)

---@class HydroniumAuthModule
---@field createFlow fun(options: HydroniumAuthFlowOptions): HydroniumAuthFlow
---@field create_flow fun(options: HydroniumAuthFlowOptions): HydroniumAuthFlow
