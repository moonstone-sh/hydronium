--[[
  Hydronium LUAX CST / AST Pretty Printer
  Complies with Amendment 7:
  - Formatter Idempotence: format(format(x)) == format(x)
  - Canonical formatting for Lua 5.1-5.4 statements and LUAX JSX elements
--]]

local printer = {}

local Printer = {}
Printer.__index = Printer

function Printer.new(options)
  options = options or {}
  local self = setmetatable({}, Printer)
  self.indent_str = options.indent_str or "  "
  self.max_line_length = options.max_line_length or 80
  self.level = 0
  self.buf = {}
  return self
end

function Printer:write(str)
  if str and #str > 0 then
    table.insert(self.buf, str)
  end
end

function Printer:indent()
  self.level = self.level + 1
end

function Printer:dedent()
  if self.level > 0 then
    self.level = self.level - 1
  end
end

function Printer:newline()
  self:write("\n" .. string.rep(self.indent_str, self.level))
end

function Printer:get_result()
  return table.concat(self.buf)
end

function Printer:print_node(node)
  if not node then return end
  local t = node.type

  if t == "Program" then
    self:print_program(node)
  elseif t == "LocalStatement" then
    self:print_local_statement(node)
  elseif t == "AssignmentStatement" then
    self:print_assignment_statement(node)
  elseif t == "ExpressionStatement" then
    self:print_node(node.expression)
  elseif t == "ReturnStatement" then
    self:print_return_statement(node)
  elseif t == "FunctionDeclaration" then
    self:print_function_declaration(node)
  elseif t == "LocalFunctionDeclaration" then
    self:print_local_function_declaration(node)
  elseif t == "IfStatement" then
    self:print_if_statement(node)
  elseif t == "WhileStatement" then
    self:print_while_statement(node)
  elseif t == "RepeatStatement" then
    self:print_repeat_statement(node)
  elseif t == "ForNumericStatement" then
    self:print_for_numeric_statement(node)
  elseif t == "ForGenericStatement" then
    self:print_for_generic_statement(node)
  elseif t == "DoStatement" then
    self:print_do_statement(node)
  elseif t == "BreakStatement" then
    self:write("break")
  elseif t == "JSXElement" then
    self:print_jsx_element(node)
  elseif t == "JSXFragment" then
    self:print_jsx_fragment(node)
  elseif t == "Identifier" then
    self:write(node.name)
  elseif t == "StringLiteral" then
    self:write(node.raw or string.format("%q", node.value))
  elseif t == "NumberLiteral" then
    self:write(tostring(node.raw or node.value))
  elseif t == "BooleanLiteral" then
    self:write(node.value and "true" or "false")
  elseif t == "NilLiteral" then
    self:write("nil")
  elseif t == "VarargLiteral" then
    self:write("...")
  elseif t == "TableConstructor" then
    self:print_table_constructor(node)
  elseif t == "BinaryExpression" then
    self:print_node(node.left)
    self:write(" " .. node.operator .. " ")
    self:print_node(node.right)
  elseif t == "UnaryExpression" then
    self:write(node.operator)
    if node.operator == "not" then self:write(" ") end
    self:print_node(node.argument)
  elseif t == "CallExpression" then
    self:print_node(node.callee)
    self:write("(")
    for i, arg in ipairs(node.arguments) do
      if i > 1 then self:write(", ") end
      self:print_node(arg)
    end
    self:write(")")
  elseif t == "MethodCallExpression" then
    self:print_node(node.receiver)
    self:write(":" .. node.method .. "(")
    for i, arg in ipairs(node.arguments) do
      if i > 1 then self:write(", ") end
      self:print_node(arg)
    end
    self:write(")")
  elseif t == "MemberExpression" or t == "JSXMemberExpression" then
    self:print_node(node.object)
    if node.computed then
      self:write("[")
      self:print_node(node.property)
      self:write("]")
    else
      self:write("." .. node.property.name)
    end
  elseif t == "FunctionExpression" then
    self:print_function_expression(node)
  elseif t == "ParenthesizedExpression" then
    self:write("(")
    self:print_node(node.expression)
    self:write(")")
  elseif t == "Comment" then
    self:write(node.text)
  end
end

function Printer:print_program(node)
  for i, stmt in ipairs(node.body) do
    self:print_node(stmt)
    if i < #node.body then
      self:newline()
      if stmt.type == "FunctionDeclaration" or stmt.type == "LocalFunctionDeclaration" then
        self:newline()
      end
    end
  end
end

-- =========================================================================
-- JSX Printing
-- =========================================================================

function Printer:format_tag_name(name_node)
  if name_node.type == "Identifier" then
    return name_node.name
  elseif name_node.type == "JSXMemberExpression" then
    return self:format_tag_name(name_node.object) .. "." .. name_node.property.name
  end
  return "UnknownTag"
end

function Printer:print_jsx_element(node)
  local opening = node.opening_element
  local tag_name = self:format_tag_name(opening.name)

  self:write("<" .. tag_name)

  if #opening.attributes > 0 then
    for _, attr in ipairs(opening.attributes) do
      self:write(" ")
      if attr.type == "JSXSpreadAttribute" then
        self:write("{...")
        self:print_node(attr.argument)
        self:write("}")
      elseif attr.type == "JSXAttribute" then
        self:write(attr.name)
        if attr.value.type == "BooleanLiteral" and attr.value.value == true then
          -- Boolean attribute shorthand
        elseif attr.value.type == "JSXExpressionContainer" then
          self:write("={")
          self:print_node(attr.value.expression)
          self:write("}")
        else
          self:write("=" .. (attr.value.raw or string.format("%q", attr.value.value)))
        end
      end
    end
  end

  if opening.self_closing then
    self:write(" />")
    return
  end

  self:write(">")

  local meaningful_children = {}
  for _, child in ipairs(node.children or {}) do
    if child.type == "JSXText" then
      local trimmed = child.value:match("^%s*(.-)%s*$")
      if trimmed and #trimmed > 0 then
        table.insert(meaningful_children, { type = "JSXText", value = trimmed, raw = child.raw })
      end
    else
      table.insert(meaningful_children, child)
    end
  end

  if #meaningful_children == 0 then
    self:write("</" .. tag_name .. ">")
    return
  end

  -- If single child and it's text or expression, format inline
  if #meaningful_children == 1 and (meaningful_children[1].type == "JSXText" or meaningful_children[1].type == "JSXExpressionContainer") then
    local c = meaningful_children[1]
    if c.type == "JSXText" then
      self:write(c.value)
    else
      self:write("{")
      self:print_node(c.expression)
      self:write("}")
    end
    self:write("</" .. tag_name .. ">")
    return
  end

  -- Multi-line children
  self:indent()
  for _, child in ipairs(meaningful_children) do
    self:newline()
    if child.type == "JSXText" then
      self:write(child.value)
    elseif child.type == "JSXComment" then
      if child.text:sub(1, 1) == "{" and child.text:sub(-1) == "}" then
        self:write(child.text)
      else
        self:write("{--" .. child.text .. "--}")
      end
    elseif child.type == "JSXExpressionContainer" then
      self:write("{")
      self:print_node(child.expression)
      self:write("}")
    elseif child.type == "JSXElement" or child.type == "JSXFragment" then
      self:print_node(child)
    end
  end
  self:dedent()
  self:newline()
  self:write("</" .. tag_name .. ">")
end

function Printer:print_jsx_fragment(node)
  self:write("<>")

  local meaningful_children = {}
  for _, child in ipairs(node.children or {}) do
    if child.type == "JSXText" then
      local trimmed = child.value:match("^%s*(.-)%s*$")
      if trimmed and #trimmed > 0 then
        table.insert(meaningful_children, { type = "JSXText", value = trimmed, raw = child.raw })
      end
    else
      table.insert(meaningful_children, child)
    end
  end

  if #meaningful_children > 0 then
    self:indent()
    for _, child in ipairs(meaningful_children) do
      self:newline()
      if child.type == "JSXText" then
        self:write(child.value)
      elseif child.type == "JSXExpressionContainer" then
        self:write("{")
        self:print_node(child.expression)
        self:write("}")
      else
        self:print_node(child)
      end
    end
    self:dedent()
    self:newline()
  end

  self:write("</>")
end

-- =========================================================================
-- Lua Statements Printing
-- =========================================================================

function Printer:print_local_statement(node)
  self:write("local ")
  for i, name in ipairs(node.names) do
    if i > 1 then self:write(", ") end
    self:print_node(name)
  end

  if #node.values > 0 then
    self:write(" = ")
    for i, val in ipairs(node.values) do
      if i > 1 then self:write(", ") end
      self:print_node(val)
    end
  end
end

function Printer:print_assignment_statement(node)
  for i, t in ipairs(node.targets) do
    if i > 1 then self:write(", ") end
    self:print_node(t)
  end

  self:write(" = ")

  for i, v in ipairs(node.values) do
    if i > 1 then self:write(", ") end
    self:print_node(v)
  end
end

function Printer:print_return_statement(node)
  self:write("return")
  if #node.values > 0 then
    self:write(" ")
    for i, v in ipairs(node.values) do
      if i > 1 then self:write(", ") end
      self:print_node(v)
    end
  end
end

function Printer:print_function_declaration(node)
  self:write("function ")
  self:print_node(node.name)
  self:write("(")
  for i, p in ipairs(node.params) do
    if i > 1 then self:write(", ") end
    self:print_node(p)
  end
  if node.is_vararg then
    if #node.params > 0 then self:write(", ") end
    self:write("...")
  end
  self:write(")")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:print_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function Printer:print_local_function_declaration(node)
  self:write("local function ")
  self:print_node(node.name)
  self:write("(")
  for i, p in ipairs(node.params) do
    if i > 1 then self:write(", ") end
    self:print_node(p)
  end
  if node.is_vararg then
    if #node.params > 0 then self:write(", ") end
    self:write("...")
  end
  self:write(")")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:print_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function Printer:print_if_statement(node)
  for i, clause in ipairs(node.clauses) do
    if i == 1 then
      self:write("if ")
    else
      self:write("elseif ")
    end
    self:print_node(clause.condition)
    self:write(" then")
    self:indent()
    for _, stmt in ipairs(clause.body) do
      self:newline()
      self:print_node(stmt)
    end
    self:dedent()
    self:newline()
  end

  if node.else_body then
    self:write("else")
    self:indent()
    for _, stmt in ipairs(node.else_body) do
      self:newline()
      self:print_node(stmt)
    end
    self:dedent()
    self:newline()
  end

  self:write("end")
end

function Printer:print_while_statement(node)
  self:write("while ")
  self:print_node(node.condition)
  self:write(" do")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:print_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function Printer:print_repeat_statement(node)
  self:write("repeat")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:print_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("until ")
  self:print_node(node.condition)
end

function Printer:print_for_numeric_statement(node)
  self:write("for ")
  self:print_node(node.var)
  self:write(" = ")
  self:print_node(node.start)
  self:write(", ")
  self:print_node(node.stop)
  if node.step then
    self:write(", ")
    self:print_node(node.step)
  end
  self:write(" do")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:print_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function Printer:print_for_generic_statement(node)
  self:write("for ")
  for i, v in ipairs(node.vars) do
    if i > 1 then self:write(", ") end
    self:print_node(v)
  end
  self:write(" in ")
  for i, iter in ipairs(node.iterators) do
    if i > 1 then self:write(", ") end
    self:print_node(iter)
  end
  self:write(" do")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:print_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function Printer:print_do_statement(node)
  self:write("do")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:print_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function Printer:print_table_constructor(node)
  self:write("{")
  if #node.fields > 0 then
    self:write(" ")
    for i, field in ipairs(node.fields) do
      if i > 1 then self:write(", ") end
      if field.key then
        if field.key.type == "StringLiteral" and field.key.value:match("^[_%a][_%w]*$") then
          self:write(field.key.value)
        else
          self:write("[")
          self:print_node(field.key)
          self:write("]")
        end
        self:write(" = ")
      end
      self:print_node(field.value)
    end
    self:write(" ")
  end
  self:write("}")
end

function Printer:print_function_expression(node)
  self:write("function(")
  for i, p in ipairs(node.params) do
    if i > 1 then self:write(", ") end
    self:print_node(p)
  end
  if node.is_vararg then
    if #node.params > 0 then self:write(", ") end
    self:write("...")
  end
  self:write(")")
  self:indent()
  for _, stmt in ipairs(node.body) do
    self:newline()
    self:print_node(stmt)
  end
  self:dedent()
  self:newline()
  self:write("end")
end

function printer.print(ast_node, options)
  local p = Printer.new(options)
  p:print_node(ast_node)
  return p:get_result()
end

return printer
