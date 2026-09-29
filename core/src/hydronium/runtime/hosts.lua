-- VM-local host capabilities. This module owns bindings, never process globals.
local M = {}
local installed = {}
local function demand(condition, message)
  if not condition then error(message, 3) end
  return condition
end
local function check(name, version)
  demand(type(name) == "string" and name:match("^[%a][%w_.%-]*$"), "host capability name must be a literal namespace")
  demand(type(version) == "number" and version >= 1 and version % 1 == 0, "host capability version must be a positive integer")
end
function M.install(name, version, bindings)
  check(name, version)
  demand(type(bindings) == "table", "host capability bindings must be a table")
  demand(not installed[name], "host capability already installed: " .. name)
  local copy = {}
  for key, fn in pairs(bindings) do
    demand(type(key) == "string" and type(fn) == "function", "host capability bindings must contain named functions")
    copy[key] = fn
  end
  local entry = { version = version, bindings = copy }
  installed[name] = entry
  -- An old owner cannot remove a later installation after its own release.
  local function release()
    if installed[name] == entry then installed[name] = nil; return true end
    return false
  end
  return copy, release
end
function M.get(name, version)
  check(name, version)
  local entry = installed[name]
  if not entry then return nil end
  demand(entry.version == version, "host capability version mismatch: " .. name .. " (expected " .. version .. ", installed " .. entry.version .. ")")
  return entry.bindings
end
function M.require(name, version)
  return demand(M.get(name, version), "host capability is not installed: " .. name .. "@" .. tostring(version))
end
function M.describe()
  local result = {}
  for name, entry in pairs(installed) do
    local methods = {}
    for method in pairs(entry.bindings) do methods[#methods + 1] = method end
    table.sort(methods)
    result[#result + 1] = { name = name, version = entry.version, methods = methods }
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end
return M
