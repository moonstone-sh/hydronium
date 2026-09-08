--[[
  Hydronium LUAX AST Node Definitions
  Supports full Lua 5.1-5.4 AST and LUAX JSX-extension nodes.
  Every node captures exact source location: line, column, and byte offset.
--]]

local ast = {}

local function create_loc(start_pos, end_pos)
  return {
    start = {
      line = start_pos and start_pos.line or 1,
      column = start_pos and start_pos.column or 1,
      offset = start_pos and start_pos.offset or 0,
    },
    ["end"] = {
      line = end_pos and end_pos.line or 1,
      column = end_pos and end_pos.column or 1,
      offset = end_pos and end_pos.offset or 0,
    },
  }
end

ast.create_loc = create_loc

function ast.Program(body, loc)
  return {
    type = "Program",
    body = body or {},
    loc = loc,
  }
end

-- =========================================================================
-- LUAX / JSX Nodes
-- =========================================================================

function ast.JSXElement(opening_element, closing_element, children, loc)
  return {
    type = "JSXElement",
    opening_element = opening_element,
    closing_element = closing_element,
    children = children or {},
    loc = loc,
  }
end

function ast.JSXOpeningElement(name, attributes, self_closing, loc)
  return {
    type = "JSXOpeningElement",
    name = name,
    attributes = attributes or {},
    self_closing = self_closing == true,
    loc = loc,
  }
end

function ast.JSXClosingElement(name, loc)
  return {
    type = "JSXClosingElement",
    name = name,
    loc = loc,
  }
end

function ast.JSXFragment(children, loc)
  return {
    type = "JSXFragment",
    children = children or {},
    loc = loc,
  }
end

function ast.JSXMemberExpression(object, property, loc)
  return {
    type = "JSXMemberExpression",
    object = object,
    property = property,
    loc = loc,
  }
end

function ast.JSXAttribute(name, value, loc)
  return {
    type = "JSXAttribute",
    name = name,
    value = value, -- StringLiteral, JSXExpressionContainer, or BooleanLiteral
    loc = loc,
  }
end

function ast.JSXSpreadAttribute(argument, loc)
  return {
    type = "JSXSpreadAttribute",
    argument = argument,
    loc = loc,
  }
end

function ast.JSXText(value, raw, loc)
  return {
    type = "JSXText",
    value = value,
    raw = raw,
    loc = loc,
  }
end

function ast.JSXExpressionContainer(expression, loc)
  return {
    type = "JSXExpressionContainer",
    expression = expression,
    loc = loc,
  }
end

function ast.JSXComment(text, loc)
  return {
    type = "JSXComment",
    text = text,
    loc = loc,
  }
end

-- =========================================================================
-- Standard Lua Expression Nodes
-- =========================================================================

function ast.Identifier(name, loc)
  return {
    type = "Identifier",
    name = name,
    loc = loc,
  }
end

function ast.StringLiteral(value, raw, loc)
  return {
    type = "StringLiteral",
    value = value,
    raw = raw or string.format("%q", value),
    loc = loc,
  }
end

function ast.NumberLiteral(value, raw, loc)
  return {
    type = "NumberLiteral",
    value = value,
    raw = raw or tostring(value),
    loc = loc,
  }
end

function ast.BooleanLiteral(value, loc)
  return {
    type = "BooleanLiteral",
    value = value == true,
    loc = loc,
  }
end

function ast.NilLiteral(loc)
  return {
    type = "NilLiteral",
    loc = loc,
  }
end

function ast.VarargLiteral(loc)
  return {
    type = "VarargLiteral",
    loc = loc,
  }
end

function ast.TableConstructor(fields, loc)
  return {
    type = "TableConstructor",
    fields = fields or {},
    loc = loc,
  }
end

function ast.TableField(key, value, loc)
  return {
    type = "TableField",
    key = key, -- nil for array element
    value = value,
    loc = loc,
  }
end

function ast.BinaryExpression(operator, left, right, loc)
  return {
    type = "BinaryExpression",
    operator = operator,
    left = left,
    right = right,
    loc = loc,
  }
end

function ast.UnaryExpression(operator, argument, loc)
  return {
    type = "UnaryExpression",
    operator = operator,
    argument = argument,
    loc = loc,
  }
end

function ast.CallExpression(callee, arguments, loc)
  return {
    type = "CallExpression",
    callee = callee,
    arguments = arguments or {},
    loc = loc,
  }
end

function ast.MethodCallExpression(receiver, method, arguments, loc)
  return {
    type = "MethodCallExpression",
    receiver = receiver,
    method = method,
    arguments = arguments or {},
    loc = loc,
  }
end

function ast.MemberExpression(object, property, computed, loc)
  return {
    type = "MemberExpression",
    object = object,
    property = property,
    computed = computed == true,
    loc = loc,
  }
end

function ast.FunctionExpression(params, is_vararg, body, loc)
  return {
    type = "FunctionExpression",
    params = params or {},
    is_vararg = is_vararg == true,
    body = body or {},
    loc = loc,
  }
end

function ast.ParenthesizedExpression(expression, loc)
  return {
    type = "ParenthesizedExpression",
    expression = expression,
    loc = loc,
  }
end

-- =========================================================================
-- Standard Lua Statement Nodes
-- =========================================================================

function ast.LocalStatement(names, values, loc)
  return {
    type = "LocalStatement",
    names = names or {},
    values = values or {},
    loc = loc,
  }
end

function ast.AssignmentStatement(targets, values, loc)
  return {
    type = "AssignmentStatement",
    targets = targets or {},
    values = values or {},
    loc = loc,
  }
end

function ast.ExpressionStatement(expression, loc)
  return {
    type = "ExpressionStatement",
    expression = expression,
    loc = loc,
  }
end

function ast.ReturnStatement(values, loc)
  return {
    type = "ReturnStatement",
    values = values or {},
    loc = loc,
  }
end

function ast.BreakStatement(loc)
  return {
    type = "BreakStatement",
    loc = loc,
  }
end

function ast.GotoStatement(label, loc)
  return {
    type = "GotoStatement",
    label = label,
    loc = loc,
  }
end

function ast.LabelStatement(name, loc)
  return {
    type = "LabelStatement",
    name = name,
    loc = loc,
  }
end

function ast.DoStatement(body, loc)
  return {
    type = "DoStatement",
    body = body or {},
    loc = loc,
  }
end

function ast.WhileStatement(condition, body, loc)
  return {
    type = "WhileStatement",
    condition = condition,
    body = body or {},
    loc = loc,
  }
end

function ast.RepeatStatement(body, condition, loc)
  return {
    type = "RepeatStatement",
    body = body or {},
    condition = condition,
    loc = loc,
  }
end

function ast.IfStatement(clauses, else_body, loc)
  return {
    type = "IfStatement",
    clauses = clauses or {},
    else_body = else_body,
    loc = loc,
  }
end

function ast.ForNumericStatement(var, start, stop, step, body, loc)
  return {
    type = "ForNumericStatement",
    var = var,
    start = start,
    stop = stop,
    step = step,
    body = body or {},
    loc = loc,
  }
end

function ast.ForGenericStatement(vars, iterators, body, loc)
  return {
    type = "ForGenericStatement",
    vars = vars or {},
    iterators = iterators or {},
    body = body or {},
    loc = loc,
  }
end

function ast.FunctionDeclaration(name, params, is_vararg, body, loc)
  return {
    type = "FunctionDeclaration",
    name = name,
    params = params or {},
    is_vararg = is_vararg == true,
    body = body or {},
    loc = loc,
  }
end

function ast.LocalFunctionDeclaration(name, params, is_vararg, body, loc)
  return {
    type = "LocalFunctionDeclaration",
    name = name,
    params = params or {},
    is_vararg = is_vararg == true,
    body = body or {},
    loc = loc,
  }
end

function ast.Comment(text, is_multiline, loc)
  return {
    type = "Comment",
    text = text,
    is_multiline = is_multiline == true,
    loc = loc,
  }
end

return ast
