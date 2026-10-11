---@meta "hydronium-table-remote"

---@class HydroniumRemoteTableParams
---@field page integer Zero based
---@field page_size integer
---@field sorting table[]
---@field filters table<string, any>
---@field search string

---@class HydroniumRemoteTableOptions
---@field client table hydronium/query client
---@field key any JSON-shaped namespace, including account identity when needed
---@field columns? table[]
---@field row_id? fun(row: any, index: integer): any
---@field page_size? integer Positive integer
---@field sorting? table[]
---@field filters? table<string, any>
---@field search? string
---@field stale_time? number
---@field query fun(params: HydroniumRemoteTableParams, context: table, done: fun(error?: any, data?: {rows: table[], total: integer})): fun()|nil

---@class HydroniumRemoteTable
---@field total fun(): integer Last known matching total, retained while paging
---@field model table Hydronium headless table model
---@field state fun(): table Query state accessor
---@field refetch fun(self: HydroniumRemoteTable)
---@field dispose fun(self: HydroniumRemoteTable)
