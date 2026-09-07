--[[
  Hydronium LUAX Recursive Descent Parser
  Complies with:
  - Amendment 1: Context-Aware Parsing (modal lexer & clean <tag vs a < b resolution)
  - XML-strict self-closing <input /> (no hardcoded HTML void tag list)
  - Dotted components (<UI.Button />), intrinsic tags (div, button, my-widget), fragments (<>...</>)
  - Attribute syntax: foo="bar", foo={expr}, enabled (boolean), {...props}, dash-attributes (aria-*, data-*)
  - Children: text literals, entity decoding, embedded expressions {expr}, embedded comments {-- comment --}
--]]

local ast = require("hydronium.luax.ast")
local lexer_mod = require("hydronium.luax.lexer")

local parser_mod = {}

local HTML_ENTITIES = {
  ["&amp;"] = "&",
  ["&lt;"] = "<",
  ["&gt;"] = ">",
  ["&quot;"] = '"',
  ["&apos;"] = "'",
  ["&#39;"] = "'",
  ["&#34;"] = '"',
  ["&nbsp;"] = "\194\160",
}

function parser_mod.decode_entities(text)
  if not text or type(text) ~= "string" then return text end
  for ent, repl in pairs(HTML_ENTITIES) do
    text = text:gsub(ent, repl)
  end
  text = text:gsub("&#[xX](%x+);", function(hex)
    local code = tonumber(hex, 16)
    if code and code > 0 and code < 256 then return string.char(code) end
    return ""
  end)
  text = text:gsub("&#(%d+);", function(dec)
    local code = tonumber(dec, 10)
    if code and code > 0 and code < 256 then return string.char(code) end
    return ""
  end)
  return text
end

function parser_mod.fold_text(text)
  if not text or #text == 0 then return "" end
  if text:find("[\r\n]") then
    local lines = {}
    for line in text:gmatch("([^\r\n]*)[\r\n]?") do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed and #trimmed > 0 then
        table.insert(lines, trimmed)
      end
    end
    return table.concat(lines, " ")
  else
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed and #trimmed > 0 then
      return trimmed:gsub("[ \t]+", " ")
    else
      return ""
    end
  end
end

local Parser = {}
Parser.__index = Parser

function parser_mod.new(source, filename, options)
  local p = setmetatable({}, Parser)
  p.filename = filename or "<anonymous>"
  p.source = source
  p.options = options or {}
  p.diagnostics = {}
  -- Tokenize input skipping plain whitespace tokens
  p.tokens = lexer_mod.tokenize(source, filename, { include_whitespace = false })
  p.idx = 1
  p.len = #p.tokens
  return p
end

function Parser:current()
  return self.tokens[self.idx] or { type = "EOF", value = "", line = 1, col = 1, pos = 1 }
end

function Parser:peek(offset)
  offset = offset or 0
  return self.tokens[self.idx + offset] or { type = "EOF", value = "", line = 1, col = 1, pos = 1 }
end

function Parser:advance()
  local tok = self:current()
  if self.idx <= self.len then
    self.idx = self.idx + 1
  end
  return tok
end

function Parser:check(tok_type, val)
  local tok = self:current()
  if tok.type ~= tok_type then return false end
  if val ~= nil and tok.value ~= val then return false end
  return true
end

function Parser:match(tok_type, val)
  if self:check(tok_type, val) then
    return self:advance()
  end
  return nil
end

function Parser:expect(tok_type, val, msg)
  local tok = self:match(tok_type, val)
  if not tok then
    local cur = self:current()
    local expected = val and ("'" .. tostring(val) .. "'") or tostring(tok_type)
    local err_msg = msg or string.format("Expected %s, but got '%s' (%s)", expected, tostring(cur.value), tostring(cur.type))
    self:error(err_msg, cur)
  end
  return tok
end

function Parser:error(msg, tok)
  tok = tok or self:current()
  local line = tok.line or (tok.loc and tok.loc.start and tok.loc.start.line) or 1
  local col = tok.col or (tok.loc and tok.loc.start and tok.loc.start.column) or 1
  local formatted = string.format("%s:%d:%d: %s", self.filename, line, col, msg)
  table.insert(self.diagnostics, { file = self.filename, line = line, col = col, message = msg })
  if not (self.options and self.options.recover) then
    error(formatted, 2)
  end
end

-- =========================================================================
-- JSX Parsing
-- =========================================================================

--- Parses dotted or single tag name into Identifier or JSXMemberExpression
function Parser:parse_tag_name(tag_str, loc)
  if not tag_str:find("%.") then
    return ast.Identifier(tag_str, loc)
  end

  local parts = {}
  for part in tag_str:gmatch("[^%.]+") do
    table.insert(parts, part)
  end

  local node = ast.Identifier(parts[1], loc)
  for i = 2, #parts do
    local prop = ast.Identifier(parts[i], loc)
    node = ast.JSXMemberExpression(node, prop, loc)
  end
  return node
end

--- Parses attributes inside <tag ... >
function Parser:parse_jsx_attributes()
  local attributes = {}

  while true do
    local tok = self:current()
    if tok.type == "TAG_CLOSE" or tok.type == "TAG_SELF_CLOSE" or tok.type == "EOF" then
      break
    elseif tok.type == "SPREAD_OPEN" then
      -- Spread attribute: {...expr}
      local start_tok = self:advance()
      local expr = self:parse_expression()
      local end_tok = self:expect("EXPR_CLOSE", "}", "Expected '}' closing spread attribute")
      local loc = ast.create_loc(
        { line = start_tok.line, column = start_tok.col, offset = start_tok.pos },
        { line = end_tok.end_line or end_tok.line, column = end_tok.end_col or end_tok.col, offset = (end_tok.end_pos or end_tok.pos) }
      )
      table.insert(attributes, ast.JSXSpreadAttribute(expr, loc))
    elseif tok.type == "ATTR_NAME" then
      local name_tok = self:advance()
      local attr_name = name_tok.value
      local val_node
      local end_tok = name_tok

      if self:match("ATTR_EQUAL", "=") then
        local next_tok = self:current()
        if next_tok.type == "STRING" then
          local str_tok = self:advance()
          end_tok = str_tok
          -- Strip outer quotes from attribute string value
          local raw_str = str_tok.value
          local clean_val = raw_str:sub(2, -2)
          val_node = ast.StringLiteral(clean_val, raw_str, ast.create_loc(
            { line = str_tok.line, column = str_tok.col, offset = str_tok.pos },
            { line = str_tok.end_line or str_tok.line, column = str_tok.end_col or str_tok.col, offset = (str_tok.end_pos or str_tok.pos) }
          ))
        elseif next_tok.type == "EXPR_OPEN" then
          local open_tok = self:advance()
          local expr = self:parse_expression()
          local close_tok = self:expect("EXPR_CLOSE", "}", "Expected '}' closing attribute expression")
          end_tok = close_tok
          local expr_loc = ast.create_loc(
            { line = open_tok.line, column = open_tok.col, offset = open_tok.pos },
            { line = close_tok.end_line or close_tok.line, column = close_tok.end_col or close_tok.col, offset = (close_tok.end_pos or close_tok.pos) }
          )
          val_node = ast.JSXExpressionContainer(expr, expr_loc)
        else
          self:error("Expected string or embedded expression '{' after '=' in attribute", next_tok)
        end
      else
        -- Boolean attribute shorthand: e.g. <input disabled />
        val_node = ast.BooleanLiteral(true)
      end

      local loc = ast.create_loc(
        { line = name_tok.line, column = name_tok.col, offset = name_tok.pos },
        { line = end_tok.end_line or end_tok.line, column = end_tok.end_col or end_tok.col, offset = (end_tok.end_pos or end_tok.pos) }
      )
      table.insert(attributes, ast.JSXAttribute(attr_name, val_node, loc))
    elseif tok.type == "COMMENT" then
      self:advance() -- skip comment inside tag
    else
      self:error("Unexpected token in JSX tag attributes: " .. tostring(tok.value), tok)
    end
  end

  return attributes
end

--- Parses JSX element or fragment
function Parser:parse_jsx_element()
  local start_tok = self:current()

  -- Check for Fragment opening <>
  if start_tok.type == "FRAGMENT_OPEN" then
    self:advance()
    local children = self:parse_jsx_children("<>")
    local close_tok = self:expect("FRAGMENT_CLOSE", "</>", "Expected closing fragment '</>'")
    local loc = ast.create_loc(
      { line = start_tok.line, column = start_tok.col, offset = start_tok.pos },
      { line = close_tok.end_line or close_tok.line, column = close_tok.end_col or close_tok.col, offset = (close_tok.end_pos or close_tok.pos) }
    )
    return ast.JSXFragment(children, loc)
  end

  -- Regular element <tag ...>
  local open_tok = self:expect("TAG_OPEN", nil, "Expected JSX opening tag")
  local tag_str = open_tok.tag
  local tag_name_node = self:parse_tag_name(tag_str, ast.create_loc(
    { line = open_tok.line, column = open_tok.col, offset = open_tok.pos },
    { line = open_tok.end_line or open_tok.line, column = open_tok.end_col or open_tok.col, offset = (open_tok.end_pos or open_tok.pos) }
  ))

  local attributes = self:parse_jsx_attributes()

  local self_close_tok = self:match("TAG_SELF_CLOSE", "/>")
  if self_close_tok then
    -- XML-strict self-closing <tag ... />
    local open_loc = ast.create_loc(
      { line = open_tok.line, column = open_tok.col, offset = open_tok.pos },
      { line = self_close_tok.end_line or self_close_tok.line, column = self_close_tok.end_col or self_close_tok.col, offset = (self_close_tok.pos + 1) }
    )
    local opening_el = ast.JSXOpeningElement(tag_name_node, attributes, true, open_loc)
    return ast.JSXElement(opening_el, nil, {}, open_loc)
  end

  -- Paired tag <tag> ... </tag>
  local tag_close_tok = self:expect("TAG_CLOSE", ">", "Expected '>' or '/>' to close opening tag")
  local open_loc = ast.create_loc(
    { line = open_tok.line, column = open_tok.col, offset = open_tok.pos },
    { line = tag_close_tok.end_line or tag_close_tok.line, column = tag_close_tok.end_col or tag_close_tok.col, offset = (tag_close_tok.end_pos or tag_close_tok.pos) }
  )
  local opening_el = ast.JSXOpeningElement(tag_name_node, attributes, false, open_loc)

  local children = self:parse_jsx_children(tag_str)

  local close_tok = self:expect("TAG_END", nil, string.format("Expected closing tag '</%s>'", tag_str))
  if close_tok and close_tok.tag ~= tag_str then
    self:error(string.format("Closing tag '</%s>' does not match opening tag '<%s>'", tostring(close_tok.tag), tag_str), close_tok)
  end

  local close_loc = close_tok and ast.create_loc(
    { line = close_tok.line, column = close_tok.col, offset = close_tok.pos },
    { line = close_tok.end_line or close_tok.line, column = close_tok.end_col or close_tok.col, offset = close_tok.pos + #close_tok.value - 1 }
  ) or open_loc
  local closing_el = ast.JSXClosingElement(tag_name_node, close_loc)
  local loc = ast.create_loc(
    { line = open_tok.line, column = open_tok.col, offset = open_tok.pos },
    {
      line = close_tok and (close_tok.end_line or close_tok.line) or open_tok.line,
      column = close_tok and (close_tok.end_col or close_tok.col) or open_tok.col,
      offset = close_tok and close_tok.pos or open_tok.pos,
    }
  )

  return ast.JSXElement(opening_el, closing_el, children, loc)
end

--- Parses children inside <tag> ... </tag> or <> ... </>
function Parser:parse_jsx_children(expected_parent_tag)
  local children = {}

  while true do
    local tok = self:current()
    if tok.type == "TAG_END" or tok.type == "FRAGMENT_CLOSE" or tok.type == "EOF" then
      break
    elseif tok.type == "JSX_TEXT" then
      local text_tok = self:advance()
      local raw = text_tok.raw or text_tok.value
      local decoded = parser_mod.decode_entities(text_tok.value)
      local val = parser_mod.fold_text(decoded)
      local loc = ast.create_loc(
        { line = text_tok.line, column = text_tok.col, offset = text_tok.pos },
        { line = text_tok.end_line or text_tok.line, column = text_tok.end_col or text_tok.col, offset = text_tok.pos + #raw - 1 }
      )
      if #val > 0 then
        table.insert(children, ast.JSXText(val, raw, loc))
      end
    elseif tok.type == "COMMENT" then
      -- Embedded comment {-- ... --}
      local c_tok = self:advance()
      local c_raw = c_tok.raw or c_tok.value or ""
      local loc = ast.create_loc(
        { line = c_tok.line, column = c_tok.col, offset = c_tok.pos },
        { line = c_tok.end_line or c_tok.line, column = c_tok.end_col or c_tok.col, offset = c_tok.pos + #c_raw - 1 }
      )
      table.insert(children, ast.JSXComment(c_tok.value, loc))
    elseif tok.type == "EXPR_OPEN" then
      -- Embedded expression {expr}
      local open_tok = self:advance()
      local expr = self:parse_expression()
      local close_tok = self:expect("EXPR_CLOSE", "}", "Expected '}' closing embedded JSX expression")
      local loc = ast.create_loc(
        { line = open_tok.line, column = open_tok.col, offset = open_tok.pos },
        { line = close_tok.end_line or close_tok.line, column = close_tok.end_col or close_tok.col, offset = (close_tok.end_pos or close_tok.pos) }
      )
      table.insert(children, ast.JSXExpressionContainer(expr, loc))
    elseif tok.type == "TAG_OPEN" or tok.type == "FRAGMENT_OPEN" then
      -- Nested child JSX element
      local child_el = self:parse_jsx_element()
      table.insert(children, child_el)
    else
      self:error("Unexpected token inside JSX children: " .. tostring(tok.value), tok)
    end
  end

  return children
end

-- =========================================================================
-- Standard Lua Expression Parsing (Operator Precedence Climbing)
-- =========================================================================

local BINOP_PRECEDENCE = {
  ["or"] = { 1, 1 },
  ["and"] = { 2, 2 },
  ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 },
  ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
  ["|"] = { 4, 4 },
  ["~"] = { 5, 5 },
  ["&"] = { 6, 6 },
  ["<<"] = { 7, 7 }, [">>"] = { 7, 7 },
  [".."] = { 9, 8 }, -- right associative
  ["+"] = { 10, 10 }, ["-"] = { 10, 10 },
  ["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
  ["^"] = { 14, 13 }, -- right associative
}

local UNARY_OPS = {
  ["not"] = true, ["#"] = true, ["-"] = true, ["~"] = true,
}

function Parser:parse_expression(min_prec)
  min_prec = min_prec or 0
  local left = self:parse_unary_or_primary()

  while true do
    local tok = self:current()
    local op = tok.value
    local prec_info = (tok.type == "PUNCT" or tok.type == "KEYWORD") and BINOP_PRECEDENCE[op]

    if not prec_info or prec_info[1] < min_prec then
      break
    end

    self:advance() -- consume binary operator
    local right = self:parse_expression(prec_info[2] + 1)
    local loc = ast.create_loc(left.loc and left.loc.start, right.loc and right.loc["end"])
    left = ast.BinaryExpression(op, left, right, loc)
  end

  return left
end

function Parser:parse_unary_or_primary()
  local tok = self:current()

  if (tok.type == "KEYWORD" or tok.type == "PUNCT") and UNARY_OPS[tok.value] then
    local op_tok = self:advance()
    local arg = self:parse_expression(12) -- unary precedence higher than binary *
    local loc = ast.create_loc(
      { line = op_tok.line, column = op_tok.col, offset = op_tok.pos },
      arg.loc and arg.loc["end"]
    )
    return ast.UnaryExpression(op_tok.value, arg, loc)
  end

  return self:parse_primary_expression()
end

function Parser:parse_primary_expression()
  while self:current().type == "COMMENT" do
    self:advance()
  end
  local tok = self:current()

  -- Check for JSX element or fragment in expression start position
  if tok.type == "TAG_OPEN" or tok.type == "FRAGMENT_OPEN" then
    return self:parse_jsx_element()
  end

  -- Nil literal
  if tok.type == "KEYWORD" and tok.value == "nil" then
    self:advance()
    return ast.NilLiteral(self:make_node_loc(tok))
  end

  -- Boolean literals
  if tok.type == "KEYWORD" and (tok.value == "true" or tok.value == "false") then
    self:advance()
    return ast.BooleanLiteral(tok.value == "true", self:make_node_loc(tok))
  end

  -- Number literal
  if tok.type == "NUMBER" then
    self:advance()
    local num_val = tonumber(tok.value) or tok.value
    return ast.NumberLiteral(num_val, tok.value, self:make_node_loc(tok))
  end

  -- String literal
  if tok.type == "STRING" then
    self:advance()
    local raw = tok.value
    local val = raw:sub(2, -2) -- basic unquote
    return ast.StringLiteral(val, raw, self:make_node_loc(tok))
  end

  -- Vararg '...'
  if tok.type == "PUNCT" and tok.value == "..." then
    self:advance()
    return ast.VarargLiteral(self:make_node_loc(tok))
  end

  -- Table constructor '{ ... }'
  if tok.type == "PUNCT" and tok.value == "{" then
    return self:parse_table_constructor()
  end

  -- Function expression 'function(...) ... end'
  if tok.type == "KEYWORD" and tok.value == "function" then
    return self:parse_function_expression()
  end

  -- Parenthesized expression '(expr)'
  if tok.type == "PUNCT" and tok.value == "(" then
    local open_tok = self:advance()
    local expr = self:parse_expression()
    local close_tok = self:expect("PUNCT", ")", "Expected ')'")
    local loc = ast.create_loc(
      { line = open_tok.line, column = open_tok.col, offset = open_tok.pos },
      { line = close_tok.end_line or close_tok.line, column = close_tok.end_col or close_tok.col, offset = (close_tok.end_pos or close_tok.pos) }
    )
    local inner = ast.ParenthesizedExpression(expr, loc)
    return self:parse_postfix_expressions(inner)
  end

  -- Identifier
  if tok.type == "IDENT" then
    local id_tok = self:advance()
    local base = ast.Identifier(id_tok.value, self:make_node_loc(id_tok))
    return self:parse_postfix_expressions(base)
  end

  self:error("Unexpected token in expression: '" .. tostring(tok.value) .. "' (" .. tostring(tok.type) .. ")", tok)
end

function Parser:parse_postfix_expressions(base)
  while true do
    local tok = self:current()

    if tok.type == "PUNCT" and tok.value == "." then
      -- Member access: base.field
      self:advance()
      local id_tok = self:expect("IDENT", nil, "Expected identifier after '.'")
      local prop = ast.Identifier(id_tok.value, self:make_node_loc(id_tok))
      local loc = ast.create_loc(base.loc and base.loc.start, prop.loc and prop.loc["end"])
      base = ast.MemberExpression(base, prop, false, loc)
    elseif tok.type == "PUNCT" and tok.value == "[" then
      -- Computed index access: base[expr]
      self:advance()
      local idx_expr = self:parse_expression()
      local close_tok = self:expect("PUNCT", "]", "Expected ']' after computed index")
      local loc = ast.create_loc(base.loc and base.loc.start, self:make_node_loc(close_tok)["end"])
      base = ast.MemberExpression(base, idx_expr, true, loc)
    elseif tok.type == "PUNCT" and tok.value == ":" then
      -- Method call: base:method(args)
      self:advance()
      local method_tok = self:expect("IDENT", nil, "Expected method name after ':'")
      local method_name = method_tok.value
      local args = self:parse_function_call_args()
      local loc = ast.create_loc(base.loc and base.loc.start, self:current_pos())
      base = ast.MethodCallExpression(base, method_name, args, loc)
    elseif tok.type == "PUNCT" and tok.value == "(" then
      -- Function call: base(args)
      local args = self:parse_function_call_args()
      local loc = ast.create_loc(base.loc and base.loc.start, self:current_pos())
      base = ast.CallExpression(base, args, loc)
    elseif tok.type == "STRING" then
      -- Syntactic sugar: base "string"
      local str_expr = self:parse_primary_expression()
      local loc = ast.create_loc(base.loc and base.loc.start, str_expr.loc and str_expr.loc["end"])
      base = ast.CallExpression(base, { str_expr }, loc)
    elseif tok.type == "PUNCT" and tok.value == "{" then
      -- Syntactic sugar: base { ... }
      local tbl_expr = self:parse_table_constructor()
      local loc = ast.create_loc(base.loc and base.loc.start, tbl_expr.loc and tbl_expr.loc["end"])
      base = ast.CallExpression(base, { tbl_expr }, loc)
    else
      break
    end
  end

  return base
end

function Parser:parse_function_call_args()
  self:expect("PUNCT", "(", "Expected '(' at call arguments")
  local args = {}

  if not self:check("PUNCT", ")") then
    while true do
      table.insert(args, self:parse_expression())
      if self:match("PUNCT", ",") then
        -- Continue next argument
      else
        break
      end
    end
  end

  self:expect("PUNCT", ")", "Expected ')' closing call arguments")
  return args
end

function Parser:parse_table_constructor()
  local open_tok = self:expect("PUNCT", "{", "Expected '{'")
  local fields = {}

  while not self:check("PUNCT", "}") and not self:check("EOF") do
    if self:check("PUNCT", "[") then
      -- [key_expr] = val_expr
      self:advance()
      local key_expr = self:parse_expression()
      self:expect("PUNCT", "]", "Expected ']' after table key")
      self:expect("PUNCT", "=", "Expected '=' after table key")
      local val_expr = self:parse_expression()
      table.insert(fields, ast.TableField(key_expr, val_expr))
    elseif self:check("IDENT") and self:peek(1).type == "PUNCT" and self:peek(1).value == "=" then
      -- ident = val_expr
      local id_tok = self:advance()
      self:advance() -- consume '='
      local key_node = ast.StringLiteral(id_tok.value)
      local val_expr = self:parse_expression()
      table.insert(fields, ast.TableField(key_node, val_expr))
    else
      -- Array field: val_expr
      local val_expr = self:parse_expression()
      table.insert(fields, ast.TableField(nil, val_expr))
    end

    if self:match("PUNCT", ",") or self:match("PUNCT", ";") then
      -- optional delimiter
    else
      break
    end
  end

  local close_tok = self:expect("PUNCT", "}", "Expected '}' closing table")
  local loc = ast.create_loc(
    { line = open_tok.line, column = open_tok.col, offset = open_tok.pos },
    { line = close_tok.end_line or close_tok.line, column = close_tok.end_col or close_tok.col, offset = (close_tok.end_pos or close_tok.pos) }
  )

  return ast.TableConstructor(fields, loc)
end

function Parser:parse_function_expression()
  local fn_tok = self:expect("KEYWORD", "function")
  self:expect("PUNCT", "(")
  local params, is_vararg = self:parse_param_list()
  self:expect("PUNCT", ")")

  local body = self:parse_block()
  local end_tok = self:expect("KEYWORD", "end", "Expected 'end' closing function expression")

  local loc = ast.create_loc(
    { line = fn_tok.line, column = fn_tok.col, offset = fn_tok.pos },
    { line = end_tok.end_line or end_tok.line, column = end_tok.end_col or end_tok.col, offset = (end_tok.end_pos or end_tok.pos) }
  )

  return ast.FunctionExpression(params, is_vararg, body, loc)
end

function Parser:parse_param_list()
  local params = {}
  local is_vararg = false

  while not self:check("PUNCT", ")") and not self:check("EOF") do
    if self:match("PUNCT", "...") then
      is_vararg = true
      break
    elseif self:check("IDENT") then
      local id_tok = self:advance()
      table.insert(params, ast.Identifier(id_tok.value, self:make_node_loc(id_tok)))
      if not self:match("PUNCT", ",") then
        break
      end
    else
      self:error("Expected parameter name or '...'", self:current())
    end
  end

  return params, is_vararg
end

-- =========================================================================
-- Lua Statements & Blocks
-- =========================================================================

function Parser:parse_block()
  local statements = {}

  while not self:check("EOF") do
    local tok = self:current()
    if tok.type == "KEYWORD" and (tok.value == "end" or tok.value == "else" or tok.value == "elseif" or tok.value == "until") then
      break
    end
    local stmt = self:parse_statement()
    if stmt then
      table.insert(statements, stmt)
    end
  end

  return statements
end

function Parser:parse_statement()
  -- Optional semicolons
  while self:match("PUNCT", ";") do end

  local tok = self:current()
  if tok.type == "EOF" then return nil end

  -- Comments in statements
  if tok.type == "COMMENT" then
    self:advance()
    local is_multi = tok.value:sub(1, 4) == "--[[" or tok.value:sub(1, 4) == "--[="
    return ast.Comment(tok.value, is_multi, self:make_node_loc(tok))
  end

  -- Return statement
  if tok.type == "KEYWORD" and tok.value == "return" then
    return self:parse_return_statement()
  end

  -- Local statement: local x, y = ... or local function name()
  if tok.type == "KEYWORD" and tok.value == "local" then
    return self:parse_local_statement()
  end

  -- Function statement: function name() ... end
  if tok.type == "KEYWORD" and tok.value == "function" then
    return self:parse_function_declaration()
  end

  -- If statement
  if tok.type == "KEYWORD" and tok.value == "if" then
    return self:parse_if_statement()
  end

  -- While statement
  if tok.type == "KEYWORD" and tok.value == "while" then
    return self:parse_while_statement()
  end

  -- Repeat statement
  if tok.type == "KEYWORD" and tok.value == "repeat" then
    return self:parse_repeat_statement()
  end

  -- For statement (numeric or generic)
  if tok.type == "KEYWORD" and tok.value == "for" then
    return self:parse_for_statement()
  end

  -- Do statement
  if tok.type == "KEYWORD" and tok.value == "do" then
    local do_tok = self:advance()
    local body = self:parse_block()
    local end_tok = self:expect("KEYWORD", "end", "Expected 'end' closing do block")
    return ast.DoStatement(body, ast.create_loc(self:make_node_loc(do_tok).start, self:make_node_loc(end_tok)["end"]))
  end

  -- Break statement
  if tok.type == "KEYWORD" and tok.value == "break" then
    self:advance()
    return ast.BreakStatement(self:make_node_loc(tok))
  end

  -- Expression or Assignment statement
  local expr = self:parse_expression()

  if self:check("PUNCT", "=") or self:check("PUNCT", ",") then
    -- Assignment: expr, expr2 = val1, val2
    local targets = { expr }
    while self:match("PUNCT", ",") do
      table.insert(targets, self:parse_expression())
    end
    self:expect("PUNCT", "=", "Expected '=' in assignment statement")
    local values = { self:parse_expression() }
    while self:match("PUNCT", ",") do
      table.insert(values, self:parse_expression())
    end
    return ast.AssignmentStatement(targets, values)
  end

  return ast.ExpressionStatement(expr)
end

function Parser:parse_return_statement()
  local ret_tok = self:expect("KEYWORD", "return")
  local values = {}

  local tok = self:current()
  local is_block_end = tok.type == "EOF" or (tok.type == "KEYWORD" and (tok.value == "end" or tok.value == "else" or tok.value == "elseif" or tok.value == "until")) or (tok.type == "PUNCT" and tok.value == ";")

  if not is_block_end then
    table.insert(values, self:parse_expression())
    while self:match("PUNCT", ",") do
      table.insert(values, self:parse_expression())
    end
  end

  self:match("PUNCT", ";")
  return ast.ReturnStatement(values, self:make_node_loc(ret_tok))
end

function Parser:parse_local_statement()
  local loc_tok = self:expect("KEYWORD", "local")

  if self:match("KEYWORD", "function") then
    local name_tok = self:expect("IDENT", nil, "Expected function name")
    self:expect("PUNCT", "(")
    local params, is_vararg = self:parse_param_list()
    self:expect("PUNCT", ")")
    local body = self:parse_block()
    local end_tok = self:expect("KEYWORD", "end", "Expected 'end' closing local function")
    return ast.LocalFunctionDeclaration(ast.Identifier(name_tok.value), params, is_vararg, body)
  end

  local names = {}
  while true do
    local id_tok = self:expect("IDENT", nil, "Expected variable name")
    table.insert(names, ast.Identifier(id_tok.value, self:make_node_loc(id_tok)))
    if not self:match("PUNCT", ",") then
      break
    end
  end

  local values = {}
  if self:match("PUNCT", "=") then
    while true do
      table.insert(values, self:parse_expression())
      if not self:match("PUNCT", ",") then
        break
      end
    end
  end

  return ast.LocalStatement(names, values)
end

function Parser:parse_function_declaration()
  self:expect("KEYWORD", "function")
  local name_parts = { self:expect("IDENT", nil, "Expected function name").value }

  while self:match("PUNCT", ".") do
    table.insert(name_parts, self:expect("IDENT", nil, "Expected method/field name").value)
  end

  local method_name = nil
  if self:match("PUNCT", ":") then
    method_name = self:expect("IDENT", nil, "Expected method name").value
  end

  self:expect("PUNCT", "(")
  local params, is_vararg = self:parse_param_list()
  self:expect("PUNCT", ")")

  if method_name then
    table.insert(params, 1, ast.Identifier("self"))
  end

  local body = self:parse_block()
  self:expect("KEYWORD", "end", "Expected 'end' closing function")

  local full_name = table.concat(name_parts, ".")
  if method_name then
    full_name = full_name .. ":" .. method_name
  end

  return ast.FunctionDeclaration(ast.Identifier(full_name), params, is_vararg, body)
end

function Parser:parse_if_statement()
  self:expect("KEYWORD", "if")
  local clauses = {}

  local cond = self:parse_expression()
  self:expect("KEYWORD", "then")
  local body = self:parse_block()
  table.insert(clauses, { condition = cond, body = body })

  while self:match("KEYWORD", "elseif") do
    local elif_cond = self:parse_expression()
    self:expect("KEYWORD", "then")
    local elif_body = self:parse_block()
    table.insert(clauses, { condition = elif_cond, body = elif_body })
  end

  local else_body = nil
  if self:match("KEYWORD", "else") then
    else_body = self:parse_block()
  end

  self:expect("KEYWORD", "end", "Expected 'end' closing if statement")
  return ast.IfStatement(clauses, else_body)
end

function Parser:parse_while_statement()
  self:expect("KEYWORD", "while")
  local cond = self:parse_expression()
  self:expect("KEYWORD", "do")
  local body = self:parse_block()
  self:expect("KEYWORD", "end", "Expected 'end' closing while statement")
  return ast.WhileStatement(cond, body)
end

function Parser:parse_repeat_statement()
  self:expect("KEYWORD", "repeat")
  local body = self:parse_block()
  self:expect("KEYWORD", "until")
  local cond = self:parse_expression()
  return ast.RepeatStatement(body, cond)
end

function Parser:parse_for_statement()
  self:expect("KEYWORD", "for")
  local first_var = self:expect("IDENT", nil, "Expected variable name in for loop")

  if self:match("PUNCT", "=") then
    -- Numeric for: for i = start, stop [, step] do
    local start_expr = self:parse_expression()
    self:expect("PUNCT", ",", "Expected ',' in numeric for loop")
    local stop_expr = self:parse_expression()
    local step_expr = nil
    if self:match("PUNCT", ",") then
      step_expr = self:parse_expression()
    end
    self:expect("KEYWORD", "do", "Expected 'do' in for loop")
    local body = self:parse_block()
    self:expect("KEYWORD", "end", "Expected 'end' closing for loop")
    return ast.ForNumericStatement(ast.Identifier(first_var.value), start_expr, stop_expr, step_expr, body)
  else
    -- Generic for: for k, v in ipairs(...) do
    local vars = { ast.Identifier(first_var.value) }
    while self:match("PUNCT", ",") do
      local next_var = self:expect("IDENT", nil, "Expected variable name in generic for")
      table.insert(vars, ast.Identifier(next_var.value))
    end
    self:expect("KEYWORD", "in", "Expected 'in' in generic for loop")
    local iterators = { self:parse_expression() }
    while self:match("PUNCT", ",") do
      table.insert(iterators, self:parse_expression())
    end
    self:expect("KEYWORD", "do", "Expected 'do' in generic for loop")
    local body = self:parse_block()
    self:expect("KEYWORD", "end", "Expected 'end' closing generic for loop")
    return ast.ForGenericStatement(vars, iterators, body)
  end
end

function Parser:make_node_loc(tok)
  return ast.create_loc(
    { line = tok.line, column = tok.col, offset = tok.pos },
    { line = tok.end_line or tok.line, column = tok.end_col or tok.col, offset = (tok.end_pos or tok.pos) }
  )
end

function Parser:current_pos()
  local tok = self:current()
  return { line = tok.line, column = tok.col, offset = tok.pos }
end

--- Main parse entry point: parses full file into Program AST
function parser_mod.parse(source, filename, options)
  local parser = parser_mod.new(source, filename, options)
  local body = parser:parse_block()
  if not (options and options.recover) then
    parser:expect("EOF", nil, "Expected end of file")
  end
  local prog = ast.Program(body)
  prog.diagnostics = parser.diagnostics
  return prog
end

return parser_mod
