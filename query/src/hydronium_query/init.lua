-- Optional client-side server-state cache.  This package intentionally does
-- not replace H.resource() (render dependency) or RouterResource (navigation
-- transition); see docs/ASYNC_DATA.md for the lifetime boundary.
local M = {}

local Client = {}
Client.__index = Client

local function now_seconds() return os.clock() end

local function finite_number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Canonical JSON-shaped query key serializer. Tables are either dense arrays
-- or string-keyed objects; mixed/sparse tables have no unambiguous JSON form.
local function encode_key(value, seen)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" and finite_number(value) then return string.format("%.17g", value) end
  if kind ~= "table" then error("hydronium.query key values must be JSON-shaped (string, boolean, number, or table)", 3) end
  seen = seen or {}
  if seen[value] then error("hydronium.query key cannot be recursive", 3) end
  seen[value] = true
  local count, array, max = 0, true, 0
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then array = false else max = math.max(max, key) end
  end
  local out = {}
  if array then
    if max ~= count then error("hydronium.query key arrays cannot be sparse", 3) end
    for i = 1, max do out[#out + 1] = encode_key(value[i], seen) end
    seen[value] = nil
    return "[" .. table.concat(out, ",") .. "]"
  end
  for key in pairs(value) do
    if type(key) ~= "string" then error("hydronium.query key objects require string keys", 3) end
    out[#out + 1] = key
  end
  table.sort(out)
  local parts = {}
  for _, key in ipairs(out) do parts[#parts + 1] = string.format("%q", key) .. ":" .. encode_key(value[key], seen) end
  seen[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

local function copy_state(entry)
  return { status = entry.status, data = entry.data, error = entry.error, updated_at = entry.updated_at, fetching = entry.fetching }
end

function Client:_notify(entry)
  local state = copy_state(entry)
  for _, observer in pairs(entry.observers) do observer(state) end
end

function Client:_entry(key)
  local id = encode_key(key)
  local entry = self.entries[id]
  if not entry then
    entry = { id = id, key = key, status = "idle", fetching = false, generation = 0, observers = {}, observer_count = 0 }
    self.entries[id] = entry
  end
  return entry
end

function Client:observe(options, observer)
  if type(options) ~= "table" or options.key == nil or type(options.query) ~= "function" then
    error("hydronium.query.observe requires { key = ..., query = function(ctx, done) ... end }", 2)
  end
  if type(observer) ~= "function" then error("hydronium.query.observe requires an observer", 2) end
  local entry = self:_entry(options.key)
  entry.query = options.query
  local token = {}
  entry.observers[token] = observer
  entry.observer_count = entry.observer_count + 1
  entry.gc_at = nil
  observer(copy_state(entry))
  local stale_time = options.stale_time or self.default_stale_time
  local current = self.clock()
  if not entry.fetching and (entry.status == "idle" or current - (entry.updated_at or -math.huge) >= stale_time) then
    self:fetch(options)
  end
  local closed = false
  return function()
    if closed then return end
    closed = true
    entry.observers[token] = nil
    entry.observer_count = entry.observer_count - 1
    if entry.observer_count == 0 then
      entry.gc_at = self.clock() + self.gc_time
      if entry.cancel then entry.cancel(); entry.cancel = nil; entry.fetching = false; entry.generation = entry.generation + 1 end
    end
  end
end

function Client:fetch(options)
  local entry = self:_entry(options.key)
  entry.query = options.query
  if entry.fetching then return entry.cancel end
  entry.fetching, entry.status, entry.error = true, entry.status == "idle" and "pending" or entry.status, nil
  entry.generation = entry.generation + 1
  local generation = entry.generation
  local settled = false
  local function done(error_value, data)
    if settled or generation ~= entry.generation then return end
    settled = true
    entry.fetching, entry.cancel = false, nil
    entry.updated_at = self.clock()
    if error_value ~= nil then entry.status, entry.error = "error", error_value else entry.status, entry.data = "success", data end
    self:_notify(entry)
  end
  self:_notify(entry)
  local ok, cancel = pcall(options.query, { key = entry.key, signal = { aborted = function() return generation ~= entry.generation end } }, done)
  if not ok then done(cancel) elseif type(cancel) == "function" and not settled then entry.cancel = cancel end
  return entry.cancel
end

function Client:invalidate(key, options)
  options = options or {}
  local prefix = encode_key(key)
  local array_prefix = prefix:sub(-1) == "]" and prefix:sub(1, -2) .. "," or nil
  for id, entry in pairs(self.entries) do
    local match = options.exact and id == prefix or (not options.exact and (id == prefix or (array_prefix and id:sub(1, #array_prefix) == array_prefix)))
    if match then
      entry.updated_at = nil
      if entry.observer_count > 0 and options.refetch ~= false and entry.query then self:fetch({ key = entry.key, query = entry.query }) end
      self:_notify(entry)
    end
  end
end

function Client:collect()
  local current = self.clock()
  for id, entry in pairs(self.entries) do
    if entry.observer_count == 0 and entry.gc_at and entry.gc_at <= current then self.entries[id] = nil end
  end
end

function Client:mutation(options)
  if type(options) ~= "table" or type(options.mutate) ~= "function" then error("hydronium.query.mutation requires mutate", 2) end
  return function(variables, done)
    done = done or function() end
    local function settled(error_value, data)
      if error_value == nil and options.invalidate then
        for _, key in ipairs(options.invalidate) do self:invalidate(key, { refetch = false }) end
      end
      done(error_value, data)
    end
    local ok, cancel = pcall(options.mutate, variables, settled)
    if not ok then settled(cancel) end
    return type(cancel) == "function" and cancel or nil
  end
end

-- Ergonomic component-facing observer. The state accessor is a Hydronium
-- signal, so reads participate in normal render tracking; disposing the
-- component scope drops the observation and may abort the shared request.
function Client:useQuery(options)
  local core = require("hydronium.core")
  local state, set_state = core.createSignal({ status = "idle", fetching = false })
  local unsubscribe = self:observe(options, set_state)
  core.onCleanup(unsubscribe)
  return {
    state = state,
    data = function() return state().data end,
    error = function() return state().error end,
    refetch = function() return self:fetch(options) end,
    dispose = unsubscribe,
  }
end

function M.createClient(options)
  options = options or {}
  return setmetatable({ entries = {}, clock = options.clock or now_seconds, default_stale_time = options.stale_time or 0, gc_time = options.gc_time or 300 }, Client)
end

M.create_client = M.createClient
M.QueryClient = Client
M.useQuery = function(client, options) return client:useQuery(options) end
M.use_query = M.useQuery
M.encodeKey = encode_key
M.encode_key = encode_key
return M
