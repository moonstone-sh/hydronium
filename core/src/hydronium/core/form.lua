--[[ Reactive bindings for immutable Hydronium action descriptors. ]]

local signals = require("hydronium.signals")
local context = require("hydronium.core.context")
local scope = require("hydronium.core.scope")

local M = {}

M.TransportContext = context.createContext(nil)

local function copy(value)
  local out = {}
  for k, v in pairs(value or {}) do out[k] = v end
  return out
end

local function encode_component(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(byte)
    return string.format("%%%02X", string.byte(byte))
  end))
end

local function encode_form(values)
  local keys = {}
  for key in pairs(values or {}) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local value = values[key]
    if type(value) == "table" then
      for i = 1, #value do
        parts[#parts + 1] = encode_component(key) .. "=" .. encode_component(value[i])
      end
    else
      parts[#parts + 1] = encode_component(key) .. "=" .. encode_component(value)
    end
  end
  return table.concat(parts, "&")
end

local function literal(value, label)
  if type(value) ~= "string" then
    error("hydronium.forms: " .. label .. " bridge returned " .. type(value) .. ", expected a Lua literal string", 3)
  end
  local compile = loadstring or load
  local chunk, err = compile("return " .. value, "@hydronium-form-bridge")
  if not chunk then error("hydronium.forms: invalid " .. label .. " bridge payload: " .. tostring(err), 3) end
  if setfenv then setfenv(chunk, {}) end
  local ok, result = pcall(chunk)
  if not ok or type(result) ~= "table" then
    error("hydronium.forms: invalid " .. label .. " bridge payload", 3)
  end
  return result
end

local function browser_transport(request, done)
  if request.encoding ~= "form" then
    error("hydronium.forms: the default browser transport supports form encoding only; pass opts.transport for "
      .. tostring(request.encoding), 3)
  end
  return _G.__hydronium_form_request(
    request.url,
    request.method,
    encode_form(request.values),
    request.id,
    function(response_status, outcome_literal)
      done(response_status, literal(outcome_literal, "response"))
    end
  )
end

local function field_of(issue)
  local path = issue.path
  if type(path) ~= "table" or path[1] == nil then return nil end
  local first = path[1]
  return type(first) == "table" and first.key or first
end

--- Validate against Standard Schema v1 synchronously.
function M.check(schema, values)
  if type(schema) ~= "table" then error("hydronium.forms: check expects a schema table", 2) end
  local std = schema["~standard"]
  if type(std) ~= "table" or type(std.validate) ~= "function" then
    error("hydronium.forms: schema must implement Standard Schema v1 (`~standard.validate`)", 2)
  end
  local result = std.validate(values)
  if type(result) ~= "table" then
    error("hydronium.forms: async Standard Schema validators are not supported", 2)
  end
  if result.issues == nil or #result.issues == 0 then return true, {}, result.value end
  local errors = {}
  for i = 1, #result.issues do
    local issue = result.issues[i]
    local field = field_of(issue)
    local key = field ~= nil and tostring(field) or "_form"
    local bucket = errors[key] or {}
    errors[key] = bucket
    bucket[#bucket + 1] = tostring(issue.message or "Invalid input")
  end
  return false, errors, nil
end

function M.is_valid(errors)
  for _, messages in pairs(errors or {}) do
    if type(messages) == "table" and #messages > 0 then return false end
  end
  return true
end

local function action_error(action)
  return type(action) ~= "table" or action._hydronium_action ~= true
end

--- Bind an action to component-local reactive state.
---
--- Transport receives `(request, done)` and may return a cancel function.
--- `done(status, outcome)` is ignored after reset, unmount, or a newer
--- submission. This generation check protects visible state even when a
--- host transport cannot cancel an in-flight request.
---@class HydroniumFormProps
---@field method "POST"
---@field action string
---@field enctype "application/x-www-form-urlencoded"
---@field ["data-hydronium-action"] string
---@field onSubmit? fun(values_literal?: string): boolean

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

---@param action HydroniumAction
---@param opts? table
---@return HydroniumForm
function M.useForm(action, opts)
  opts = opts or {}
  if action_error(action) then
    error("hydronium.forms: useForm expects an action created by hydronium.action(...) ", 2)
  end
  if action.method ~= "POST" then
    error("hydronium.forms: progressive HTML forms support POST actions only; action "
      .. string.format("%q", action.id) .. " is " .. action.method, 2)
  end
  if opts.enctype ~= nil and opts.enctype ~= "application/x-www-form-urlencoded" then
    error("hydronium.forms: only application/x-www-form-urlencoded is supported; multipart requires a Meteorite upload contract", 2)
  end

  local initial = opts.initial or {}
  local values, set_values = signals.createSignal(copy(initial.values))
  local errors, set_errors = signals.createSignal(copy(initial.errors))
  local pending, set_pending = signals.createSignal(false)
  local status, set_status = signals.createSignal(initial.status)
  local data, set_data = signals.createSignal(initial.data)
  local generation, set_generation = signals.createSignal(0)
  local alive = true
  local cancel = nil

  scope.onCleanup(function()
    alive = false
    if type(cancel) == "function" then pcall(cancel) end
    cancel = nil
  end)

  local form = {
    action = action,
    props = {
      method = "POST",
      action = action:path_for(opts.params),
      enctype = "application/x-www-form-urlencoded",
      ["data-hydronium-action"] = action.id,
    },
  }

  function form:values() return values() end
  function form:errors() return errors() end
  function form:pending() return pending() end
  function form:status() return status() end
  function form:data() return data() end
  function form:error(field)
    local messages = errors()[field]
    return type(messages) == "table" and messages[1] or nil
  end
  function form:is_valid() return M.is_valid(errors()) end
  function form:set_values(next_values) set_values(copy(next_values)) end
  function form:set_value(field, value)
    local next_values = copy(values())
    next_values[field] = value
    set_values(next_values)
  end
  function form:set_errors(next_errors) set_errors(copy(next_errors)) end

  function form:validate(candidate)
    local subject = copy(candidate or values())
    if not action.schema then
      set_errors({})
      return true, {}, subject
    end
    local ok, next_errors, output = M.check(action.schema, subject)
    set_errors(next_errors)
    return ok, next_errors, output
  end

  function form:finish(token, response_status, outcome)
    if not alive or token ~= generation() then return false end
    outcome = type(outcome) == "table" and outcome or {}
    signals.batch(function()
      set_pending(false)
      set_status(response_status or outcome.status)
      if outcome.values ~= nil then set_values(copy(outcome.values)) end
      set_errors(copy(outcome.errors))
      if outcome.data ~= nil then set_data(outcome.data) end
    end)
    cancel = nil
    if outcome.redirect ~= nil and type(_G.__hydronium_form_redirect) == "function" then
      _G.__hydronium_form_redirect(outcome.redirect)
    end
    return true
  end

  function form:submit(candidate)
    if pending() then return false end
    local subject = copy(candidate or values())
    local ok = self:validate(subject)
    if not ok then return false end
    local transport = opts.transport or context.useContext(M.TransportContext)
    if type(transport) ~= "function" and _G.__hydronium_form_request ~= nil then
      transport = browser_transport
    end
    if type(transport) ~= "function" then
      error("hydronium.forms: submit needs a TransportContext provider or opts.transport; native form submission still works without calling submit()", 2)
    end
    local token = generation() + 1
    signals.batch(function()
      set_generation(token)
      set_values(subject)
      set_pending(true)
    end)
    local completed = false
    local ok_transport, returned = pcall(transport, {
      action = action,
      id = action.id,
      url = action:path_for(opts.params),
      method = action.method,
      encoding = action.encoding,
      values = subject,
      generation = token,
    }, function(response_status, outcome)
      completed = true
      self:finish(token, response_status, outcome)
    end)
    if not ok_transport then
      if alive and token == generation() then set_pending(false) end
      error(returned, 0)
    end
    -- A transport is allowed to settle synchronously. Do not retain its
    -- cancellation handle after the completion callback already cleared it.
    if not completed and type(returned) == "function" then cancel = returned end
    return true
  end

  function form:reset(next)
    set_generation(generation() + 1)
    if type(cancel) == "function" then pcall(cancel) end
    cancel = nil
    next = next or {}
    signals.batch(function()
      set_values(copy(next.values))
      set_errors(copy(next.errors))
      set_pending(false)
      set_status(next.status)
      set_data(next.data)
    end)
  end

  if opts.enhance == true or (_G.__hydronium_form_values ~= nil and _G.__hydronium_form_request ~= nil) then
    form.props.onSubmit = function(values_literal)
      -- The DOM host supplies a snapshot captured during event dispatch.
      -- Other hosts may omit it and provide __hydronium_form_values instead.
      if values_literal == nil then
        values_literal = _G.__hydronium_form_values()
      end
      return form:submit(literal(values_literal, "values"))
    end
  end

  return form
end

M.use_form = M.useForm

return M
