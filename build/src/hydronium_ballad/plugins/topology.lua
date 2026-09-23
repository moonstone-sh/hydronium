--[[
  Hydronium Ballad source-topology adapter.

  Ballad owns assets and execution. Hydronium owns the semantic mapping from
  source paths to module identities. This adapter lowers one project
  `hydronium.sources.lua` declaration onto ordinary Ballad file assets; LUAX
  compilation and the client resolver then consume the stamped metadata.
--]]

local graph = require("ballad.graph")
local process = require("ballad.process")
local dkjson = require("dkjson")
local source_topology = require("hydronium.core.source_topology")

local M = {}

local function lua_value(value, indent)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind ~= "table" then error("hydronium_ballad.plugins.topology: inventory cannot serialize " .. kind, 0) end
  indent = indent or ""
  local inner, rows = indent .. "  ", {}
  if #value > 0 then
    for _, item in ipairs(value) do rows[#rows + 1] = inner .. lua_value(item, inner) end
  else
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
      local encoded = type(key) == "string" and key:match("^[%a_][%w_]*$") and key
        or "[" .. lua_value(key, inner) .. "]"
      rows[#rows + 1] = inner .. encoded .. " = " .. lua_value(value[key], inner)
    end
  end
  if #rows == 0 then return "{}" end
  return "{\n" .. table.concat(rows, ",\n") .. "\n" .. indent .. "}"
end

local function slash(path)
  return tostring(path or ""):gsub("\\", "/")
end

local function project_relative(asset, root)
  local source_path = slash(asset.source_path)
  local prefix = slash(root):gsub("/+$", "")
  if source_path ~= "" and prefix ~= "" and source_path:sub(1, #prefix + 1) == prefix .. "/" then
    return source_path:sub(#prefix + 2)
  end
  return slash(asset.virtual_path)
end

local function load_config(value, root)
  if type(value) == "table" then return value end
  local filename = tostring(root or ".") .. "/" .. tostring(value or "hydronium.sources.lua")
  local chunk, err = loadfile(filename)
  if not chunk then error("hydronium_ballad.plugins.topology: cannot load " .. filename .. ": " .. tostring(err), 0) end
  local ok, config = pcall(chunk)
  if not ok then error("hydronium_ballad.plugins.topology: configuration failed: " .. tostring(config), 0) end
  if type(config) ~= "table" then error("hydronium_ballad.plugins.topology: configuration must return a table", 0) end
  return config
end

local function clone_asset(asset, record)
  local copy = {}
  for key, value in pairs(asset) do copy[key] = value end
  local metadata, prior = {}, asset.metadata and asset.metadata.hydronium or {}
  for key, value in pairs(asset.metadata or {}) do metadata[key] = value end
  local hydronium = {}
  for key, value in pairs(prior) do hydronium[key] = value end
  hydronium.module_id = record.id
  hydronium.target = record.target
  hydronium.transform = record.transform
  hydronium.update = record.update
  hydronium.effects = record.effects
  hydronium.tags = record.tags
  hydronium.origin = hydronium.origin or asset.source_path or record.path
  metadata.hydronium = hydronium
  copy.metadata = metadata
  return copy
end

local function records_for(ctx, inputs, opts)
  opts = opts or {}
  local root = opts.root or "."
  local config = load_config(opts.config, root)
  local by_path, files = {}, {}
  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      if asset.source_path or asset.virtual_path then
        local path = project_relative(asset, root)
        if by_path[path] then
          ctx.fail("hydronium_ballad.plugins.topology: source path appears more than once: " .. path)
        end
        by_path[path] = asset
        files[#files + 1] = path
      end
    end
  end
  local ok, records_or_error = pcall(source_topology.resolve, config, files)
  if not ok then ctx.fail("hydronium_ballad.plugins.topology: " .. tostring(records_or_error)) end
  return config, by_path, records_or_error
end

--- Stamp source assets with normalized Hydronium module metadata.
---
--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts {config?: string|table, root?: string}
--- @return AssetSet
function M.classify(ctx, inputs, opts)
  opts = opts or {}
  local _, by_path, records_or_error = records_for(ctx, inputs, opts)
  local out = graph.AssetSet.new()
  for _, record in ipairs(records_or_error) do
    out:add(ctx.graph:add_asset(clone_asset(by_path[record.path], record)))
  end
  return out
end

--- Emit a host-private, generated topology authority. It deliberately keeps
--- project-relative paths (unlike the public site manifest) so a dev host can
--- serve only declared modules without rediscovering the filesystem.
--- @return AssetSet generated JSON and Lua inventory artifacts
function M.inventory(ctx, inputs, opts)
  opts = opts or {}
  local config, _, records = records_for(ctx, inputs, opts)
  local payload = { version = 1, config = config, records = records }
  -- Hash the complete normalized declaration and record list. The revision is
  -- embedded in the artifact and is stable for an identical build closure.
  payload.revision = "b3:" .. process.b3sum_string(dkjson.encode(payload, { indent = false }))
  local name = opts.name or ".hydronium/source-inventory.json"
  local lua_name = name:gsub("%.json$", ".lua")
  local metadata = { hydronium = { inventory = "source-topology", private = true, revision = payload.revision } }
  return graph.AssetSet.new({
    ctx.graph:add_asset({
    kind = "hy_source_inventory",
    generated = true,
    virtual_path = name,
    content = dkjson.encode(payload, { indent = true }),
    metadata = metadata,
    }),
    ctx.graph:add_asset({
      kind = "hy_source_inventory",
      generated = true,
      virtual_path = lua_name,
      content = "return " .. lua_value(payload) .. "\n",
      metadata = metadata,
    }),
  })
end

M.node = {
  name = "hydronium_ballad.plugins.topology.classify",
  cacheable = false,
  run = M.classify,
}

return M
