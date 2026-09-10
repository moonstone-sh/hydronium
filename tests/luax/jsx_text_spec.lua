local runner = require("tests.runner")
local parser = require("hydronium_luax.parser")
local compiler = require("hydronium_luax.compiler")

--- Returns the folded values of a JSX element's children, with elements and
--- embedded expressions represented as markers, so a spec can assert on the
--- exact child sequence including whitespace-only text children.
local function children_of(src)
  local prog = parser.parse(src)
  local out = {}
  for _, child in ipairs(prog.body[1].expression.children) do
    if child.type == "JSXText" then
      out[#out + 1] = { text = child.value }
    elseif child.type == "JSXExpressionContainer" then
      out[#out + 1] = { expr = true }
    else
      out[#out + 1] = { element = true }
    end
  end
  return out
end

local function texts_of(src)
  local out = {}
  for _, c in ipairs(children_of(src)) do
    if c.text then out[#out + 1] = c.text end
  end
  return out
end

describe("LUAX JSX text folding", function()
  -- These expectations are not invented: every one of them was checked
  -- against the real `cleanJSXElementLiteralChild` in @babel/types 8.0.4,
  -- the implementation React/Preact/Vue-JSX/Solid all mirror.

  describe("(a) single-line runs are preserved verbatim", function()
    it("keeps the space between a closing tag and following text", function()
      -- The original bug: this rendered as "xand".
      local kids = children_of("<p><d.code>x</d.code> and</p>")
      assert.equal(#kids, 2)
      assert.truthy(kids[1].element)
      assert.equal(kids[2].text, " and")
    end)

    it("keeps the space between text and a following opening tag", function()
      local kids = children_of("<p>and <d.code>x</d.code></p>")
      assert.equal(#kids, 2)
      assert.equal(kids[1].text, "and ")
      assert.truthy(kids[2].element)
    end)

    it("keeps the spaces on BOTH sides of an inline element", function()
      -- The exact shape that shipped broken as "Powered by<strong>...".
      local kids = children_of("<p>Powered by <strong>Hydronium</strong> today</p>")
      assert.equal(#kids, 3)
      assert.equal(kids[1].text, "Powered by ")
      assert.truthy(kids[2].element)
      assert.equal(kids[3].text, " today")
    end)

    it("keeps whitespace adjacent to an embedded expression", function()
      local kids = children_of("<p>x {y} z</p>")
      assert.equal(#kids, 3)
      assert.equal(kids[1].text, "x ")
      assert.truthy(kids[2].expr)
      assert.equal(kids[3].text, " z")
    end)

    it("preserves a lone space between two elements on one line", function()
      local kids = children_of("<p><b>a</b> <i>b</i></p>")
      assert.equal(#kids, 3)
      assert.truthy(kids[1].element)
      assert.equal(kids[2].text, " ")
      assert.truthy(kids[3].element)
    end)

    it("does NOT collapse internal runs of whitespace", function()
      -- Babel leaves interior whitespace alone; only line edges are touched.
      assert.equal(texts_of("<p>a    b</p>")[1], "a    b")
    end)

    it("preserves leading and trailing whitespace of the whole run", function()
      assert.equal(parser.fold_text("  spaced  "), "  spaced  ")
    end)

    it("converts tabs to single spaces without trimming them", function()
      assert.equal(parser.fold_text("\ta\t"), " a ")
    end)
  end)

  describe("(b) multi-line runs collapse per-line edge whitespace", function()
    it("joins lines with exactly one space", function()
      assert.equal(texts_of("<p>\n  Hello\n  World\n</p>")[1], "Hello World")
    end)

    it("keeps leading whitespace on the FIRST line only", function()
      -- First line's leading whitespace is significant; the second line's
      -- indentation is not.
      assert.equal(parser.fold_text("  a\n  b"), "  a b")
    end)

    it("keeps trailing whitespace on the LAST line only", function()
      assert.equal(parser.fold_text("a  \nb  "), "a b  ")
    end)

    it("folds a run that starts mid-line and wraps to the next", function()
      local kids = children_of("<p><b>x</b> and\n   more</p>")
      assert.equal(#kids, 2)
      assert.truthy(kids[1].element)
      assert.equal(kids[2].text, " and more")
    end)

    it("normalizes CRLF and lone CR identically to LF", function()
      assert.equal(parser.fold_text("a\r\nb"), "a b")
      assert.equal(parser.fold_text("a\rb"), "a b")
      assert.equal(parser.fold_text("a\nb"), "a b")
    end)
  end)

  describe("(c) whitespace-only lines contribute nothing", function()
    it("drops indentation between siblings on separate lines", function()
      local kids = children_of("<p>\n  <b>a</b>\n  <i>b</i>\n</p>")
      assert.equal(#kids, 2)
      assert.truthy(kids[1].element)
      assert.truthy(kids[2].element)
    end)

    it("folds a pure-indentation run to the empty string", function()
      assert.equal(parser.fold_text("\n    "), "")
      assert.equal(parser.fold_text("\n\n\n"), "")
      assert.equal(parser.fold_text("  \n  \n  "), "")
    end)

    it("adds no extra space across a blank line between two words", function()
      assert.equal(parser.fold_text("a\n\nb"), "a b")
    end)

    it("emits no trailing space after the last non-empty line", function()
      assert.equal(parser.fold_text("\n  Hello\n  World\n  "), "Hello World")
    end)
  end)

  describe("(d) the emitted code carries the preserved whitespace", function()
    -- Folding correctly in the parser is not enough: the CodeEmitter used to
    -- drop any text child with no non-whitespace character, which discarded
    -- the very space this fix preserves.
    it("emits the leading and trailing spaces around an inline element", function()
      local code = compiler.compile("local el = <p>Powered by <strong>Hydronium</strong> today</p>").code
      assert.truthy(code:find('"Powered by "', 1, true))
      assert.truthy(code:find('" today"', 1, true))
    end)

    it("emits a lone space between two elements as a real child", function()
      local code = compiler.compile("local el = <p><b>a</b> <i>b</i></p>").code
      assert.truthy(code:find('" "', 1, true))
    end)

    it("still emits no text child for pure indentation between siblings", function()
      local code = compiler.compile("local el = <p>\n  <b>a</b>\n  <i>b</i>\n</p>").code
      assert.falsy(code:find('" "', 1, true))
      assert.falsy(code:find('""', 1, true))
    end)
  end)
end)
