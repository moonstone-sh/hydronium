--[[
  LÖVE HMR adapter.

  It has no dependency on LÖVE at load time. `from_love` merely supplies the
  usual filesystem reader; tests and alternate game hosts can inject one.
  Call `:update()` from love.update, after game input/update work and before
  drawing. That is the explicit frame-safe commit boundary.
--]]

local hmr_host = require("hydronium.core.hmr_host")

local M = {}

local function fail(message, level)
  error("hydronium.core.love_hmr: " .. message, level or 3)
end

local function valid_record(record)
  return type(record) == "table" and type(record.id) == "string" and record.id ~= ""
    and type(record.path) == "string" and record.path ~= ""
end

function M.new(opts)
  opts = opts or {}
  if type(opts.records) ~= "table" then fail("records must be normalized source-topology records", 2) end
  if type(opts.read) ~= "function" then fail("read(path) is required", 2) end
  if opts.compile ~= nil and type(opts.compile) ~= "function" then fail("compile(record, source) must be a function", 2) end

  local records, previous = {}, {}
  for _, record in ipairs(opts.records) do
    if not valid_record(record) then fail("each record needs id and path", 2) end
    if records[record.id] then fail("duplicate module id " .. record.id, 2) end
    records[record.id] = record
  end
  local host = hmr_host.new({ root = opts.root, on_remount = opts.on_remount, on_restart = opts.on_restart })
  local self = { revision = 0, host = host }

  local function source_for(record)
    local source, err = opts.read(record.path)
    if source == nil then return nil, err or "source is unavailable" end
    if type(source) ~= "string" then return nil, "reader returned " .. type(source) end
    if opts.compile then
      local ok, compiled = pcall(opts.compile, record, source)
      if not ok then return nil, tostring(compiled) end
      if type(compiled) ~= "string" then return nil, "compiler returned " .. type(compiled) end
      source = compiled
    end
    return source
  end

  --- Establish the initial source snapshot. Call after modules are installed;
  --- this never evaluates replacements or reloads a game.
  function self:prime()
    for id, record in pairs(records) do
      local source, err = source_for(record)
      if not source then return nil, "cannot read " .. id .. ": " .. tostring(err) end
      previous[id] = source
    end
    return true
  end

  --- Poll once at the game frame boundary. Unsafe, missing, compilation-failed,
  --- or planner-rejected updates preserve the previous snapshot and report a
  --- restart-required outcome; no partial source set is committed.
  function self:update()
    local batch, effects, next_snapshot = {}, {}, {}
    for id, record in pairs(records) do
      local source, err = source_for(record)
      if not source then
        return { outcome = "restart", reason = "source_unavailable:" .. id .. ":" .. tostring(err) }
      end
      next_snapshot[id] = source
      if previous[id] ~= source then
        batch[id], effects[id] = source, record.effects or "restart"
      end
    end
    if next(batch) == nil then return nil end
    self.revision = self.revision + 1
    local revision = tostring(self.revision)
    host:queue_batch(batch, { revision = revision, effects = effects })
    local result = host:flush(revision)
    if result.outcome ~= "restart" and result.outcome ~= "rejected" then previous = next_snapshot end
    if opts.on_result then opts.on_result(result) end
    return result
  end

  return self
end

function M.from_love(opts)
  opts = opts or {}
  local love_api = opts.love or _G.love
  if not love_api or not love_api.filesystem or type(love_api.filesystem.read) ~= "function" then
    fail("love.filesystem.read is required", 2)
  end
  if not opts.read then
    opts.read = function(path)
      local data, err = love_api.filesystem.read(path)
      return data, err
    end
  end
  return M.new(opts)
end

return M
