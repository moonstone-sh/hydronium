--[[
  Source-topology route adapter.

  This deliberately does not infer routes from directories or filenames.
  A project may use routes/, features/, layers/, or any other layout; only a
  normalized topology record carrying `tags.route` becomes a route here.
--]]

local M = {}

local function fail(message, level)
  error("hydronium_router.topology: " .. message, level or 3)
end

local function route_tag(record)
  local tags = record.tags
  if type(tags) ~= "table" then return nil end
  return tags.route
end

--- Lower tagged source-topology records to route declarations.
---
--- `tags.route` is either `false` (explicitly no route) or a table:
--- `{ path = "/posts/:id", id? = "post", target? = "client|server|shared",
---    meta? = {...} }`. The module is always the record's declared logical
--- identity; a route cannot smuggle in a filesystem-derived module ID.
function M.routes(records, opts)
  if type(records) ~= "table" then fail("routes(records) requires normalized topology records", 2) end
  opts = opts or {}
  local wanted_target = opts.target
  local result, ids, paths = {}, {}, {}
  for _, record in ipairs(records) do
    local tag = route_tag(record)
    if tag ~= nil and tag ~= false then
      if type(tag) ~= "table" then fail("tags.route for " .. tostring(record.id) .. " must be a table or false", 2) end
      if type(tag.path) ~= "string" or tag.path:sub(1, 1) ~= "/" then
        fail("tags.route.path for " .. tostring(record.id) .. " must be an absolute route path", 2)
      end
      local target = tag.target or record.target
      if target ~= "client" and target ~= "server" and target ~= "shared" then
        fail("tags.route.target for " .. tostring(record.id) .. " is invalid", 2)
      end
      if not wanted_target or wanted_target == target or target == "shared" then
        local id = tag.id or record.id
        if type(id) ~= "string" or id == "" then fail("tags.route.id for " .. tostring(record.id) .. " must be a non-empty string", 2) end
        if ids[id] then fail("duplicate route id " .. string.format("%q", id), 2) end
        if paths[tag.path] then fail("duplicate route path " .. string.format("%q", tag.path), 2) end
        local row = { id = id, path = tag.path, module = record.id, target = target, meta = tag.meta }
        result[#result + 1], ids[id], paths[tag.path] = row, true, true
      end
    end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

return M
