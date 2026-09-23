--[[
  Host-neutral reader for Ballad's private source inventory.

  The inventory is an authority, not a cache: its declared records are
  re-derived from the embedded topology configuration before a host consumes
  them. That lets DOM, Ink, LÖVE, and future hosts share one safe artifact
  without each gaining a filesystem scanner or JSON dependency.
--]]

local topology = require("hydronium.core.source_topology")

local M = {}

local function fail(message, level)
  error("hydronium.core.source_inventory: " .. message, level or 3)
end

function M.from_table(inventory)
  if type(inventory) ~= "table" or inventory.version ~= 1 or type(inventory.config) ~= "table"
    or type(inventory.records) ~= "table" then
    fail("invalid source inventory", 2)
  end
  local config, paths, supplied = {}, {}, {}
  for key, value in pairs(inventory.config) do config[key] = value end
  config.files = paths
  for _, record in ipairs(inventory.records) do
    if type(record) ~= "table" or type(record.path) ~= "string" or supplied[record.path] then
      fail("inventory contains an invalid or duplicate record", 2)
    end
    supplied[record.path] = record
    paths[#paths + 1] = record.path
  end
  local records = topology.resolve(config, paths)
  for _, record in ipairs(records) do
    local declared = supplied[record.path]
    if not declared or declared.id ~= record.id or declared.transform ~= record.transform
      or declared.target ~= record.target or declared.update ~= record.update or declared.effects ~= record.effects then
      fail("inventory record disagrees with its topology declaration: " .. record.path, 2)
    end
  end
  return { config = config, records = records, revision = inventory.revision }
end

function M.load(path)
  local chunk, err = loadfile(path)
  if not chunk then fail("cannot load " .. tostring(path) .. ": " .. tostring(err), 2) end
  local ok, inventory = pcall(chunk)
  if not ok then fail("inventory failed: " .. tostring(inventory), 2) end
  return M.from_table(inventory)
end

return M
