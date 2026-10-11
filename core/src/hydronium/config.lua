-- Explicit environment decoding. Call once at application startup; no globals
-- are captured and validation errors never echo environment values/secrets.
---@type HydroniumConfigModule
local M = {}
local function scalar(raw, field)
  local kind = field.kind or "string"
  if kind == "string" then return type(raw) == "string" and raw or nil end
  if kind == "boolean" then
    if raw == true or raw == "true" or raw == "1" then return true end
    if raw == false or raw == "false" or raw == "0" then return false end
    return nil
  end
  if kind == "integer" then
    local value = tonumber(raw)
    if value and value == value and value ~= math.huge and value ~= -math.huge
      and value == math.floor(value) then return value end
    return nil
  end
  error("hydronium.config: unsupported kind " .. tostring(kind), 3)
end

function M.read(fields, environment)
  local get = type(environment) == "function" and environment
    or (type(environment) == "table" and function(name) return environment[name] end)
    or os.getenv
  local values, errors = {}, {}
  local keys = {}; for key in pairs(fields) do keys[#keys+1] = key end; table.sort(keys)
  for _, key in ipairs(keys) do
    local field = fields[key]
    local kind = field.kind or "string"
    if kind ~= "string" and kind ~= "boolean" and kind ~= "integer" then
      error("hydronium.config: unsupported kind " .. tostring(kind), 2)
    end
    if field.min ~= nil or field.max ~= nil then
      if kind ~= "integer" or (field.min ~= nil and type(field.min) ~= "number")
        or (field.max ~= nil and type(field.max) ~= "number")
        or (field.min ~= nil and field.max ~= nil and field.min > field.max) then
        error("hydronium.config: invalid integer bounds for " .. key, 2)
      end
    end
    local raw = get(field.env or key)
    if raw == nil then raw = field.default end
    local value
    if raw ~= nil then value = scalar(raw, field) end
    local problem
    if raw == nil then
      if field.required then problem = "is required" end
    elseif value == nil then problem = "must be " .. (field.kind or "string")
    elseif field.min and value < field.min or field.max and value > field.max then problem = "is outside the allowed range"
    elseif field.values then
      local found = false
      for _, allowed in ipairs(field.values) do if value == allowed then found = true end end
      if not found then problem = "must be one of the allowed values" end
    end
    if not problem and value ~= nil and field.schema then
      local ok, _, transformed = require("hydronium.core.form").check(field.schema, value)
      if ok then value = transformed else problem = "failed schema validation" end
    end
    if problem then errors[#errors+1] = {field=key, env=field.env or key, message=problem}
    else values[key] = value end
  end
  if #errors > 0 then return nil, errors end
  return values
end

function M.require(fields, environment)
  local values, errors = M.read(fields, environment)
  if values then return values end
  local messages = {}
  for _, issue in ipairs(errors) do messages[#messages+1] = issue.env .. " " .. issue.message end
  error("Invalid application configuration: " .. table.concat(messages, "; "), 2)
end
return M
