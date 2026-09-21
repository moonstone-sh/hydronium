-- Single-owner session service for HTTP/dev-host adapters. The host is
-- responsible for routing every call to this one object; no session state is
-- stored in request-handler globals.
local runtime = require("hydronium_ink_lab.runtime")

local M, Service = {}, {}
Service.__index = Service

local function positive_integer(value, label)
  value = tonumber(value)
  if not value or value < 1 or value % 1 ~= 0 then error(label .. " must be a positive integer", 3) end
  return value
end

local function default_clock() return os.time() end

function M.new(registry, opts)
  opts = opts or {}
  if type(opts.id) ~= "function" then
    error("hydronium_ink_lab.service: a cryptographically secure id callback is required", 2)
  end
  return setmetatable({
    registry = registry,
    sessions = {},
    count = 0,
    max_sessions = positive_integer(opts.max_sessions or 32, "max_sessions"),
    idle_seconds = positive_integer(opts.idle_seconds or 900, "idle_seconds"),
    max_operation_bytes = positive_integer(opts.max_operation_bytes or 65536, "max_operation_bytes"),
    clock = opts.clock or default_clock,
    id = opts.id,
    generation = opts.generation or "1",
  }, Service)
end

function Service:sweep(now)
  now = now or self.clock()
  local removed = 0
  for id, item in pairs(self.sessions) do
    if now - item.touched >= self.idle_seconds then
      item.runtime:close()
      self.sessions[id], self.count, removed = nil, self.count - 1, removed + 1
    end
  end
  return removed
end

function Service:create()
  self:sweep()
  if self.count >= self.max_sessions then
    return { ok = false, outcome = "rate_limited", message = "Lab session capacity reached" }
  end
  local id = self.id()
  if type(id) ~= "string" or #id < 32 or self.sessions[id] then
    error("hydronium_ink_lab.service: id callback must return unique opaque strings of at least 32 bytes", 2)
  end
  self.sessions[id] = { runtime = runtime.new(self.registry), sequence = 0, touched = self.clock() }
  self.count = self.count + 1
  return { ok = true, outcome = "created", session = id, sequence = 0, generation = self.generation,
    catalog = self.sessions[id].runtime:catalog() }
end

function Service:operate(id, envelope, encoded_bytes)
  self:sweep()
  local item = self.sessions[id]
  if not item then return { ok = false, outcome = "session_expired" } end
  if type(envelope) ~= "table" then return { ok = false, outcome = "invalid_request", message = "operation must be an object" } end
  if encoded_bytes and encoded_bytes > self.max_operation_bytes then
    return { ok = false, outcome = "invalid_request", message = "operation body is too large" }
  end
  if envelope.generation ~= nil and envelope.generation ~= self.generation then
    return { ok = false, outcome = "stale_revision", generation = self.generation }
  end
  local expected = item.sequence + 1
  if envelope.sequence ~= expected then
    return { ok = false, outcome = "stale_sequence", expected = expected, sequence = item.sequence }
  end
  local ok, result = pcall(item.runtime.request, item.runtime, envelope.request)
  if not ok then
    item.touched = self.clock()
    return { ok = false, outcome = "render_error", sequence = item.sequence, message = tostring(result) }
  end
  item.sequence, item.touched = expected, self.clock()
  return { ok = true, outcome = "frame", sequence = item.sequence, generation = self.generation, result = result }
end

function Service:close(id)
  local item = self.sessions[id]
  if not item then return { ok = true, outcome = "closed", existed = false } end
  item.runtime:close()
  self.sessions[id], self.count = nil, self.count - 1
  return { ok = true, outcome = "closed", existed = true }
end

function Service:invalidate(generation, registry)
  for id, item in pairs(self.sessions) do item.runtime:close(); self.sessions[id] = nil end
  self.count = 0
  if registry then self.registry = registry end
  self.generation = tostring(generation)
  return { ok = true, outcome = "invalidated", generation = self.generation }
end

function Service:shutdown()
  return self:invalidate(self.generation)
end

M.Service = Service
return M
