--[[
  hydronium.core.flavor_files -- choose Moonstone flavor variant files for
  the browser engines.

  Moonstone lets a package ship `compat@lua54.lua` beside `compat.lua`;
  `moon sync` projects one of them under the plain name for the HOST
  interpreter. The browser runs Lua 5.4 (lua-wasm, Wasmoon) whatever the
  host is, so every path that collects Lua for the browser (the dev
  manifest, the Ballad client bundle, the DOM Lab bundle) picks files with
  this module instead of trusting the host's choice:

    * `name@lua54.ext` wins over `name.ext` when both are readable;
    * any other variant (`@luajit`, `@lua51`, `@linux`, ...) never applies.

  Tag rules mirror `moonstone.variants` (the generated module is not
  required here, so this works with older moon releases and outside
  Moonstone). Because a dependency's environment keeps only the host's pick,
  Hydronium itself ships no variant other than `@lua54`; see
  docs/LUA_FLAVORS.md.
--]]

local M = {}

M.BROWSER_TAG = "lua54"

local DIMENSION = {}
for _, tag in ipairs({ "lua51", "lua52", "lua53", "lua54", "lua55", "luajit", "luau" }) do DIMENSION[tag] = 1 end
for _, tag in ipairs({ "linux", "macos", "windows", "freebsd" }) do DIMENSION[tag] = 2 end
for _, tag in ipairs({ "x86_64", "aarch64", "riscv64" }) do DIMENSION[tag] = 3 end

--- Split `stem@tag@tag` into its stem and tags when every tag is a known
--- flavor tag in dimension order; nil for an ordinary name.
--- @param name string module id or file name without extension
--- @return string|nil stem, string[]|nil tags
local function split(name)
  local stem, rest = name:match("^([^@]+)(@.+)$")
  if not stem then return nil end
  local tags, previous = {}, 0
  for tag in rest:gmatch("@([^@]*)") do
    local dimension = DIMENSION[tag]
    if not dimension or dimension <= previous then return nil end
    previous = dimension
    tags[#tags + 1] = tag
  end
  return stem, tags
end

--- @param tags string[]
--- @return boolean
function M.matches_browser(tags)
  return #tags == 1 and tags[1] == M.BROWSER_TAG
end

--- Parse a module id such as `hydronium.compat@lua54`.
--- @return string|nil base_id, string[]|nil tags
function M.split_module_id(id)
  return split(id)
end

--- Parse a file name such as `compat@lua54.lua` (directories allowed).
--- @return string|nil base_path, string[]|nil tags
function M.split_file(path)
  local dir, file = path:match("^(.-)([^/\\]*)$")
  local base, ext = file:match("^(.+)(%.[^.@/\\]+)$")
  if not base then return nil end
  local stem, tags = split(base)
  if not stem then return nil end
  return dir .. stem .. ext, tags
end

local function readable(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

--- The file the browser should load in place of `path`: its `@lua54`
--- sibling when there is one, else `path` itself.
--- @param path string
--- @return string
function M.browser_path(path)
  local dir, file = path:match("^(.-)([^/\\]*)$")
  local base, ext = file:match("^(.+)(%.[^.@/\\]+)$")
  if not base or split(base) then return path end
  local variant = dir .. base .. "@" .. M.BROWSER_TAG .. ext
  if readable(variant) then return variant end
  return path
end

--- `package.searchpath` for the browser flavor: per template, the `@lua54`
--- file first, then the plain one.
--- @param id string
--- @param path? string defaults to package.path
--- @return string|nil
function M.searchpath(id, path)
  path = path or package.path
  local relative = id:gsub("%.", "/")
  for template in path:gmatch("[^;]+") do
    local filename = template:gsub("%?", relative)
    local chosen = M.browser_path(filename)
    if chosen ~= filename or readable(filename) then return chosen end
  end
  return nil
end

--- Collapse a list of `{ module_id = ... }` records the way the browser
--- sees them: a `<id>@lua54` record replaces `<id>`, and records for other
--- flavors are dropped. Order is preserved; records are not copied.
--- @generic T: { module_id: string }
--- @param records T[]
--- @return T[]
function M.select_browser_modules(records)
  local winners = {}
  for _, record in ipairs(records) do
    local base, tags = split(record.module_id)
    if base and M.matches_browser(tags) then winners[base] = record end
  end
  local out = {}
  for _, record in ipairs(records) do
    local base, tags = split(record.module_id)
    if base then
      if M.matches_browser(tags) then
        record.module_id = base
        out[#out + 1] = record
      end
    elseif not winners[record.module_id] then
      out[#out + 1] = record
    end
  end
  return out
end

return M
