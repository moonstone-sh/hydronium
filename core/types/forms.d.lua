---@meta "hydronium-core-forms"

--- Public forms and actions declarations. This sits beside the runtime in
--- hydronium/core so `moon add hydronium/core` gives LuaLS the same API that
--- applications execute; it is not an application-local example typing.

---@class HydroniumActionOptions
---@field id string
---@field path string
---@field method? "GET"|"POST"|"PUT"|"PATCH"|"DELETE"
---@field encoding? "form"|"json"
---@field schema? table Standard Schema v1 validator

---@class HydroniumAction
---@field id string
---@field path string
---@field method "GET"|"POST"|"PUT"|"PATCH"|"DELETE"
---@field encoding "form"|"json"
---@field schema? table
---@field path_for fun(self: HydroniumAction, params?: table<string, any>): string
---@field href fun(self: HydroniumAction, params?: table<string, any>): string
---@field check fun(self: HydroniumAction, values: table<string, any>): boolean, table<string, string[]>, any

---@class HydroniumFormProps
---@field method "POST"
---@field action string
---@field enctype "application/x-www-form-urlencoded"
---@field ["data-hydronium-action"] string
---@field onSubmit? fun(values_literal?: string): boolean

---@class HydroniumUseFormOptions
---@field params? table<string, any>
---@field initial? {values?: table<string, any>, errors?: table<string, string[]>, status?: integer, data?: any}
---@field enctype? "application/x-www-form-urlencoded"
---@field enhance? boolean
---@field transport? fun(request: table, done: fun(status?: integer, outcome?: table)): fun()|nil

---@class HydroniumForm
---@field action HydroniumAction
---@field props HydroniumFormProps
---@field values fun(self: HydroniumForm): table<string, any>
---@field errors fun(self: HydroniumForm): table<string, string[]>
---@field error fun(self: HydroniumForm, field: string): string|nil
---@field pending fun(self: HydroniumForm): boolean
---@field status fun(self: HydroniumForm): integer|nil
---@field data fun(self: HydroniumForm): any
---@field is_valid fun(self: HydroniumForm): boolean
---@field set_values fun(self: HydroniumForm, values: table<string, any>)
---@field set_value fun(self: HydroniumForm, field: string, value: any)
---@field set_errors fun(self: HydroniumForm, errors: table<string, string[]>)
---@field validate fun(self: HydroniumForm, candidate?: table<string, any>): boolean, table<string, string[]>, any
---@field submit fun(self: HydroniumForm, candidate?: table<string, any>): boolean
---@field reset fun(self: HydroniumForm, next?: {values?: table<string, any>, errors?: table<string, string[]>, status?: integer, data?: any})

---@class Hydronium
---@field action fun(opts: HydroniumActionOptions): HydroniumAction
---@field Action HydroniumAction
---@field action_ok fun(opts?: {status?: integer, data?: any, redirect?: string}): {ok: true, status: integer, data: any, redirect: string|nil}
---@field action_fail fun(opts?: {status?: integer, values?: table<string, any>, errors?: table<string, string[]>, data?: any}): {ok: false, status: integer, values: table<string, any>, errors: table<string, string[]>, data: any}
---@field forms table
---@field useForm fun(action: HydroniumAction, opts?: HydroniumUseFormOptions): HydroniumForm
---@field use_form fun(action: HydroniumAction, opts?: HydroniumUseFormOptions): HydroniumForm
