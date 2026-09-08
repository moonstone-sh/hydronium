-- Parser Test Suite for Hydronium LUAX
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local parser = require("hydronium_luax.parser")

describe("LUAX: Parser CST/AST Construction", function()

  describe("Intrinsic Elements and Children", function()
    it("parses intrinsic elements and nested hierarchies", function()
      local src = [[
        local view = <div class="container" id="main">
          <span>Hello World</span>
          <hr />
        </div>
      ]]
      local prog = parser.parse(src, "test.luax")
      assert.equal(prog.type, "Program")
      assert.equal(#prog.body, 1)

      local local_stmt = prog.body[1]
      assert.equal(local_stmt.type, "LocalStatement")
      local el = local_stmt.values[1]
      assert.equal(el.type, "JSXElement")
      assert.equal(el.opening_element.name.name, "div")
      assert.falsy(el.opening_element.self_closing)

      -- 2 attributes
      assert.equal(#el.opening_element.attributes, 2)
      assert.equal(el.opening_element.attributes[1].name, "class")
      assert.equal(el.opening_element.attributes[1].value.value, "container")
      assert.equal(el.opening_element.attributes[2].name, "id")
      assert.equal(el.opening_element.attributes[2].value.value, "main")

      -- 2 children: span and hr
      assert.equal(#el.children, 2)
      assert.equal(el.children[1].type, "JSXElement")
      assert.equal(el.children[1].opening_element.name.name, "span")
      assert.equal(el.children[2].type, "JSXElement")
      assert.equal(el.children[2].opening_element.name.name, "hr")
      assert.truthy(el.children[2].opening_element.self_closing)
    end)
  end)

  describe("Components and Dotted Paths", function()
    it("parses functional components with PascalCase identifiers", function()
      local src = "local app = <ProfileCard username='Alice' active={true} />"
      local prog = parser.parse(src)
      local el = prog.body[1].values[1]

      assert.equal(el.type, "JSXElement")
      assert.equal(el.opening_element.name.type, "Identifier")
      assert.equal(el.opening_element.name.name, "ProfileCard")
      assert.truthy(el.opening_element.self_closing)
    end)

    it("parses dotted path member expressions as tag names", function()
      local src = "local btn = <UI.Layout.Grid.Item span={4} />"
      local prog = parser.parse(src)
      local el = prog.body[1].values[1]

      assert.equal(el.type, "JSXElement")
      local name_node = el.opening_element.name
      assert.equal(name_node.type, "JSXMemberExpression")
      assert.equal(name_node.property.name, "Item")
      assert.equal(name_node.object.property.name, "Grid")
      assert.equal(name_node.object.object.property.name, "Layout")
      assert.equal(name_node.object.object.object.name, "UI")
    end)
  end)

  describe("Fragments", function()
    it("parses fragment containers <> ... </>", function()
      local src = [[
        local list = <>
          <li>Item 1</li>
          <li>Item 2</li>
        </>
      ]]
      local prog = parser.parse(src)
      local frag = prog.body[1].values[1]

      assert.equal(frag.type, "JSXFragment")
      assert.equal(#frag.children, 2)
      assert.equal(frag.children[1].opening_element.name.name, "li")
      assert.equal(frag.children[2].opening_element.name.name, "li")
    end)
  end)

  describe("Attributes, Boolean Shorthands, and Spreads", function()
    it("parses boolean attributes defaulting to true", function()
      local src = "<input disabled checked required />"
      local prog = parser.parse(src)
      local el = prog.body[1].expression

      local attrs = el.opening_element.attributes
      assert.equal(#attrs, 3)
      assert.equal(attrs[1].name, "disabled")
      assert.truthy(attrs[1].value.value)
      assert.equal(attrs[2].name, "checked")
      assert.truthy(attrs[2].value.value)
      assert.equal(attrs[3].name, "required")
      assert.truthy(attrs[3].value.value)
    end)

    it("parses spread attributes {...props}", function()
      local src = "<div class='card' {...props} id='c1' {...extra} />"
      local prog = parser.parse(src)
      local el = prog.body[1].expression

      local attrs = el.opening_element.attributes
      assert.equal(#attrs, 4)
      assert.equal(attrs[1].type, "JSXAttribute")
      assert.equal(attrs[1].name, "class")

      assert.equal(attrs[2].type, "JSXSpreadAttribute")
      assert.equal(attrs[2].argument.name, "props")

      assert.equal(attrs[3].type, "JSXAttribute")
      assert.equal(attrs[3].name, "id")

      assert.equal(attrs[4].type, "JSXSpreadAttribute")
      assert.equal(attrs[4].argument.name, "extra")
    end)
  end)

  describe("Entity Decoding and Text Folding", function()
    it("decodes XML and HTML entities correctly", function()
      local raw = "Hello &amp; &lt;World&gt; &quot;quoted&quot; &#39;apostrophe&#39; &nbsp;"
      local decoded = parser.decode_entities(raw)

      assert.truthy(decoded:find("&", 1, true))
      assert.truthy(decoded:find("<", 1, true))
      assert.truthy(decoded:find(">", 1, true))
      assert.truthy(decoded:find('"', 1, true))
      assert.truthy(decoded:find("'", 1, true))
      assert.truthy(decoded:find("\194\160", 1, true))
    end)

    it("folds multiline JSX text and normalizes inter-tag indentation", function()
      local raw = [[
        Hello
        wonderful
        World
      ]]
      local folded = parser.fold_text(raw)
      assert.equal(folded, "Hello wonderful World")
    end)

    it("automatically decodes entities in parsed JSXText child nodes", function()
      local src = "<p>Design &amp; Technology &copy; 2026</p>"
      local prog = parser.parse(src)
      local text_node = prog.body[1].expression.children[1]

      assert.equal(text_node.type, "JSXText")
      assert.truthy(text_node.value:find("&", 1, true))
      assert.truthy(text_node.value:find("Design & Technology"))
    end)
  end)

  describe("Malformed Syntax Recovery and Diagnostics", function()
    it("throws a descriptive syntax error with coordinates on unclosed tags", function()
      local src = "local x = <div><span>Unclosed</div>"
      assert.has_error(function()
        parser.parse(src, "unclosed.luax")
      end, "Closing tag")
    end)

    it("recovers gracefully and collects diagnostics when recover=true", function()
      local src = "local x = <div><span>Mismatch</div>"
      local prog = parser.parse(src, "mismatch.luax", { recover = true })

      assert.truthy(prog)
      assert.is_table(prog.diagnostics)
      assert.truthy(#prog.diagnostics >= 1)
      assert.truthy(prog.diagnostics[1].message:find("Closing tag") or prog.diagnostics[1].message:find("Expected"))
    end)
  end)

end)
