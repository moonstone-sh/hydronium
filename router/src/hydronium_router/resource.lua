-- Reactive state owned by one matched route loader.
local H = require("hydronium.core")

local M = {}
local Resource = {}
Resource.__index = Resource

function M.new(initial)
  initial = initial or {}
  local status, set_status = H.createSignal(initial.status or "idle")
  local value, set_value = H.createSignal(initial.value)
  local failure, set_failure = H.createSignal(initial.error)

  return setmetatable({
    _status = status,
    _set_status = set_status,
    _value = value,
    _set_value = set_value,
    _error = failure,
    _set_error = set_failure,
    identity = initial.identity,
    route_id = initial.route_id,
    key = initial.key,
  }, Resource)
end

function Resource:status() return self._status() end
function Resource:value() return self._value() end
function Resource:error() return self._error() end
function Resource:pending() return self._status() == "pending" end
function Resource:ready() return self._status() == "ready" end

function Resource:set_pending()
  H.batch(function()
    self._set_error(nil)
    self._set_status("pending")
  end)
end

function Resource:resolve(value)
  H.batch(function()
    self._set_value(value)
    self._set_error(nil)
    self._set_status("ready")
  end)
end

function Resource:reject(err)
  H.batch(function()
    self._set_error(err)
    self._set_status("error")
  end)
end

M.Resource = Resource
return M
