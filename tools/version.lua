-- Hydronium versions: one number for the whole workspace (lockstep).
--
-- The root moonstone.toml's `version` is the release version. Every member
-- package carries the same version, every `hydronium/*` floor in create's
-- templates is `^<version>`, and the CLIs report it. Releases change versions
-- only through this script; see docs/VERSIONING.md.
--
--   moon exec -- luajit tools/version.lua check            copies agree with members
--   moon exec -- luajit tools/version.lua check --lockstep and every member equals the root
--   moon exec -- luajit tools/version.lua set 0.7.0        rewrite everything to 0.7.0
--
-- Run from the repository root. Also usable as a module (tests require it).

local M = {}

-- Not the global: test runners replace `assert`.
local function ensure(value, message)
  if not value then error(message or "assertion failed", 2) end
  return value
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, content)
  local f = ensure(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function lines_of(command)
  local out, handle = {}, ensure(io.popen(command))
  for line in handle:lines() do out[#out + 1] = line end
  handle:close()
  return out
end

--- The first `version = "..."` in a manifest's [package] table.
local function package_version(manifest)
  local package_table = manifest:match("%[package%](.-)\n%[") or manifest:match("%[package%](.*)$") or ""
  return package_table:match('\nversion = "([^"]+)"')
end

local function set_package_version(manifest, version)
  local head, body, tail = manifest:match("^(.-%[package%])(.-)(\n%[.*)$")
  if not head then
    head, body = manifest:match("^(.-%[package%])(.*)$")
    tail = ""
  end
  local replaced, count = body:gsub('\nversion = "[^"]+"', '\nversion = "' .. version .. '"', 1)
  ensure(count == 1, "no [package] version to replace")
  return head .. replaced .. tail
end

function M.members(root)
  root = root or "."
  local manifest = ensure(read(root .. "/moonstone.toml"), "run from the repository root")
  local members = {}
  for path in manifest:gmatch('%[%[orbits%.member%]%]%s*\nname = "[^"]+"%s*\npath = "([^"]+)"') do
    local text = read(root .. "/" .. path .. "/moonstone.toml")
    if text then
      members[#members + 1] = {
        path = path,
        name = text:match('\nname = "([^"]+)"'),
        version = package_version(text),
      }
    end
  end
  return members, package_version(manifest)
end

-- Places that repeat a member's version: `pattern` captures the text before
-- the version, the version, and the text after it.
M.CONSTANTS = {
  { file = "create/src/main.lua", member = "create", pattern = '(\nlocal VERSION = ")([^"]+)(")' },
  { file = "cli/src/main.lua", member = "cli", pattern = '(\nM%.VERSION = ")([^"]+)(")' },
}

local function create_sources(root)
  local files = lines_of('find "' .. root .. '/create/src" -name "*.lua" | sort')
  files[#files + 1] = root .. "/create/tests/create_spec.lua"
  return files
end

--- Every `hydronium/*` floor create writes into generated projects, and the
--- literal copies its tests assert. Calls `visit(file, line, package, version)`.
local function each_floor(root, visit)
  for _, file in ipairs(create_sources(root)) do
    local text = read(file) or ""
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    for i, line in ipairs(lines) do
      local floor = line:match('constraint = "%^(%d+%.%d+%.%d+)"')
      if floor then
        for j = i, math.max(1, i - 4), -1 do
          local name = lines[j]:match('name = "([^"]+)"')
          if name then
            local package = name:match("^hydronium/(.+)$")
            if package then visit(file, i, package, floor) end
            break
          end
        end
      end
      -- create_spec asserts generated manifests with escaped newlines.
      for package, floor in line:gmatch('name = "hydronium/([%w%-]+)"\\nconstraint = "%^(%d+%.%d+%.%d+)"') do
        visit(file, i, package, floor)
      end
    end
  end
end

local function member_dir(package)
  return package == "ballad" and "build" or package
end

--- Returns a list of human-readable problems (empty when consistent).
function M.check(root, options)
  root = root or "."
  options = options or {}
  local members, root_version = M.members(root)
  local by_dir, problems = {}, {}
  for _, member in ipairs(members) do by_dir[member.path] = member end

  if options.lockstep then
    for _, member in ipairs(members) do
      if member.version ~= root_version then
        problems[#problems + 1] = member.path .. "/moonstone.toml is " .. tostring(member.version)
          .. ", the workspace is " .. tostring(root_version)
      end
    end
  end

  each_floor(root, function(file, line, package, floor)
    local member = by_dir[member_dir(package)]
    if not member then
      problems[#problems + 1] = file .. ":" .. line .. ": hydronium/" .. package .. " is not a workspace member"
    elseif floor ~= member.version then
      problems[#problems + 1] = file .. ":" .. line .. ": hydronium/" .. package .. " floor ^" .. floor
        .. ", member is " .. member.version
    end
  end)

  for _, constant in ipairs(M.CONSTANTS) do
    local text = read(root .. "/" .. constant.file) or ""
    local _, found = text:match(constant.pattern)
    local expected = by_dir[constant.member] and by_dir[constant.member].version
    if found ~= expected then
      problems[#problems + 1] = constant.file .. ": reports " .. tostring(found) .. ", " .. constant.member
        .. " is " .. tostring(expected)
    end
  end
  return problems
end

--- Rewrites the workspace, every member, every floor and every constant.
function M.set(root, version)
  root = root or "."
  ensure(type(version) == "string" and version:match("^%d+%.%d+%.%d+$"), "version must be MAJOR.MINOR.PATCH")
  local changed = {}
  local function save(path, before, after)
    if before ~= after then write(path, after); changed[#changed + 1] = path end
  end

  local root_manifest = root .. "/moonstone.toml"
  local text = read(root_manifest)
  save(root_manifest, text, set_package_version(text, version))
  local members = M.members(root)
  for _, member in ipairs(members) do
    local path = root .. "/" .. member.path .. "/moonstone.toml"
    local before = read(path)
    save(path, before, set_package_version(before, version))
  end

  for _, file in ipairs(create_sources(root)) do
    local before = read(file) or ""
    local lines = {}
    for line in (before .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    lines[#lines] = nil
    for i, line in ipairs(lines) do
      if line:match('constraint = "%^%d+%.%d+%.%d+"') then
        for j = i, math.max(1, i - 4), -1 do
          local name = lines[j]:match('name = "([^"]+)"')
          if name then
            if name:match("^hydronium/") then
              lines[i] = line:gsub('constraint = "%^%d+%.%d+%.%d+"', 'constraint = "^' .. version .. '"', 1)
            end
            break
          end
        end
      end
      lines[i] = lines[i]:gsub('(name = "hydronium/[%w%-]+"\\nconstraint = "%^)%d+%.%d+%.%d+', "%1" .. version)
    end
    save(file, before, table.concat(lines, "\n") .. (before:sub(-1) == "\n" and "\n" or ""))
  end

  for _, constant in ipairs(M.CONSTANTS) do
    local path = root .. "/" .. constant.file
    local before = read(path) or ""
    save(path, before, (before:gsub(constant.pattern, function(prefix, _, suffix) return prefix .. version .. suffix end, 1)))
  end
  return changed
end

if arg and arg[0] and arg[0]:match("version%.lua$") then
  local command = arg[1]
  if command == "check" then
    local problems = M.check(".", { lockstep = arg[2] == "--lockstep" })
    for _, problem in ipairs(problems) do io.stderr:write(problem, "\n") end
    if #problems > 0 then os.exit(1) end
    local _, version = M.members(".")
    print("versions consistent" .. (arg[2] == "--lockstep" and (" at " .. version) or ""))
  elseif command == "set" and arg[2] then
    for _, path in ipairs(M.set(".", arg[2])) do print("updated " .. path) end
    local problems = M.check(".", { lockstep = true })
    for _, problem in ipairs(problems) do io.stderr:write(problem, "\n") end
    if #problems > 0 then os.exit(1) end
  else
    io.stderr:write("usage: luajit tools/version.lua check [--lockstep] | set MAJOR.MINOR.PATCH\n")
    os.exit(2)
  end
end

return M
