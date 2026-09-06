--[[
  Hydronium LUAX Compiler
  Compiles .luax AST / source to standard Lua 5.1-5.4 / LuaJIT code.
  Complies with:
  - Amendment 4: Spread Operator Lowering (__luax.spread left-to-right evaluation)
  - Amendment 5: Schema Provider / Environment Protocol (zero hardcoded HTML tags or module names)
  - Amendment 6: UTF-8 Byte & Column Mapping in Source Maps (V3 Base64 VLQ)
--]]

local parser_mod = require("hydronium.luax.parser")
local env_mod = require("hydronium.luax.environment")
local sourcemap_mod = require("hydronium.luax.compiler.sourcemap")

local compiler = {}

local LUA_KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

local CodeEmitter = {}
CodeEmitter.__index = CodeEmitter

function CodeEmitter.new(source_filename, source_content, env, options)
  local self = setmetatable({}, CodeEmitter)
  self.source_filename = source_filename or "input.luax"
  self.source_content = source_content or ""
  self.env = env or env_mod.get_current()
  self.options = options or {}

  self.buffer = {}
  self.gen_line = 1
  self.gen_col = 1
  self.indent_level = 0
  self.indent_str = "  "

  -- Detect pragma from source if present
  local pragma = options.pragma or options.jsxFactory
  if not pragma and self.source_content then
    pragma = self.source_content:match("@jsx%s+([%w_%.]+)")
  end

  local runtime_target = options.runtime or (pragma and "custom") or "universal"
  if pragma then
    self.factory_name = pragma
    local base = pragma:match("^(.-)%.") or "H"
    self.fragment_name = options.jsxFragment or (pragma .. "(" .. base .. ".Fragment")
    self.spread_name = options.jsxSpread or (base .. ".spread or __luax.spread")
  elseif runtime_target == "starship" then
    self.factory_name = "Starship.createElement"
    self.fragment_name = "Starship.createElement(Starship.Fragment"
    self.spread_name = options.jsxSpread or "Starship.spread or __luax.spread"
  elseif runtime_target == "hydronium" then
    self.factory_name = options.h or "H.h"
    self.fragment_name = options.fragment and (options.h .. "(" .. options.fragment) or "H.h(H.Fragment"
    self.spread_name = options.jsxSpread or "__luax.spread"
  elseif runtime_target == "direct" then
    self.factory_name = "direct"
    self.fragment_name = options.fragment or "H.Fragment"
    self.spread_name = options.jsxSpread or "__luax.spread"
  else
    self.factory_name = options.jsxFactory or self.env.factory
    self.fragment_name = options.jsxFragment or self.env.fragment
    self.spread_name = options.jsxSpread or self.env.spread
  end

  self.sm = sourcemap_mod.create({
    file = options.output_filename or (self.source_filename:gsub("%.luax$", ".lua")),
  })
  self.source_idx = self.sm:add_source(self.source_filename, self.source_content)

  return self
end

function CodeEmitter:write(str, orig_loc)
  if not str or #str == 0 then return end

  if orig_loc and orig_loc.start then
    self.sm:add_mapping(
      self.gen_line,
      self.gen_col,
      orig_loc.start.line,
      orig_loc.start.column,
      self.source_idx
    )
  end

  table.insert(self.buffer, str)

  -- Track generated lines and columns
  for i = 1, #str do
    local ch = str:sub(i, i)
    if ch == "\n" then
      self.gen_line = self.gen_line + 1
      self.gen_col = 1
    else
      self.gen_col = self.gen_col + 1
    end
  end
end

function CodeEmitter:newline()
  self:write("\n")
  if self.indent_level > 0 then
    self:write(string.rep(self.indent_str, self.indent_level))
  end
end

function CodeEmitter:indent()
  self.indent_level = self.indent_level + 1
end

function CodeEmitter:dedent()
  if self.indent_level > 0 then
    self.indent_level = self.indent_level - 1
  end
end

function CodeEmitter:get_output()
  return table.concat(self.buffer)
end

-- =========================================================================
-- Node Compilation Dispatcher
-- =========================================================================

function CodeEmitter:emit_node(node)
  if not node then return end

  local node_type = node.type
  local is_statement = (node_type:match("Statement$") ~= nil) or
                       (node_type:match("Declaration$") ~= nil) or
                       (node_type == "JSXElement")

  if is_statement and self.options.virtual_luals and node.loc and node.loc.start and node.loc.start.line then
    local orig_line = node.loc.start.line
    if self.gen_line < orig_line then
      self:write(string.rep("\n", orig_line - self.gen_line))
    end
  end

  if node_type == "Program" then
    self:emit_program(node)
  elseif node_type == "LocalStatement" then
    self:emit_local_statement(node)
  elseif node_type == "AssignmentStatement" then
    self:emit_assignment_statement(node)
  elseif node_type == "ExpressionStatement" then
    self:emit_expression_statement(node)
  elseif node_type == "ReturnStatement" then
    self:emit_return_statement(node)
  elseif node_type == "FunctionDeclaration" then
    self:emit_function_declaration(node)
  elseif node_type == "LocalFunctionDeclaration" then
    self:emit_local_function_declaration(node)
  elseif node_type == "IfStatement" then
    self:emit_if_statement(node)
  elseif node_type == "WhileStatement" then
    self:emit_while_statement(node)
  elseif node_type == "RepeatStatement" then
    self:emit_repeat_statement(node)
  elseif node_type == "ForNumericStatement" then
    self:emit_for_numeric_statement(node)
  elseif node_type == "ForGenericStatement" then
    self:emit_for_generic_statement(node)
  elseif node_type == "DoStatement" then
    self:emit_do_statement(node)
  elseif node_type == "BreakStatement" then
    self:write("break", node.loc)
  elseif node_type == "JSXElement" then
    self:emit_jsx_element(node)
  elseif node_type == "JSXFragment" then
    self:emit_jsx_fragment(node)
  elseif node_type == "Identifier" then
    self:write(node.name, node.loc)
  elseif node_type == "StringLiteral" then
    self:write(node.raw or string.format("%q", node.value), node.loc)
  elseif node_type == "NumberLiteral" then
    self:write(tostring(node.raw or node.value), node.loc)
  elseif node_type == "BooleanLiteral" then
    self:write(node.value and "true" or "false", node.loc)
  elseif node_type == "NilLiteral" then
    self:write("nil", node.loc)
  elseif node_type == "VarargLiteral" then
    self:write("...", node.loc)
  elseif node_type == "TableConstructor" then
    self:emit_table_constructor(node)
  elseif node_type == "BinaryExpression" then
    self:emit_binary_expression(node)
  elseif node_type == "UnaryExpression" then
    self:emit_unary_expression(node)
  elseif node_type == "CallExpression" then
    self:emit_call_expression(node)
  elseif node_type == "MethodCallExpression" then
    self:emit_method_call_expression(node)
  elseif node_type == "MemberExpression" or node_type == "JSXMemberExpression" then
    self:emit_member_expression(node)
  elseif node_type == "FunctionExpression" then
    self:emit_function_expression(node)
  elseif node_type == "ParenthesizedExpression" then
    self:write("(")
    self:emit_node(node.expression)
    self:write(")")
  elseif node_type == "Comment" then
    self:write(node.text, node.loc)
  else
    error("Unknown AST node type: " .. tostring(node_type))
  end
end

function CodeEmitter:emit_program(node)
  for i, stmt in ipairs(node.body) do
    self:emit_node(stmt)
    if i < #node.body then
      self:newline()
    end
  end
end

-- =========================================================================
-- JSX Elements Lowering
-- =========================================================================

function CodeEmitter:is_intrinsic_tag(name_node)
  if name_node.type == "Identifier" then
    if name_node.name:find("%-") then
      return true
    end
    return self.env:is_intrinsic(name_node.name)
  end
  return false
end

function CodeEmitter:emit_jsx_element(node)
  local opening = node.opening_element
  local name_node = opening.name
  local is_intrinsic = self:is_intrinsic_tag(name_node)

  if self.options.virtual_luals then
    if is_intrinsic then
      self:write("__luax_intrinsic." .. name_node.name .. "(", node.loc)
    else
      self:write("__luax_component(", node.loc)
      self:emit_node(name_node)
      self:write(", ")
    end
  elseif self.factory_name == "direct" then
    self:emit_node(name_node)
    self:write("(", node.loc)
  else
    self:write(self.factory_name .. "(", node.loc)
    if is_intrinsic then
      self:write(string.format("%q", name_node.name), name_node.loc)
    else
      self:emit_node(name_node)
    end
    self:write(", ")
  end

  -- Props argument (handles Amendment 4 Spread Operator Lowering)
  self:emit_jsx_props(opening.attributes, node.loc)

  -- Children arguments
  local children = self:filter_jsx_children(node.children)
  for _, child in ipairs(children) do
    self:write(", ")
    self:emit_jsx_child(child)
  end

  self:write(")")
end

function CodeEmitter:emit_jsx_fragment(node)
  if self.options.virtual_luals then
    self:write("__luax_fragment(", node.loc)
    local children = self:filter_jsx_children(node.children)
    for i, child in ipairs(children) do
      if i > 1 then self:write(", ") end
      self:emit_jsx_child(child)
    end
    self:write(")")
  else
    if self.fragment_name:find("%(") then
      self:write(self.fragment_name .. ", nil", node.loc)
    else
      self:write(self.fragment_name .. "(nil", node.loc)
    end
    local children = self:filter_jsx_children(node.children)
    for _, child in ipairs(children) do
      self:write(", ")
      self:emit_jsx_child(child)
    end
    self:write(")")
  end
end

--- Filters out comments and empty whitespace children between tags
function CodeEmitter:filter_jsx_children(children)
  local filtered = {}
  for _, child in ipairs(children or {}) do
    if child.type == "JSXComment" then
      -- Skip embedded comments in compiled output
    elseif child.type == "JSXText" then
      -- Only include if text contains non-whitespace characters
      if child.value and child.value:match("%S") then
        table.insert(filtered, child)
      end
    else
      table.insert(filtered, child)
    end
  end
  return filtered
end

function CodeEmitter:emit_jsx_child(child)
  if child.type == "JSXText" then
    self:write(string.format("%q", child.value), child.loc)
  elseif child.type == "JSXExpressionContainer" then
    self:emit_node(child.expression)
  elseif child.type == "JSXElement" or child.type == "JSXFragment" then
    self:emit_node(child)
  end
end

--- Emits JSX attributes.
--- When spreads are present: lowers to __luax.spread({ a = 1 }, props, { b = 2 })
--- When no spreads are present: directly emits table literal { a = 1, b = 2 }
function CodeEmitter:emit_jsx_props(attributes, loc)
  local has_attrs = attributes and #attributes > 0
  local has_spread = false
  if has_attrs then
    for _, attr in ipairs(attributes) do
      if attr.type == "JSXSpreadAttribute" then
        has_spread = true
        break
      end
    end
  end

  if not has_attrs and not self.options.development then
    self:write("nil")
    return
  end

  if not has_spread then
    -- Clean table literal without spread overhead
    self:emit_attr_table(attributes or {}, loc)
    return
  end

  -- Group into chunks of static attributes and spread arguments
  self:write(self.spread_name .. "(")
  local chunks = {}
  local current_static = {}

  for _, attr in ipairs(attributes) do
    if attr.type == "JSXSpreadAttribute" then
      if #current_static > 0 then
        table.insert(chunks, { type = "static", attrs = current_static })
        current_static = {}
      end
      table.insert(chunks, { type = "spread", expr = attr.argument })
    else
      table.insert(current_static, attr)
    end
  end

  if #current_static > 0 then
    table.insert(chunks, { type = "static", attrs = current_static })
  end

  if self.options.development and loc and loc.start then
    if #chunks > 0 and chunks[#chunks].type == "static" then
      chunks[#chunks].dev_loc = loc
    else
      table.insert(chunks, { type = "static", attrs = {}, dev_loc = loc })
    end
  end

  for i, chunk in ipairs(chunks) do
    if i > 1 then self:write(", ") end
    if chunk.type == "static" then
      self:emit_attr_table(chunk.attrs, chunk.dev_loc)
    else
      self:emit_node(chunk.expr)
    end
  end

  self:write(")")
end

function CodeEmitter:emit_attr_table(attrs, loc)
  self:write("{ ")
  local count = 0
  for i, attr in ipairs(attrs) do
    if i > 1 then self:write(", ") end
    count = count + 1
    local name = attr.name
    -- If attribute contains hyphen, matches a Lua keyword, or non-ident chars, use string key ["name"]
    if name:find("%-") or LUA_KEYWORDS[name] or not name:match("^[_%a][_%w]*$") then
      self:write(string.format("[%q]", name), attr.loc)
    else
      self:write(name, attr.loc)
    end

    self:write(" = ")

    if attr.value.type == "JSXExpressionContainer" then
      self:emit_node(attr.value.expression)
    else
      self:emit_node(attr.value)
    end
  end

  if self.options.development and loc and loc.start then
    if count > 0 then self:write(", ") end
    self:write(string.format('__source = { file = %q, line = %d, col = %d }',
      self.source_filename, loc.start.line, loc.start.column))
  end

  self:write(" }")
end

-- =========================================================================
-- Standard Lua Statements and Expressions
-- =========================================================================

function CodeEmitter:emit_local_statement(node)
  self:write("local ", node.loc)
  for i, name in ipairs(node.names) do
    if i > 1 then self:write(", ") end
    self:emit_node(name)
  end

  if #node.values > 0 then
    self:write(" = ")
    for i, val in ipairs(node.values) do
      if i > 1 then self:write(", ") end
      self:emit_node(val)
    end
  end
end

function CodeEmitter:emit_assignment_statement(node)
  for i, target in ipairs(node.targets) do
    if i > 1 then self:write(", ") end
    self:emit_node(target)
  end

  self:write(" = ")

  for i, val in ipairs(node.values) do
    if i > 1 then self:write(", ") end
    self:emit_node(val)
  end
end

function CodeEmitter:emit_expression_statement(node)
  self:emit_node(node.expression)
end

function CodeEmitter:emit_return_statement(node)
  self:write("return", node.loc)
  if #node.values > 0 then
    self:write(" ")
    for i, val in ipairs(node.values) do
      if i > 1 then self:write(", ") end
      self:emit_node(val)
    end
  end
end

function CodeEmitter:emit_function_declaration(node)
  self:write("function ", node.loc)
  self:emit_node(node.name)
  self:write("(")
  for i, p in ipairs(node.params) do
    if i > 1 then self:write(", ") end
    self:emit_node(p)
  end
  if node.is_vararg then
    if #node.params > 0 then self:write(", ") end
    self:write("...")
  end
  self:write(")")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:emit_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function CodeEmitter:emit_local_function_declaration(node)
  self:write("local function ", node.loc)
  self:emit_node(node.name)
  self:write("(")
  for i, p in ipairs(node.params) do
    if i > 1 then self:write(", ") end
    self:emit_node(p)
  end
  if node.is_vararg then
    if #node.params > 0 then self:write(", ") end
    self:write("...")
  end
  self:write(")")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:emit_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function CodeEmitter:emit_if_statement(node)
  for i, clause in ipairs(node.clauses) do
    if i == 1 then
      self:write("if ", node.loc)
    else
      self:write("elseif ")
    end
    self:emit_node(clause.condition)
    self:write(" then")
    self:indent()
    for _, stmt in ipairs(clause.body) do
      self:newline()
      self:emit_node(stmt)
    end
    self:dedent()
    self:newline()
  end

  if node.else_body then
    self:write("else")
    self:indent()
    for _, stmt in ipairs(node.else_body) do
      self:newline()
      self:emit_node(stmt)
    end
    self:dedent()
    self:newline()
  end

  self:write("end")
end

function CodeEmitter:emit_while_statement(node)
  self:write("while ", node.loc)
  self:emit_node(node.condition)
  self:write(" do")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:emit_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function CodeEmitter:emit_repeat_statement(node)
  self:write("repeat", node.loc)
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:emit_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("until ")
  self:emit_node(node.condition)
end

function CodeEmitter:emit_for_numeric_statement(node)
  self:write("for ", node.loc)
  self:emit_node(node.var)
  self:write(" = ")
  self:emit_node(node.start)
  self:write(", ")
  self:emit_node(node.stop)
  if node.step then
    self:write(", ")
    self:emit_node(node.step)
  end
  self:write(" do")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:emit_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function CodeEmitter:emit_for_generic_statement(node)
  self:write("for ", node.loc)
  for i, v in ipairs(node.vars) do
    if i > 1 then self:write(", ") end
    self:emit_node(v)
  end
  self:write(" in ")
  for i, iter in ipairs(node.iterators) do
    if i > 1 then self:write(", ") end
    self:emit_node(iter)
  end
  self:write(" do")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:emit_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function CodeEmitter:emit_do_statement(node)
  self:write("do", node.loc)
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:emit_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function CodeEmitter:emit_binary_expression(node)
  self:write("(")
  self:emit_node(node.left)
  self:write(" " .. node.operator .. " ")
  self:emit_node(node.right)
  self:write(")")
end

function CodeEmitter:emit_unary_expression(node)
  self:write(node.operator)
  if node.operator == "not" then self:write(" ") end
  self:write("(")
  self:emit_node(node.argument)
  self:write(")")
end

function CodeEmitter:emit_call_expression(node)
  self:emit_node(node.callee)
  self:write("(")
  for i, arg in ipairs(node.arguments) do
    if i > 1 then self:write(", ") end
    self:emit_node(arg)
  end
  self:write(")")
end

function CodeEmitter:emit_method_call_expression(node)
  self:emit_node(node.receiver)
  self:write(":" .. node.method .. "(")
  for i, arg in ipairs(node.arguments) do
    if i > 1 then self:write(", ") end
    self:emit_node(arg)
  end
  self:write(")")
end

function CodeEmitter:emit_member_expression(node)
  self:emit_node(node.object)
  if node.computed then
    self:write("[")
    self:emit_node(node.property)
    self:write("]")
  else
    self:write(".")
    self:emit_node(node.property)
  end
end

function CodeEmitter:emit_table_constructor(node)
  self:write("{")
  for i, field in ipairs(node.fields) do
    if i > 1 then self:write(", ") end
    if field.key then
      if field.key.type == "StringLiteral" and field.key.value:match("^[_%a][_%w]*$") then
        self:write(field.key.value)
      else
        self:write("[")
        self:emit_node(field.key)
        self:write("]")
      end
      self:write(" = ")
    end
    self:emit_node(field.value)
  end
  self:write("}")
end

function CodeEmitter:emit_function_expression(node)
  self:write("function(", node.loc)
  for i, p in ipairs(node.params) do
    if i > 1 then self:write(", ") end
    self:emit_node(p)
  end
  if node.is_vararg then
    if #node.params > 0 then self:write(", ") end
    self:write("...")
  end
  self:write(")")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:emit_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

--- Main compile function
--- @param source_or_ast string|table LUAX source code or parsed AST Program
--- @param options table? Compiler configuration
--- @return table Result with .code, .sourcemap, and .map_json
function compiler.compile(source_or_ast, options)
  options = options or {}
  local ast_root
  local source_content = ""
  local filename = options.filename or "input.luax"

  if type(source_or_ast) == "string" then
    source_content = source_or_ast
    ast_root = parser_mod.parse(source_or_ast, filename)
  else
    ast_root = source_or_ast
  end

  local env = options.env or env_mod.get_current()
  local emitter = CodeEmitter.new(filename, source_content, env, options)

  emitter:emit_node(ast_root)

  local code = emitter:get_output()
  local map = emitter.sm

  if options.inline_sourcemap then
    code = code .. "\n" .. map:to_comment()
  end

  return {
    code = code,
    sourcemap = map,
    map_json = map:to_json(),
  }
end

return compiler
