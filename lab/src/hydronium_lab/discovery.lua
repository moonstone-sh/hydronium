-- Pure convention planner and binder. Hosts enumerate files and load modules;
-- this module makes both operations deterministic without depending on a
-- filesystem API or Meteorite.
local M = {}

local SUFFIXES = { ".stories.lua", ".stories.luax" }

local function normalize_path(path, label)
  if type(path) ~= "string" or path == "" then error(label .. " must be a non-empty path", 3) end
  path = path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+", "/")
  if path:match("^/") or path:match("^%a:/") or path:find("[%z\r\n]") then
    error(label .. " must be project-relative", 3)
  end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then error(label .. " escapes the project", 3) end
  end
  return path:gsub("/$", "")
end

local function under(path, root)
  if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
  return nil
end

local function normalize_roots(roots)
  local normalized = {}
  for index, root in ipairs(roots) do
    normalized[index] = normalize_path(root, "hydronium_lab.discovery: root")
  end
  for left = 1, #normalized do
    for right = left + 1, #normalized do
      local a, b = normalized[left], normalized[right]
      if a == b or under(a, b) or under(b, a) then
        error("hydronium_lab.discovery: roots must not duplicate or overlap: '" .. a .. "' and '" .. b .. "'", 3)
      end
    end
  end
  return normalized
end

local function story_suffix(path)
  for _, suffix in ipairs(SUFFIXES) do
    if path:sub(-#suffix) == suffix then return suffix end
  end
end

local function slug(segment)
  local value = segment:gsub("([%l%d])([%u])", "%1-%2"):lower():gsub("[^a-z0-9]+", "-")
  value = value:gsub("^%-+", ""):gsub("%-+$", "")
  if value == "" then error("hydronium_lab.discovery: path segment has no portable id: " .. segment, 3) end
  return value
end

local function prefix_for(relative, suffix)
  local stem = relative:sub(1, #relative - #suffix)
  local parts = {}
  for part in stem:gmatch("[^/]+") do parts[#parts + 1] = slug(part) end
  return table.concat(parts, "/"), stem
end

local function merge(left, right)
  local out = {}
  for key, value in pairs(left or {}) do out[key] = value end
  for key, value in pairs(right or {}) do out[key] = value end
  return out
end

--- Plan convention modules from an unordered project-relative path list.
--- @param paths string[]
--- @param opts? {roots?: string[]}
function M.plan(paths, opts)
  opts = opts or {}
  if type(paths) ~= "table" then error("hydronium_lab.discovery.plan: paths must be a list", 2) end
  local roots = opts.roots or { "src" }
  local normalized_roots = normalize_roots(roots)
  local records, by_path, by_folded_stem = {}, {}, {}
  for _, raw in ipairs(paths) do
    local path = normalize_path(raw, "hydronium_lab.discovery: file")
    local suffix = story_suffix(path)
    if suffix then
      local matched
      for _, root in ipairs(normalized_roots) do
        local relative = under(path, root)
        if relative then
          if matched then error("hydronium_lab.discovery: story matches more than one root: " .. path, 2) end
          local id_prefix, stem = prefix_for(relative, suffix)
          matched = { path = path, root = root, relative = relative, stem = stem,
            suffix = suffix, transform = suffix == ".stories.luax" and "luax" or "lua", id_prefix = id_prefix }
        end
      end
      if matched then
        if by_path[path] then error("hydronium_lab.discovery: duplicate input path: " .. path, 2) end
        local folded = (matched.root .. "/" .. matched.stem):lower()
        local prior = by_folded_stem[folded]
        if prior then
          error("hydronium_lab.discovery: story stem collision between '" .. prior.path .. "' and '" .. path .. "'", 2)
        end
        by_path[path], by_folded_stem[folded] = matched, matched
        records[#records + 1] = matched
      end
    end
  end
  table.sort(records, function(a, b) return a.path < b.path end)
  return records
end

--- Bind a loaded convention module to its path-derived id namespace.
--- Existing explicit stories/registries remain accepted unchanged.
function M.bind(record, value)
  local lab = require("hydronium_lab")
  if type(value) ~= "table" then error("hydronium_lab.discovery: " .. record.path .. " must return a Lab value", 2) end
  if value._kind == "hydronium.lab.story" or value._kind == "hydronium.lab.registry" then return value end
  if value._kind ~= "hydronium.lab.collection" then
    error("hydronium_lab.discovery: " .. record.path .. " must return lab.collection, lab.story, or lab.registry", 2)
  end
  local entries, keys = {}, {}
  for key in pairs(value.stories) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local variant = value.stories[key]
    local args = merge(value.args, variant.args)
    local renderer = variant.render or value.render
    if renderer == nil then
      local component = variant.component or value.component
      renderer = function(current_args)
        return require("hydronium").h(component, current_args)
      end
    end
    entries[#entries + 1] = lab.story({
      id = variant.id or (record.id_prefix .. "--" .. key),
      title = variant.title or key,
      group = variant.group or value.title or record.stem,
      description = variant.description,
      args = args,
      controls = merge(value.controls, variant.controls),
      sizes = variant.sizes or value.sizes,
      color = variant.color or value.color,
      interactions = variant.interactions,
      render = renderer,
      source = { path = record.path, key = key },
    })
  end
  return lab.registry(entries)
end

--- Load and combine planned records with an injected compiler/loader.
--- `load(record)` returns the convention module's value.
function M.registry(records, load)
  if type(load) ~= "function" then error("hydronium_lab.discovery.registry: load callback is required", 2) end
  local lab, entries, ids = require("hydronium_lab"), {}, {}
  for _, record in ipairs(records) do
    local bound = M.bind(record, load(record))
    local stories = bound._kind == "hydronium.lab.registry" and bound.stories or { bound }
    for _, story in ipairs(stories) do
      local folded = story.id:lower()
      local prior = ids[folded]
      if prior then
        error("hydronium_lab.discovery: story id collision '" .. story.id .. "' between '"
          .. tostring(prior.source and prior.source.path or "explicit registry") .. "' and '"
          .. tostring(story.source and story.source.path or record.path) .. "'", 2)
      end
      ids[folded], entries[#entries + 1] = story, story
    end
  end
  table.sort(entries, function(a, b)
    local ag, bg = a.group or "", b.group or ""
    if ag ~= bg then return ag < bg end
    if a.title ~= b.title then return a.title < b.title end
    return a.id < b.id
  end)
  return lab.registry(entries)
end

return M
