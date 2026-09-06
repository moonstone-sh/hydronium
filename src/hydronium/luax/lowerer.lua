-- Lowerer module for Hydronium LUAX
-- Delegates to hydronium.luax.compiler for full AST lowering and code generation
local compiler = require("hydronium.luax.compiler")

local lowerer = {}

function lowerer.lower(ast_or_source, options)
  return compiler.compile(ast_or_source, options)
end

function lowerer.create(ast_or_source, options)
  return {
    lower = function()
      return compiler.compile(ast_or_source, options)
    end
  }
end

return lowerer
