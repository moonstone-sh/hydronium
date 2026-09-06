-- Lexer Test Suite for Hydronium LUAX
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local lexer = require("hydronium.luax.lexer")
local TOKEN = lexer.TOKEN

describe("LUAX: Lexer Tokenization", function()

  describe("Standard Lua Tokenization", function()
    it("tokenizes keywords, identifiers, and numbers", function()
      local src = "local count = 42 return count"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[1].type, TOKEN.KEYWORD)
      assert.equal(tokens[1].value, "local")
      assert.equal(tokens[2].type, TOKEN.IDENT)
      assert.equal(tokens[2].value, "count")
      assert.equal(tokens[3].type, TOKEN.PUNCT)
      assert.equal(tokens[3].value, "=")
      assert.equal(tokens[4].type, TOKEN.NUMBER)
      assert.equal(tokens[4].value, "42")
      assert.equal(tokens[5].type, TOKEN.KEYWORD)
      assert.equal(tokens[5].value, "return")
      assert.equal(tokens[6].type, TOKEN.IDENT)
      assert.equal(tokens[6].value, "count")
    end)

    it("tokenizes string literals including quotes and escapes", function()
      local src = [==[local a = "hello \"world\"" local b = 'foo' local c = [[long string]]]==]
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[4].type, TOKEN.STRING)
      assert.equal(tokens[4].value, [["hello \"world\""]])
      assert.equal(tokens[8].type, TOKEN.STRING)
      assert.equal(tokens[8].value, "'foo'")
      assert.equal(tokens[12].type, TOKEN.STRING)
      assert.equal(tokens[12].value, "[[long string]]")
    end)

    it("tokenizes operators and punctuation correctly", function()
      local src = "a == b and c ~= d or e <= f and g >= h"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[2].type, TOKEN.PUNCT)
      assert.equal(tokens[2].value, "==")
      assert.equal(tokens[4].type, TOKEN.KEYWORD)
      assert.equal(tokens[4].value, "and")
      assert.equal(tokens[6].type, TOKEN.PUNCT)
      assert.equal(tokens[6].value, "~=")
      assert.equal(tokens[10].type, TOKEN.PUNCT)
      assert.equal(tokens[10].value, "<=")
      assert.equal(tokens[14].type, TOKEN.PUNCT)
      assert.equal(tokens[14].value, ">=")
    end)
  end)

  describe("Disambiguation of '<' as Operator vs Tag", function()
    it("tokenizes '<' and '>' as comparison operators in standard Lua expressions", function()
      local src = "if a < b and c > d then return a < 10 end"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[1].type, TOKEN.KEYWORD) -- if
      assert.equal(tokens[2].type, TOKEN.IDENT)   -- a
      assert.equal(tokens[3].type, TOKEN.PUNCT)   -- <
      assert.equal(tokens[3].value, "<")
      assert.equal(tokens[4].type, TOKEN.IDENT)   -- b
      assert.equal(tokens[7].type, TOKEN.PUNCT)   -- >
      assert.equal(tokens[7].value, ">")
      assert.equal(tokens[12].type, TOKEN.PUNCT)  -- <
      assert.equal(tokens[12].value, "<")
    end)

    it("preserves strings containing HTML tags without entering JSX mode", function()
      local src = [[local html = "<div><span>Text</span></div>"]]
      local tokens = lexer.tokenize(src)

      assert.equal(#tokens, 5) -- local, html, =, STRING, EOF
      assert.equal(tokens[4].type, TOKEN.STRING)
      assert.equal(tokens[4].value, [["<div><span>Text</span></div>"]])
    end)

    it("tokenizes '<' as JSX tag after return, '=', '(', or '{'", function()
      local t1 = lexer.tokenize("return <div />")
      assert.equal(t1[2].type, TOKEN.TAG_OPEN)
      assert.equal(t1[2].value, "<div")

      local t2 = lexer.tokenize("local x = <span />")
      assert.equal(t2[4].type, TOKEN.TAG_OPEN)
      assert.equal(t2[4].value, "<span")

      local t3 = lexer.tokenize("fn(<button />)")
      assert.equal(t3[3].type, TOKEN.TAG_OPEN)
      assert.equal(t3[3].value, "<button")
    end)
  end)

  describe("Tags and Fragments", function()
    it("tokenizes intrinsic opening, closing, and self-closing tags", function()
      local src = "<div><span /></div>"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[1].type, TOKEN.TAG_OPEN)
      assert.equal(tokens[1].value, "<div")
      assert.equal(tokens[2].type, TOKEN.TAG_CLOSE)
      assert.equal(tokens[2].value, ">")
      assert.equal(tokens[3].type, TOKEN.TAG_OPEN)
      assert.equal(tokens[3].value, "<span")
      assert.equal(tokens[4].type, TOKEN.TAG_SELF_CLOSE)
      assert.equal(tokens[4].value, "/>")
      assert.equal(tokens[5].type, TOKEN.TAG_END)
      assert.equal(tokens[5].value, "</div>")
    end)

    it("tokenizes component tags and dotted component paths", function()
      local src = "<UI.Layout.Grid.Item size='large' />"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[1].type, TOKEN.TAG_OPEN)
      assert.equal(tokens[1].value, "<UI.Layout.Grid.Item")
      assert.equal(tokens[2].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[2].value, "size")
      assert.equal(tokens[3].type, TOKEN.ATTR_EQUAL)
      assert.equal(tokens[4].type, TOKEN.STRING)
      assert.equal(tokens[4].value, "'large'")
      assert.equal(tokens[5].type, TOKEN.TAG_SELF_CLOSE)
    end)

    it("tokenizes fragments <> and </>", function()
      local src = "<><span /></>"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[1].type, TOKEN.FRAGMENT_OPEN)
      assert.equal(tokens[1].value, "<>")
      assert.equal(tokens[2].type, TOKEN.TAG_OPEN)
      assert.equal(tokens[2].value, "<span")
      assert.equal(tokens[3].type, TOKEN.TAG_SELF_CLOSE)
      assert.equal(tokens[4].type, TOKEN.FRAGMENT_CLOSE)
      assert.equal(tokens[4].value, "</>")
    end)
  end)

  describe("Attributes, Spreads, and Expressions", function()
    it("tokenizes string, expression, and boolean attributes", function()
      local src = "<input type='text' disabled value={state.text} />"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[1].type, TOKEN.TAG_OPEN)
      assert.equal(tokens[2].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[2].value, "type")
      assert.equal(tokens[3].type, TOKEN.ATTR_EQUAL)
      assert.equal(tokens[4].type, TOKEN.STRING)
      assert.equal(tokens[5].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[5].value, "disabled")
      assert.equal(tokens[6].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[6].value, "value")
      assert.equal(tokens[7].type, TOKEN.ATTR_EQUAL)
      assert.equal(tokens[8].type, TOKEN.EXPR_OPEN)
      assert.equal(tokens[9].type, TOKEN.IDENT)
      assert.equal(tokens[9].value, "state")
      assert.equal(tokens[10].type, TOKEN.PUNCT)
      assert.equal(tokens[10].value, ".")
      assert.equal(tokens[11].type, TOKEN.IDENT)
      assert.equal(tokens[11].value, "text")
      assert.equal(tokens[12].type, TOKEN.EXPR_CLOSE)
      assert.equal(tokens[13].type, TOKEN.TAG_SELF_CLOSE)
    end)

    it("tokenizes spread attributes {...props}", function()
      local src = "<div id='card' {...props} class='highlight' />"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[1].type, TOKEN.TAG_OPEN)
      assert.equal(tokens[2].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[2].value, "id")
      assert.equal(tokens[3].type, TOKEN.ATTR_EQUAL)
      assert.equal(tokens[4].type, TOKEN.STRING)
      assert.equal(tokens[5].type, TOKEN.SPREAD_OPEN)
      assert.equal(tokens[5].value, "{...")
      assert.equal(tokens[6].type, TOKEN.IDENT)
      assert.equal(tokens[6].value, "props")
      assert.equal(tokens[7].type, TOKEN.EXPR_CLOSE)
      assert.equal(tokens[8].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[8].value, "class")
      assert.equal(tokens[9].type, TOKEN.ATTR_EQUAL)
      assert.equal(tokens[10].type, TOKEN.STRING)
      assert.equal(tokens[11].type, TOKEN.TAG_SELF_CLOSE)
    end)

    it("tokenizes dash-separated attributes (data-*, aria-*)", function()
      local src = "<button data-testid='submit-btn' aria-hidden='true' />"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[2].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[2].value, "data-testid")
      assert.equal(tokens[5].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[5].value, "aria-hidden")
    end)

    it("handles complex Lua expressions and callbacks inside attribute braces", function()
      local src = "<button onClick={function(e) handleClick(e, 1 + 2) end}>Click</button>"
      local tokens = lexer.tokenize(src)

      assert.equal(tokens[1].type, TOKEN.TAG_OPEN)
      assert.equal(tokens[2].type, TOKEN.ATTR_NAME)
      assert.equal(tokens[3].type, TOKEN.ATTR_EQUAL)
      assert.equal(tokens[4].type, TOKEN.EXPR_OPEN)
      assert.equal(tokens[5].type, TOKEN.KEYWORD)
      assert.equal(tokens[5].value, "function")
      -- Find closing brace
      local found_close = false
      for _, t in ipairs(tokens) do
        if t.type == TOKEN.EXPR_CLOSE then
          found_close = true
          break
        end
      end
      assert.truthy(found_close)
    end)
  end)

  describe("Comments", function()
    it("tokenizes standard Lua comments and JSX comments", function()
      local src = [[
        -- Standard comment
        local x = <div>
          {/* JSX block comment */}
          <span>Text</span>
        </div>
      ]]
      local tokens = lexer.tokenize(src, "test.luax", { include_comments = true })

      local comment_count = 0
      for _, t in ipairs(tokens) do
        if t.type == TOKEN.COMMENT then
          comment_count = comment_count + 1
        end
      end
      assert.equal(comment_count, 2)
    end)
  end)

  describe("Source Coordinates", function()
    it("tracks line and column numbers accurately across multiple lines", function()
      local src = "local a = 1\nlocal b = <div\n  class='my-div'\n/>"
      local tokens = lexer.tokenize(src)

      -- 'local b' is line 2
      assert.equal(tokens[5].line, 2)
      assert.equal(tokens[5].value, "local")

      -- '<div' is line 2
      assert.equal(tokens[8].line, 2)
      assert.equal(tokens[8].value, "<div")

      -- 'class' is line 3
      assert.equal(tokens[9].line, 3)
      assert.equal(tokens[9].value, "class")

      -- '/>' is line 4
      assert.equal(tokens[12].line, 4)
      assert.equal(tokens[12].value, "/>")
    end)
  end)

end)
