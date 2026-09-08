--[[
  Hydronium LUAX Formatter
  Complies with Amendment 7:
  - Idempotent CST pretty-printer: format(format(x)) == format(x)
--]]

local parser = require("hydronium_luax.parser")
local printer = require("hydronium_luax.formatter.printer")

local formatter = {}

--- Formats LUAX source code or AST.
--- @param source_or_ast string|table LUAX source string or parsed Program AST
--- @param options table? Formatting options (indent_str, max_line_length)
--- @return string Formatted LUAX code
function formatter.format(source_or_ast, options)
  options = options or {}
  local ast_root
  if type(source_or_ast) == "string" then
    ast_root = parser.parse(source_or_ast, options.filename or "<formatted>")
  else
    ast_root = source_or_ast
  end

  return printer.print(ast_root, options)
end

return formatter
