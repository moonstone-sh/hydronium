--[[ Host-neutral, immutable mutation descriptors. ]]

local M = {}

local function fail(message, level)
  error("hydronium.actions: " .. message, level or 3)
end

local function copy(value)
  local out = {}
  for k, v in pairs(value or {}) do out[k] = v end
  return out
end

local valid_methods = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true }

local function encode(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(byte)
    return string.format("%%%02X", string.byte(byte))
  end))
end

local function fill_path(path, params)
  params = params or {}
  local used = {}
  local function replacement(name, catch_all)
    local value = params[name]
    if value == nil then
      fail("missing path param " .. string.format("%q", name) .. " for action " .. string.format("%q", path), 3)
    end
    used[name] = true
    if catch_all then
      local segments = {}
      for segment in tostring(value):gmatch("[^/]+") do segments[#segments + 1] = encode(segment) end
      return table.concat(segments, "/")
    end
    return encode(value)
  end
  -- Lua patterns have no optional quantifier. Expand catch-alls first so the
  -- ordinary parameter pass cannot consume the name and leave a stray `*`.
  local result = path:gsub(":([%a_][%w_]*)%*", function(name)
    return replacement(name, true)
  end)
  result = result:gsub(":([%a_][%w_]*)", function(name)
    return replacement(name, false)
  end)
  for key in pairs(params) do
    if not used[key] then
      fail("unknown path param " .. string.format("%q", tostring(key))
        .. " for action " .. string.format("%q", path), 3)
    end
  end
  return result
end

---@class HydroniumAction
---@field id string
---@field path string
---@field method "GET"|"POST"|"PUT"|"PATCH"|"DELETE"
---@field encoding "form"|"json"
---@field schema table|nil Standard Schema v1 validator
local Action = {}
Action.__index = Action

function Action:path_for(params)
  return fill_path(self.path, params)
end

Action.href = Action.path_for

function Action:meteorite(opts)
  opts = opts or {}
  if type(opts) ~= "table" then fail("action:meteorite expects an options table", 2) end
  if opts.handler == nil then fail("action:meteorite requires opts.handler", 2) end
  local spec = copy(opts)
  spec.id = self.id
  spec.route = self.path
  spec.handler = opts.handler
  return spec
end

function Action:check(values)
  if not self.schema then return true, {}, values end
  return require("hydronium.core.form").check(self.schema, values)
end

---@class HydroniumActionOptions
---@field id string
---@field path string
---@field method? "GET"|"POST"|"PUT"|"PATCH"|"DELETE"
---@field encoding? "form"|"json"
---@field schema? table Standard Schema v1 validator

---@param opts HydroniumActionOptions
---@return HydroniumAction
function M.define(opts)
  if type(opts) ~= "table" then fail("define expects an options table", 2) end
  if type(opts.id) ~= "string" or opts.id == "" then fail("action id must be a non-empty string", 2) end
  if type(opts.path) ~= "string" or opts.path == "" or opts.path:sub(1, 1) ~= "/" then
    fail("action " .. string.format("%q", tostring(opts.id)) .. " needs an absolute path", 2)
  end
  local method = string.upper(opts.method or "POST")
  if not valid_methods[method] then fail("action " .. string.format("%q", opts.id) .. " has unsupported method " .. string.format("%q", method), 2) end
  if opts.encoding ~= nil and opts.encoding ~= "form" and opts.encoding ~= "json" then
    fail("action " .. string.format("%q", opts.id) .. " encoding must be \"form\" or \"json\"", 2)
  end
  if opts.schema ~= nil then
    local std = type(opts.schema) == "table" and opts.schema["~standard"]
    if type(std) ~= "table" or type(std.validate) ~= "function" then
      fail("action " .. string.format("%q", opts.id) .. " schema must implement Standard Schema v1", 2)
    end
  end
  local descriptor = {
    _hydronium_action = true,
    id = opts.id,
    path = opts.path,
    method = method,
    encoding = opts.encoding or "form",
    schema = opts.schema,
  }
  return setmetatable({}, {
    __index = function(_, key)
      local method_value = Action[key]
      if method_value ~= nil then return method_value end
      return descriptor[key]
    end,
    __newindex = function(_, key)
      fail("cannot modify action " .. string.format("%q", opts.id)
        .. " field " .. string.format("%q", tostring(key)), 2)
    end,
    __pairs = function() return next, descriptor, nil end,
    __tostring = function() return "Action(" .. opts.id .. ")" end,
  })
end

function M.ok(opts)
  opts = opts or {}
  if type(opts) ~= "table" then fail("ok expects an options table", 2) end
  return { ok = true, status = opts.status or 200, data = opts.data, redirect = opts.redirect }
end

function M.fail(opts)
  opts = opts or {}
  if type(opts) ~= "table" then fail("fail expects an options table", 2) end
  return {
    ok = false,
    status = opts.status or 422,
    values = copy(opts.values),
    errors = copy(opts.errors),
    data = opts.data,
  }
end

M.Action = Action
M.action = M.define

return M
