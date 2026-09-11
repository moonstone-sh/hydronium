-- Lexer for Hydronium LUAX (Lua + JSX/LuaX syntax)
local M = {}

-- Token types
M.TOKEN = {
  EOF = "EOF",
  WHITESPACE = "WHITESPACE",
  COMMENT = "COMMENT",
  KEYWORD = "KEYWORD",
  IDENT = "IDENT",
  NUMBER = "NUMBER",
  STRING = "STRING",
  PUNCT = "PUNCT",
  
  -- JSX specific tokens
  TAG_OPEN = "TAG_OPEN",             -- <tag
  TAG_CLOSE = "TAG_CLOSE",           -- >
  TAG_SELF_CLOSE = "TAG_SELF_CLOSE", -- />
  TAG_END = "TAG_END",               -- </tag>
  FRAGMENT_OPEN = "FRAGMENT_OPEN",   -- <>
  FRAGMENT_CLOSE = "FRAGMENT_CLOSE", -- </>
  ATTR_NAME = "ATTR_NAME",           -- class, onClick, data-id
  ATTR_EQUAL = "ATTR_EQUAL",         -- =
  SPREAD_OPEN = "SPREAD_OPEN",       -- {...
  EXPR_OPEN = "EXPR_OPEN",           -- {
  EXPR_CLOSE = "EXPR_CLOSE",         -- }
  JSX_TEXT = "JSX_TEXT",             -- text between tags
}

local KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

-- Tokens that indicate the following '<' can be a JSX tag opening
local EXPR_PRECEDING_KEYWORDS = {
  ["return"] = true, ["then"] = true, ["else"] = true, ["do"] = true,
  ["in"] = true, ["and"] = true, ["or"] = true, ["not"] = true,
  ["repeat"] = true,
}

local EXPR_PRECEDING_PUNCTS = {
  ["="] = true, ["("] = true, ["["] = true, ["{"] = true,
  [","] = true, [":"] = true, [";"] = true, ["+"] = true,
  ["-"] = true, ["*"] = true, ["/"] = true, [".."] = true,
  ["=="] = true, ["~="] = true,
}

-- UTF-8 character encoder compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT
local function utf8_char(code)
  if utf8 and utf8.char then
    local ok, res = pcall(utf8.char, code)
    if ok then return res end
  end
  if code < 0 or code > 0x10FFFF then
    return "\239\191\189" -- Unicode replacement character U+FFFD
  elseif code <= 0x7F then
    return string.char(code)
  elseif code <= 0x7FF then
    local b1 = 0xC0 + math.floor(code / 0x40)
    local b2 = 0x80 + (code % 0x40)
    return string.char(b1, b2)
  elseif code <= 0xFFFF then
    local b1 = 0xE0 + math.floor(code / 0x1000)
    local b2 = 0x80 + (math.floor(code / 0x40) % 0x40)
    local b3 = 0x80 + (code % 0x40)
    return string.char(b1, b2, b3)
  else
    local b1 = 0xF0 + math.floor(code / 0x40000)
    local b2 = 0x80 + (math.floor(code / 0x1000) % 0x40)
    local b3 = 0x80 + (math.floor(code / 0x40) % 0x40)
    local b4 = 0x80 + (code % 0x40)
    return string.char(b1, b2, b3, b4)
  end
end

local ENTITIES = {
  ["lt"] = "<",
  ["gt"] = ">",
  ["amp"] = "&",
  ["quot"] = '"',
  ["apos"] = "'",
  ["nbsp"] = "\194\160",
  ["copy"] = "\194\169",
  ["reg"] = "\194\174",
  ["euro"] = "\226\130\172",
  ["pound"] = "\194\163",
  ["yen"] = "\194\165",
  ["cent"] = "\194\162",
  ["times"] = "\195\151",
  ["divide"] = "\195\183",
}

local function decode_entities(text)
  return text:gsub("&#([xX]?)([0-9a-fA-F]+);", function(hex, val)
    local code
    if hex == "x" or hex == "X" then
      code = tonumber(val, 16)
    else
      code = tonumber(val, 10)
    end
    if code then
      return utf8_char(code)
    end
    return "&#" .. hex .. val .. ";"
  end):gsub("&([a-zA-Z]+);", function(name)
    return ENTITIES[name] or ("&" .. name .. ";")
  end)
end

M.decode_entities = decode_entities

local Lexer = {}
Lexer.__index = Lexer

function M.create(src, filename)
  local l = {
    src = src,
    filename = filename or "<anonymous>",
    len = #src,
    pos = 1,
    line = 1,
    col = 1,
    mode = "LUA", -- "LUA", "JSX_TAG", "JSX_CHILDREN"
    mode_stack = {},
    tag_stack = {},
    brace_depth = 0,
    prev_token = nil,
  }
  return setmetatable(l, Lexer)
end

function Lexer:peek(offset)
  offset = offset or 0
  local idx = self.pos + offset
  if idx > self.len then return nil end
  return self.src:sub(idx, idx)
end

function Lexer:advance(n)
  n = n or 1
  for _ = 1, n do
    if self.pos <= self.len then
      local ch = self.src:sub(self.pos, self.pos)
      if ch == "\n" then
        self.line = self.line + 1
        self.col = 1
      else
        self.col = self.col + 1
      end
      self.pos = self.pos + 1
    end
  end
end

function Lexer:match(pattern)
  local s, e = self.src:find("^" .. pattern, self.pos)
  if s then
    local matched = self.src:sub(s, e)
    self:advance(e - s + 1)
    return matched
  end
  return nil
end

-- Check if '<' at current position is a JSX tag opening
function Lexer:can_start_jsx()
  local prev = self.prev_token
  if not prev then
    return true
  end
  if prev.type == M.TOKEN.KEYWORD and EXPR_PRECEDING_KEYWORDS[prev.value] then
    return true
  end
  if prev.type == M.TOKEN.PUNCT and EXPR_PRECEDING_PUNCTS[prev.value] then
    return true
  end
  if prev.type == M.TOKEN.EXPR_OPEN or prev.type == M.TOKEN.SPREAD_OPEN then
    return true
  end
  return false
end

function Lexer:read_whitespace()
  local start_line = self.line
  local start_col = self.col
  local start_pos = self.pos
  local val = self:match("[ \t\r\n]+")
  if val then
    return {
      type = M.TOKEN.WHITESPACE,
      value = val,
      line = start_line,
      col = start_col,
      pos = start_pos,
      end_line = self.line,
      end_col = self.col,
    }
  end
  return nil
end

function Lexer:read_comment()
  if self.src:sub(self.pos, self.pos + 1) == "--" then
    local start_line = self.line
    local start_col = self.col
    local start_pos = self.pos
    self:advance(2)

    -- Check for long bracket comment --[=[ ... ]=]
    -- NOTE: no leading "^" here -- Lexer:match() (above) already
    -- anchors its pattern to self.pos internally (`"^" .. pattern`).
    -- Passing a second leading "^" produced the literal two-character
    -- pattern "^^%[..." (a lone "^" not in anchor position is not
    -- magic in Lua patterns, but doubling it here made the whole
    -- pattern never match beginning-of-subject text), which silently
    -- made this branch dead: every --[[ ... ]] comment was
    -- misdetected as a single-line comment, consuming only its
    -- opening line before the lexer started tokenizing the comment's
    -- own remaining lines as real code. Confirmed via a minimal
    -- repro before this fix: `("[["):find("^^%[(=*)%[")` -> nil,
    -- `("[["):find("%[(=*)%[")` -> a real match.
    local eq = self:match("%[(=*)%[")
    if eq then
      local num_eq = #eq:match("^%[(=*)%[")
      local close_pat = "%]" .. string.rep("=", num_eq) .. "%]"
      local s, e = self.src:find(close_pat, self.pos)
      if s then
        self:advance(e - self.pos + 1)
      else
        self:advance(self.len - self.pos + 1)
      end
    else
      -- Single line comment
      while self.pos <= self.len and self:peek() ~= "\n" do
        self:advance(1)
      end
    end

    local val = self.src:sub(start_pos, self.pos - 1)
    return {
      type = M.TOKEN.COMMENT,
      value = val,
      line = start_line,
      col = start_col,
      pos = start_pos,
      end_line = self.line,
      end_col = self.col,
    }
  end
  return nil
end

function Lexer:read_string()
  local start_ch = self:peek()
  if start_ch == '"' or start_ch == "'" then
    local start_line = self.line
    local start_col = self.col
    local start_pos = self.pos
    self:advance(1)

    while self.pos <= self.len do
      local ch = self:peek()
      if ch == "\\" then
        self:advance(2)
      elseif ch == start_ch then
        self:advance(1)
        break
      elseif ch == "\n" then
        error(string.format("%s:%d:%d: Unterminated string literal", self.filename, start_line, start_col))
      else
        self:advance(1)
      end
    end

    return {
      type = M.TOKEN.STRING,
      value = self.src:sub(start_pos, self.pos - 1),
      line = start_line,
      col = start_col,
      pos = start_pos,
      end_line = self.line,
      end_col = self.col,
    }
  elseif self:peek() == "[" then
    local eq = self.src:match("^%[(=*)%[", self.pos)
    if eq then
      local start_line = self.line
      local start_col = self.col
      local start_pos = self.pos
      local num_eq = #eq
      self:advance(2 + num_eq)
      local close_pat = "%]" .. string.rep("=", num_eq) .. "%]"
      local s, e = self.src:find(close_pat, self.pos)
      if s then
        self:advance(e - self.pos + 1)
      else
        error(string.format("%s:%d:%d: Unterminated long string literal", self.filename, start_line, start_col))
      end
      return {
        type = M.TOKEN.STRING,
        value = self.src:sub(start_pos, self.pos - 1),
        line = start_line,
        col = start_col,
        pos = start_pos,
        end_line = self.line,
        end_col = self.col,
      }
    end
  end
  return nil
end

function Lexer:read_number()
  local start_line = self.line
  local start_col = self.col
  local start_pos = self.pos

  -- Hex
  local hex = self:match("0[xX][0-9a-fA-F]+")
  if hex then
    return {
      type = M.TOKEN.NUMBER,
      value = hex,
      line = start_line,
      col = start_col,
      pos = start_pos,
      end_line = self.line,
      end_col = self.col,
    }
  end

  -- Decimal
  local num = self:match("%d+%.?%d*[eE][+-]?%d+") or self:match("%d+%.?%d*") or self:match("%.%d+[eE][+-]?%d+") or self:match("%.%d+")
  if num then
    return {
      type = M.TOKEN.NUMBER,
      value = num,
      line = start_line,
      col = start_col,
      pos = start_pos,
      end_line = self.line,
      end_col = self.col,
    }
  end
  return nil
end

function Lexer:read_ident_or_keyword()
  local start_line = self.line
  local start_col = self.col
  local start_pos = self.pos

  local ident = self:match("[a-zA-Z_][a-zA-Z0-9_]*")
  if ident then
    local t_type = KEYWORDS[ident] and M.TOKEN.KEYWORD or M.TOKEN.IDENT
    return {
      type = t_type,
      value = ident,
      line = start_line,
      col = start_col,
      pos = start_pos,
      end_line = self.line,
      end_col = self.col,
    }
  end
  return nil
end

-- Read JSX Tag name: can be 'div', 'MyComp', 'UI.Button', 'Layout.Grid.Item'
function Lexer:read_jsx_tag_name()
  local start_line = self.line
  local start_col = self.col
  local start_pos = self.pos

  local parts = {}
  local first = self:match("[a-zA-Z_][a-zA-Z0-9_%-]*")
  if not first then return nil end
  table.insert(parts, first)

  while self:peek() == "." do
    self:advance(1)
    local next_part = self:match("[a-zA-Z_][a-zA-Z0-9_%-]*")
    if not next_part then
      error(string.format("%s:%d:%d: Expected identifier after '.' in tag name", self.filename, self.line, self.col))
    end
    table.insert(parts, next_part)
  end

  local val = table.concat(parts, ".")
  return {
    type = M.TOKEN.IDENT,
    value = val,
    line = start_line,
    col = start_col,
    pos = start_pos,
    end_line = self.line,
    end_col = self.col,
  }
end

-- Read JSX Attribute name: e.g. class, onClick, data-testid, aria-label
function Lexer:read_jsx_attr_name()
  local start_line = self.line
  local start_col = self.col
  local start_pos = self.pos

  local name = self:match("[a-zA-Z_][a-zA-Z0-9_%-]*")
  if name then
    return {
      type = M.TOKEN.ATTR_NAME,
      value = name,
      line = start_line,
      col = start_col,
      pos = start_pos,
      end_line = self.line,
      end_col = self.col,
    }
  end
  return nil
end

-- Read JSX Text content (until '<' or '{')
function Lexer:read_jsx_text()
  local start_line = self.line
  local start_col = self.col
  local start_pos = self.pos

  while self.pos <= self.len do
    local ch = self:peek()
    if ch == "<" or ch == "{" then
      break
    else
      self:advance(1)
    end
  end

  if self.pos > start_pos then
    local raw = self.src:sub(start_pos, self.pos - 1)
    local decoded = decode_entities(raw)
    return {
      type = M.TOKEN.JSX_TEXT,
      value = decoded,
      raw = raw,
      line = start_line,
      col = start_col,
      pos = start_pos,
      end_pos = self.pos - 1,
      end_line = self.line,
      end_col = self.col,
    }
  end
  return nil
end

-- Main next_token method
function Lexer:next_token()
  if self.pos > self.len then
    return {
      type = M.TOKEN.EOF,
      value = "",
      line = self.line,
      col = self.col,
      pos = self.pos,
      end_line = self.line,
      end_col = self.col,
    }
  end

  -- In JSX_CHILDREN mode, we read either child tags (<), embedded expressions ({), or JSX text
  if self.mode == "JSX_CHILDREN" then
    local ch = self:peek()
    if ch == "<" then
      -- Tag open or fragment open or closing tag
      if self.src:sub(self.pos, self.pos + 1) == "</" then
        -- Closing tag or closing fragment
        local start_line = self.line
        local start_col = self.col
        local start_pos = self.pos
        self:advance(2)
        if self:peek() == ">" then
          -- Closing fragment </>
          self:advance(1)
          local top = table.remove(self.tag_stack)
          local top_tag = type(top) == "table" and top.tag or top
          if top_tag ~= "<>" then
            error(string.format("%s:%d:%d: Mismatched fragment close '</>', expected '</%s>'", self.filename, start_line, start_col, tostring(top_tag)))
          end
          self.mode = (type(top) == "table" and top.prev_mode) or (#self.tag_stack == 0 and "LUA" or "JSX_CHILDREN")
          local tok = {
            type = M.TOKEN.FRAGMENT_CLOSE,
            value = "</>",
            line = start_line,
            col = start_col,
            pos = start_pos,
            end_line = self.line,
            end_col = self.col,
          }
          self.prev_token = tok
          return tok
        else
          -- Closing tag </name>
          local tag_name = self:read_jsx_tag_name()
          if not tag_name then
            error(string.format("%s:%d:%d: Expected tag name after '</'", self.filename, self.line, self.col))
          end
          if self:peek() ~= ">" then
            error(string.format("%s:%d:%d: Expected '>' after tag name in closing tag", self.filename, self.line, self.col))
          end
          self:advance(1)
          local top = table.remove(self.tag_stack)
          self.mode = (type(top) == "table" and top.prev_mode) or (#self.tag_stack == 0 and "LUA" or "JSX_CHILDREN")
          local tok = {
            type = M.TOKEN.TAG_END,
            value = "</" .. tag_name.value .. ">",
            tag = tag_name.value,
            line = start_line,
            col = start_col,
            pos = start_pos,
            end_line = self.line,
            end_col = self.col,
          }
          self.prev_token = tok
          return tok
        end
      elseif self.src:sub(self.pos, self.pos + 1) == "<>" then
        -- Opening fragment <>
        local start_line = self.line
        local start_col = self.col
        local start_pos = self.pos
        self:advance(2)
        table.insert(self.tag_stack, { tag = "<>", prev_mode = self.mode })
        local tok = {
          type = M.TOKEN.FRAGMENT_OPEN,
          value = "<>",
          line = start_line,
          col = start_col,
          pos = start_pos,
          end_line = self.line,
          end_col = self.col,
        }
        self.prev_token = tok
        return tok
      else
        -- Child opening tag <tag
        local start_line = self.line
        local start_col = self.col
        local start_pos = self.pos
        self:advance(1)
        local tag_name = self:read_jsx_tag_name()
        if not tag_name then
          error(string.format("%s:%d:%d: Expected tag name after '<'", self.filename, self.line, self.col))
        end
        self.mode = "JSX_TAG"
        table.insert(self.tag_stack, { tag = tag_name.value, prev_mode = "JSX_CHILDREN" })
        local tok = {
          type = M.TOKEN.TAG_OPEN,
          value = "<" .. tag_name.value,
          tag = tag_name.value,
          line = start_line,
          col = start_col,
          pos = start_pos,
          end_line = self.line,
          end_col = self.col,
        }
        self.prev_token = tok
        return tok
      end
    elseif ch == "{" then
      -- Embedded expression inside JSX body
      local start_line = self.line
      local start_col = self.col
      local start_pos = self.pos
      self:advance(1)

      -- Check for JSX comment {/* ... */} or {-- ... --}
      if self.src:sub(self.pos, self.pos + 1) == "/*" then
        local s, e = self.src:find("%*/%s*}", self.pos)
        if s then
          self:advance(e - self.pos + 1)
          local tok = {
            type = M.TOKEN.COMMENT,
            value = self.src:sub(start_pos, self.pos - 1),
            line = start_line,
            col = start_col,
            pos = start_pos,
            end_line = self.line,
            end_col = self.col,
          }
          return tok
        end
      elseif self.src:sub(self.pos, self.pos + 1) == "--" then
        local s, e = self.src:find("%-%-%s*}", self.pos)
        if s then
          self:advance(e - self.pos + 1)
          local tok = {
            type = M.TOKEN.COMMENT,
            value = self.src:sub(start_pos, self.pos - 1),
            line = start_line,
            col = start_col,
            pos = start_pos,
            end_line = self.line,
            end_col = self.col,
          }
          return tok
        end
      end

      table.insert(self.mode_stack, { mode = "JSX_CHILDREN", enter_brace_depth = self.brace_depth })
      self.brace_depth = self.brace_depth + 1
      self.mode = "LUA"
      local tok = {
        type = M.TOKEN.EXPR_OPEN,
        value = "{",
        line = start_line,
        col = start_col,
        pos = start_pos,
        end_line = self.line,
        end_col = self.col,
      }
      self.prev_token = tok
      return tok
    else
      local text_tok = self:read_jsx_text()
      if text_tok then
        self.prev_token = text_tok
        return text_tok
      end
    end
  end

  -- In JSX_TAG mode (reading attributes inside <tag ... >)
  if self.mode == "JSX_TAG" then
    -- Skip whitespace
    local ws = self:read_whitespace()
    if ws then return ws end

    local comment = self:read_comment()
    if comment then return comment end

    local ch = self:peek()
    if ch == "/" and self:peek(1) == ">" then
      -- Self-closing tag />
      local start_line = self.line
      local start_col = self.col
      local start_pos = self.pos
      self:advance(2)
      local top = table.remove(self.tag_stack)
      self.mode = (type(top) == "table" and top.prev_mode) or (#self.tag_stack == 0 and "LUA" or "JSX_CHILDREN")
      local tok = {
        type = M.TOKEN.TAG_SELF_CLOSE,
        value = "/>",
        line = start_line,
        col = start_col,
        pos = start_pos,
        end_line = self.line,
        end_col = self.col,
      }
      self.prev_token = tok
      return tok
    elseif ch == ">" then
      -- Closing of opening tag >
      local start_line = self.line
      local start_col = self.col
      local start_pos = self.pos
      self:advance(1)
      self.mode = "JSX_CHILDREN"
      local tok = {
        type = M.TOKEN.TAG_CLOSE,
        value = ">",
        line = start_line,
        col = start_col,
        pos = start_pos,
        end_line = self.line,
        end_col = self.col,
      }
      self.prev_token = tok
      return tok
    elseif ch == "=" then
      local start_line = self.line
      local start_col = self.col
      local start_pos = self.pos
      self:advance(1)
      local tok = {
        type = M.TOKEN.ATTR_EQUAL,
        value = "=",
        line = start_line,
        col = start_col,
        pos = start_pos,
        end_line = self.line,
        end_col = self.col,
      }
      self.prev_token = tok
      return tok
    elseif ch == '"' or ch == "'" then
      local tok = self:read_string()
      self.prev_token = tok
      return tok
    elseif ch == "{" then
      local start_line = self.line
      local start_col = self.col
      local start_pos = self.pos
      self:advance(1)

      table.insert(self.mode_stack, { mode = "JSX_TAG", enter_brace_depth = self.brace_depth })
      self.brace_depth = self.brace_depth + 1
      self.mode = "LUA"

      -- Check if followed by '...'
      if self.src:sub(self.pos, self.pos + 2) == "..." then
        self:advance(3)
        local tok = {
          type = M.TOKEN.SPREAD_OPEN,
          value = "{...",
          line = start_line,
          col = start_col,
          pos = start_pos,
          end_line = self.line,
          end_col = self.col,
        }
        self.prev_token = tok
        return tok
      end

      local tok = {
        type = M.TOKEN.EXPR_OPEN,
        value = "{",
        line = start_line,
        col = start_col,
        pos = start_pos,
        end_line = self.line,
        end_col = self.col,
      }
      self.prev_token = tok
      return tok
    else
      local attr_name = self:read_jsx_attr_name()
      if attr_name then
        self.prev_token = attr_name
        return attr_name
      end
    end
  end

  -- Normal LUA mode
  local ws = self:read_whitespace()
  if ws then return ws end

  local comment = self:read_comment()
  if comment then return comment end

  -- Check if '}' closes an embedded JSX expression
  if self:peek() == "}" and #self.mode_stack > 0 then
    local top_entry = self.mode_stack[#self.mode_stack]
    if self.brace_depth - 1 == top_entry.enter_brace_depth then
      local start_line = self.line
      local start_col = self.col
      local start_pos = self.pos
      self:advance(1)
      self.brace_depth = self.brace_depth - 1
      self.mode = table.remove(self.mode_stack).mode
      local tok = {
        type = M.TOKEN.EXPR_CLOSE,
        value = "}",
        line = start_line,
        col = start_col,
        pos = start_pos,
        end_line = self.line,
        end_col = self.col,
      }
      self.prev_token = tok
      return tok
    end
  end

  -- Check for JSX opening tag in expression context
  if self:peek() == "<" then
    local next2 = self.src:sub(self.pos, self.pos + 1)
    if next2 == "<>" and self:can_start_jsx() then
      -- Fragment opening <>
      local start_line = self.line
      local start_col = self.col
      local start_pos = self.pos
      local prev_m = self.mode
      self:advance(2)
      self.mode = "JSX_CHILDREN"
      table.insert(self.tag_stack, { tag = "<>", prev_mode = prev_m })
      local tok = {
        type = M.TOKEN.FRAGMENT_OPEN,
        value = "<>",
        line = start_line,
        col = start_col,
        pos = start_pos,
        end_line = self.line,
        end_col = self.col,
      }
      self.prev_token = tok
      return tok
    elseif next2 ~= "<=" and next2 ~= "<<" and self:can_start_jsx() then
      local tag_part = self.src:match("^<([a-zA-Z_][a-zA-Z0-9_%.%-]*)", self.pos)
      if tag_part then
        local start_line = self.line
        local start_col = self.col
        local start_pos = self.pos
        local prev_m = self.mode
        self:advance(1 + #tag_part)
        self.mode = "JSX_TAG"
        table.insert(self.tag_stack, { tag = tag_part, prev_mode = prev_m })
        local tok = {
          type = M.TOKEN.TAG_OPEN,
          value = "<" .. tag_part,
          tag = tag_part,
          line = start_line,
          col = start_col,
          pos = start_pos,
          end_line = self.line,
          end_col = self.col,
        }
        self.prev_token = tok
        return tok
      end
    end
  end

  -- Track brace depth for normal lua tables
  if self:peek() == "{" then
    self.brace_depth = self.brace_depth + 1
  elseif self:peek() == "}" then
    self.brace_depth = self.brace_depth - 1
  end

  -- Identifiers & Keywords
  local ident = self:read_ident_or_keyword()
  if ident then
    self.prev_token = ident
    return ident
  end

  -- Numbers
  local num = self:read_number()
  if num then
    self.prev_token = num
    return num
  end

  -- Strings
  local str = self:read_string()
  if str then
    self.prev_token = str
    return str
  end

  -- Multi-character punctuation
  local start_line = self.line
  local start_col = self.col
  local start_pos = self.pos

  local two = self.src:sub(self.pos, self.pos + 1)
  local three = self.src:sub(self.pos, self.pos + 2)

  if three == "..." then
    self:advance(3)
    local tok = { type = M.TOKEN.PUNCT, value = "...", line = start_line, col = start_col, pos = start_pos, end_line = self.line, end_col = self.col }
    self.prev_token = tok
    return tok
  end

  local two_punct = {
    ["=="] = true, ["~="] = true, ["<="] = true, [">="] = true,
    [".."] = true, ["//"] = true, ["::"] = true, ["<<"] = true, [">>"] = true
  }
  if two_punct[two] then
    self:advance(2)
    local tok = { type = M.TOKEN.PUNCT, value = two, line = start_line, col = start_col, pos = start_pos, end_line = self.line, end_col = self.col }
    self.prev_token = tok
    return tok
  end

  -- Single character punctuation
  local ch = self:peek()
  self:advance(1)
  local tok = { type = M.TOKEN.PUNCT, value = ch, line = start_line, col = start_col, pos = start_pos, end_line = self.line, end_col = self.col }
  self.prev_token = tok
  return tok
end

-- Tokenize entire input into list of non-whitespace tokens (with optional preserve_whitespace)
function M.tokenize(src, filename, options)
  options = options or {}
  local lexer = M.create(src, filename)
  local tokens = {}

  while true do
    local tok = lexer:next_token()
    -- Most token constructors in next_token()/read_* only record end_line/
    -- end_col (for human-readable diagnostics), not an end byte offset.
    -- Parser loc computations (ast.create_loc) fall back to a token's
    -- *start* offset (`.pos`) when `.end_pos` is absent, which silently
    -- truncates any AST node's loc.end to the start of its last token
    -- instead of that token's actual end -- corrupting byte-range consumers
    -- like the LuaLS virtual-source rewriter (src/hydronium_luax/luals/virtual_source.lua)
    -- for any multi-character end token (e.g. a whole string-literal
    -- attribute value). Backfill it centrally here, once, using the
    -- lexer's position immediately after the token was fully consumed.
    if tok.end_pos == nil then
      tok.end_pos = math.max(tok.pos or 1, lexer.pos - 1)
    end
    if not options.include_whitespace and tok.type == M.TOKEN.WHITESPACE then
      -- Skip whitespace
    else
      table.insert(tokens, tok)
    end
    if tok.type == M.TOKEN.EOF then
      break
    end
  end

  return tokens
end

M.new = M.create

return M
