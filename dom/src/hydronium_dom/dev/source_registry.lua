--[[
  Development source registry.

  This is the host-side companion to hydronium.core.source_topology. A server
  receives an explicit project-relative file inventory rather than shelling out
  from a request handler. That is important for Meteorite's concurrent hybrid
  runtime: module lookup remains manifest-whitelisted and never turns a dotted
  HTTP parameter into a filesystem path.
--]]

local topology = require("hydronium.core.source_topology")
local source_inventory = require("hydronium.core.source_inventory")

local M = {}

local function load_config(path)
  local chunk, err = loadfile(path)
  if not chunk then error("hydronium_dom.dev.source_registry: cannot load " .. tostring(path) .. ": " .. tostring(err), 2) end
  local ok, config = pcall(chunk)
  if not ok then error("hydronium_dom.dev.source_registry: configuration failed: " .. tostring(config), 2) end
  if type(config) ~= "table" then error("hydronium_dom.dev.source_registry: configuration must return a table", 2) end
  return config
end

--- Normalize the optional top-level `watch` list: non-module files the HMR
--- stream also reports. A string is watched only; `{ path, href }` is a
--- stylesheet the browser swaps in place at `href` (and that
--- hydronium.mount serves from disk during development).
--- @return { path: string, href?: string }[]
function M.watch_entries(config)
  local entries = {}
  for index, entry in ipairs(config.watch or {}) do
    if type(entry) == "string" then
      entries[#entries + 1] = { path = entry }
    elseif type(entry) == "table" and type(entry.path) == "string" then
      if entry.href ~= nil and (type(entry.href) ~= "string" or entry.href:sub(1, 1) ~= "/") then
        error("hydronium_dom.dev.source_registry: watch #" .. index .. " href must be an absolute URL path", 3)
      end
      entries[#entries + 1] = { path = entry.path, href = entry.href }
    else
      error("hydronium_dom.dev.source_registry: watch #" .. index .. " must be a path or { path, href }", 3)
    end
  end
  return entries
end

local function make(config, config_path)
  if type(config.files) ~= "table" then
    error("hydronium_dom.dev.source_registry: config.files must be an explicit project-relative file list", 3)
  end
  local records = topology.resolve(config, config.files)
  local by_id = {}
  for _, record in ipairs(records) do by_id[record.id] = record end

  local registry = { config = config, config_path = config_path, records = records, by_id = by_id, revision = config.revision,
    watch = M.watch_entries(config) }

  function registry:module(id)
    return self.by_id[id]
  end

  function registry:watch_files(extra)
    local files, seen = {}, {}
    local function add(path)
      if type(path) == "string" and not seen[path] then seen[path] = true; files[#files + 1] = path end
    end
    for _, record in ipairs(self.records) do add(record.path) end
    add(self.config_path)
    for _, path in ipairs(extra or {}) do add(path) end
    table.sort(files)
    return files
  end

  function registry:browser_manifest(url_prefix)
    local modules, updates = {}, {}
    url_prefix = url_prefix or "/__hydronium/dev/module/"
    for _, record in ipairs(self.records) do
      if record.target == "client" or record.target == "shared" then
        modules[record.id] = {
          url = url_prefix .. record.id,
          transform = record.transform,
          target = record.target,
          update = record.update,
          effects = record.effects,
        }
      end
      if record.update ~= "ignore" then
        local update = { action = record.update, effects = record.effects }
        if record.target == "client" or record.target == "shared" then update.module = record.id end
        updates[record.path] = update
      end
    end
    if self.config_path then updates[self.config_path] = { action = "reload" } end
    for _, entry in ipairs(self.watch) do
      if entry.href then updates[entry.path] = { action = "style", href = entry.href } end
    end
    return { version = 1, revision = self.revision, entry = self.config.entry, modules = modules, updates = updates }
  end

  return registry
end

function M.from_config(config)
  return make(config, nil)
end

function M.load(path)
  return make(load_config(path), path)
end

--- Construct a registry from Ballad's private generated inventory. The
--- inventory supplies paths; this host does not discover files or trust a
--- request parameter as a path. Re-resolving checks that its records still
--- agree with the embedded topology declaration.
function M.from_inventory(inventory)
  local resolved = source_inventory.from_table(inventory)
  resolved.config.revision = resolved.revision
  return make(resolved.config, nil)
end

--- Load Ballad's Lua inventory variant. JSON remains available for external
--- tooling; Lua keeps the runtime host dependency-free.
function M.load_inventory(path)
  local resolved = source_inventory.load(path)
  resolved.config.revision = resolved.revision
  local registry = make(resolved.config, nil)
  registry.inventory_path = path
  return registry
end

--- The project's source authority, first match wins:
---   1. `.hydronium/ballad/source-inventory.lua` -- Ballad discovery
---      (`hydronium_ballad.source_inventory`, kept current by
---      `hydronium dev --watch-sources`).
---   2. `.hydronium/sources.lua` -- written by the Vite discovery script that
---      apps generated before Ballad owned discovery still carry.
---   3. `hydronium.sources.lua` -- a hand-written, explicit `files` list.
--- Shared by the Meteorite dev routes and Lab, so a module id resolves the
--- same way everywhere.
M.BALLAD_INVENTORY = ".hydronium/ballad/source-inventory.lua"
M.DISCOVERED_SOURCES = ".hydronium/sources.lua"
M.PROJECT_SOURCES = "hydronium.sources.lua"

local function exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

--- @param root? string project directory prefix (default: current directory)
--- @return table registry
function M.load_project(root)
  local prefix = root and (root:gsub("/+$", "") .. "/") or ""
  if exists(prefix .. M.BALLAD_INVENTORY) then return M.load_inventory(prefix .. M.BALLAD_INVENTORY) end
  if exists(prefix .. M.DISCOVERED_SOURCES) then return M.load(prefix .. M.DISCOVERED_SOURCES) end
  return M.load(prefix .. M.PROJECT_SOURCES)
end

--- Like load_project, but nil (never an error) when the project declares no
--- source topology or it cannot be loaded -- for optional consumers like Lab.
--- @return table|nil
function M.try_load_project(root)
  local ok, registry = pcall(M.load_project, root)
  return ok and registry or nil
end

return M
