--[[
  Hydronium LUAX - Declarative JSX Compiler and Tooling for Lua
  Provides:
  - Context-aware modal lexer & parser (AST)
  - Compiler with Base64 VLQ source maps
  - Formatter with guaranteed idempotence: format(format(x)) == format(x)
  - Runtime ABI (__luax.spread, __luax.element, __luax.fragment)
  - Schema Provider / Environment Protocol (Environment<I>)
  - LuaLS virtual source lowering with 1:1 LSP coordinates
--]]

local ast = require("hydronium_luax.ast")
local lexer = require("hydronium_luax.lexer")
local parser = require("hydronium_luax.parser")
local compiler = require("hydronium_luax.compiler")
local environment = require("hydronium_luax.environment")
local runtime = require("hydronium_luax.runtime")
local formatter = require("hydronium_luax.formatter")
local sourcemap = require("hydronium_luax.compiler.sourcemap")
local luals = require("hydronium_luax.luals")
local loader = require("hydronium_luax.loader")

local Luax = {
  _VERSION = "0.1.0",
  _DESCRIPTION = "Declarative JSX dialect compiler and tooling for Hydronium Lua",

  -- AST & Parsing
  ast = ast,
  lexer = lexer,
  parser = parser,
  parse = parser.parse,

  -- Compiler & Code Generation
  compiler = compiler,
  compile = compiler.compile,
  sourcemap = sourcemap,

  -- Environment Protocol
  environment = environment,
  Environment = environment.Environment,

  -- Runtime ABI
  runtime = runtime,
  spread = runtime.spread,
  element = runtime.element,
  fragment = runtime.fragment,

  -- Tooling & Language Server
  formatter = formatter,
  format = formatter.format,
  luals = luals,
  virtual_source = luals.virtual_source,

  -- Serve-time loading: compile-and-run a `.luax` file on demand,
  -- cached by mtime (see hydronium_luax.loader's own doc comment).
  loader = loader,
  load_luax = loader.load,
}

return Luax
