--[[
  hydronium_luax.dialects -- the one place that decides which source files
  LUAX compiles, and with what.

    .luax       LUAX (Lua + elements)       hydronium_luax.compiler
    .md, .mdx   Markdown component modules  hydronium_luax.markdown

  The loader's searcher, the Ballad compile plugin, the dev module route, the
  client manifest and Lab all ask here instead of matching extensions
  themselves, so a new dialect is added once.
]]
local M = {}

--- Extensions in the order `require` tries them after plain `.lua`.
M.EXTENSIONS = { ".luax", ".md", ".mdx" }

local BY_EXTENSION = { luax = "luax", md = "markdown", mdx = "markdown" }

--- The dialect of a path, an extension (`"mdx"`, `".mdx"`) or a source
--- topology transform name; nil for plain Lua and anything unknown.
--- @param value string?
--- @return "luax"|"markdown"|nil
function M.of(value)
  if type(value) ~= "string" then return nil end
  local extension = value:match("%.([%w]+)$") or value
  return BY_EXTENSION[extension]
end

--- Does LUAX compile this path / extension / transform?
function M.compiles(value)
  return M.of(value) ~= nil
end

--- Compiles `source` with the dialect chosen by `options.filename`.
--- @param source string
--- @param options { filename: string, module_id?: string, development?: boolean, runtime?: string }
function M.compile(source, options)
  local dialect = M.of(options and options.filename)
  if dialect == "luax" then return require("hydronium_luax.compiler").compile(source, options) end
  if dialect == "markdown" then return require("hydronium_luax.markdown").compile(source, options) end
  error("hydronium_luax.dialects: no LUAX dialect for '" .. tostring(options and options.filename) .. "'", 2)
end

return M
