--[[
  Hydronium source topology.

  This is deliberately a pure resolver: a project declares roots and explicit
  entry overrides, while a host supplies the project-relative files it found.
  It gives HMR, build plugins, and route adapters one deterministic physical
  path -> logical module mapping without assigning meaning to directories such
  as `views`, `routes`, or `components`.
--]]

local M = {}

local function expect(condition, message)
  if not condition then error(message, 3) end
  return condition
end

local valid_target = { client = true, server = true, shared = true }
local valid_update = { hot = true, remount = true, reload = true, restart = true, ignore = true }
-- `effects` is the host's explicit proof boundary for evaluation during a
-- live replacement. Unknown code must never be treated as safe merely
-- because it happens to be under a watched root.
local valid_effects = { safe = true, managed = true, restart = true }

local function project_path(value, label)
  expect(type(value) == "string" and value ~= "", "hydronium.source_topology: " .. label .. " must be a non-empty string")
  value = value:gsub("\\", "/"):gsub("^%./", "")
  expect(not value:match("^/") and not value:match("^%a:/") and not value:find("[%z\r\n]"),
    "hydronium.source_topology: " .. label .. " must be a safe project-relative path")
  for segment in value:gmatch("[^/]+") do
    expect(segment ~= "." and segment ~= "..", "hydronium.source_topology: " .. label .. " escapes the project")
  end
  return value:gsub("/+$", "")
end

local function module_id(value, label)
  expect(type(value) == "string" and value ~= "", "hydronium.source_topology: " .. label .. " must be a dotted Lua module id")
  local rebuilt, count = {}, 0
  for segment in value:gmatch("[^.]+") do
    count = count + 1
    expect(segment:match("^[%a_][%w_]*$") ~= nil,
      "hydronium.source_topology: " .. label .. " must be a dotted Lua module id")
    rebuilt[#rebuilt + 1] = segment
  end
  expect(count > 0 and table.concat(rebuilt, ".") == value,
    "hydronium.source_topology: " .. label .. " must be a dotted Lua module id")
  return value
end

local function extension(path)
  return path:match("%.([%a%d_]+)$")
end

local function under(path, root)
  if path == root then return "" end
  if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
  return nil
end

local function add_record(records, by_id, casefolded, record)
  local prior = by_id[record.id]
  if prior then
    error("hydronium.source_topology: module id collision `" .. record.id
      .. "` between `" .. prior.path .. "` and `" .. record.path .. "`", 3)
  end
  local folded = record.id:lower()
  local folded_prior = casefolded[folded]
  if folded_prior then
    error("hydronium.source_topology: case-folding module id collision `" .. record.id
      .. "` with `" .. folded_prior.id .. "`", 3)
  end
  by_id[record.id] = record
  casefolded[folded] = record
  records[#records + 1] = record
end

--- Resolve `files` into normalized records.
---
--- config = {
---   roots = {{ path = "src", namespace = "app", target = "client",
---              update = "hot", effects = "safe", transforms = { lua = "lua", luax = "luax" } }},
---   entries = {{ id = "app", path = "src/App.luax" }},
--- }
---
--- Roots define a mechanical namespace only. Entries are ordinary overrides
--- for applications that intentionally expose a stable public module name.
function M.resolve(config, files)
  expect(type(config) == "table", "hydronium.source_topology: config must be a table")
  expect(type(files) == "table", "hydronium.source_topology: files must be a list")
  local roots = config.roots or {}
  expect(type(roots) == "table", "hydronium.source_topology: roots must be a list")

  local normalized_roots = {}
  for index, root in ipairs(roots) do
    expect(type(root) == "table", "hydronium.source_topology: root #" .. index .. " must be a table")
    local transforms = root.transforms or { lua = "lua", luax = "luax" }
    expect(type(transforms) == "table", "hydronium.source_topology: root.transforms must be a table")
    local namespace = root.namespace
    if namespace ~= nil then module_id(namespace, "root.namespace") end
    local target, update, effects = root.target or "client", root.update or "hot", root.effects or "restart"
    expect(valid_target[target], "hydronium.source_topology: unknown target `" .. tostring(target) .. "`")
    expect(valid_update[update], "hydronium.source_topology: unknown update policy `" .. tostring(update) .. "`")
    expect(valid_effects[effects], "hydronium.source_topology: unknown effects policy `" .. tostring(effects) .. "`")
    normalized_roots[#normalized_roots + 1] = {
      path = project_path(root.path, "root.path"), namespace = namespace,
      transforms = transforms, target = target, update = update, effects = effects, tags = root.tags or {},
    }
  end

  local candidates = {}
  for _, raw_path in ipairs(files) do
    local path = project_path(raw_path, "file path")
    for _, root in ipairs(normalized_roots) do
      local relative = under(path, root.path)
      local transform = relative and root.transforms[extension(path)]
      if relative and relative ~= "" and transform then
        expect(not candidates[path], "hydronium.source_topology: source path matches more than one root: " .. path)
        local stem = relative:gsub("%.[%a%d_]+$", ""):gsub("/", ".")
        local id = root.namespace and (root.namespace .. "." .. stem) or stem
        candidates[path] = { id = module_id(id, "derived module id"), path = path,
          transform = transform, target = root.target, update = root.update,
          effects = root.effects, tags = root.tags }
      end
    end
  end

  local entries = config.entries or {}
  expect(type(entries) == "table", "hydronium.source_topology: entries must be a list")
  for index, entry in ipairs(entries) do
    expect(type(entry) == "table", "hydronium.source_topology: entry #" .. index .. " must be a table")
    local path = project_path(entry.path, "entry.path")
    local record = candidates[path]
    expect(record, "hydronium.source_topology: entry path is not matched by a root: " .. path)
    record.id = module_id(entry.id, "entry.id")
    if entry.target then expect(valid_target[entry.target], "hydronium.source_topology: invalid entry target"); record.target = entry.target end
    if entry.update then expect(valid_update[entry.update], "hydronium.source_topology: invalid entry update"); record.update = entry.update end
    if entry.effects then expect(valid_effects[entry.effects], "hydronium.source_topology: invalid entry effects"); record.effects = entry.effects end
    if entry.transform then record.transform = entry.transform end
    if entry.tags then record.tags = entry.tags end
  end

  local paths, records, by_id, casefolded = {}, {}, {}, {}
  for path in pairs(candidates) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do add_record(records, by_id, casefolded, candidates[path]) end
  table.sort(records, function(a, b) return a.id < b.id end)
  return records
end

return M
