-- Formatter Test Suite for Hydronium LUAX
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local formatter = require("hydronium_luax.formatter")

describe("LUAX: Formatter & CST Pretty Printing", function()

  describe("Formatter Idempotence (format(format(x)) == format(x))", function()
    it("is strictly idempotent for simple and nested components", function()
      local src = [[
        local function Button(props)
          return <button class="btn" disabled>
            <span>{props.label}</span>
          </button>
        end
      ]]

      local once = formatter.format(src)
      local twice = formatter.format(once)
      local thrice = formatter.format(twice)

      assert.equal(once, twice, "format(format(x)) != format(x)")
      assert.equal(twice, thrice, "format(format(format(x))) != format(format(x))")
    end)

    it("is idempotent for complex components with spreads, fragments, and comments", function()
      local src = [[
        -- Header navigation component
        local function Nav(props)
          return <nav class="navbar" {...props.extra}>
            <>
              <a href="/">Home</a>
              <a href="/about">About</a>
            </>
            <input type="search" placeholder="Search..." disabled />
            {-- Navigation links footer --}
          </nav>
        end
      ]]

      local once = formatter.format(src)
      local twice = formatter.format(once)

      assert.equal(once, twice, "format(format(x)) must match format(x) exactly for complex components")
    end)

    it("is idempotent on fixture sample component", function()
      local f = io.open("tests/fixtures/sample_component.luax", "r")
      assert.truthy(f)
      local src = f:read("*a")
      f:close()

      local f1 = formatter.format(src)
      local f2 = formatter.format(f1)
      assert.equal(f1, f2, "Fixture sample_component.luax formatting must be idempotent")
    end)
  end)

  describe("Comment Preservation", function()
    it("preserves leading file comments and function comments", function()
      local src = [[
        -- Module documentation comment
        -- Version: 1.0.0
        local function Header()
          return <header><h1>Title</h1></header>
        end
      ]]

      local formatted = formatter.format(src)
      assert.truthy(formatted:find("-- Module documentation comment", 1, true))
      assert.truthy(formatted:find("-- Version: 1.0.0", 1, true))
    end)

    it("preserves embedded JSX comments inside tag children", function()
      local src = [[
        local x = <div>
          {-- Embedded note inside element --}
          <span>Content</span>
        </div>
      ]]

      local formatted = formatter.format(src)
      assert.truthy(formatted:find("Embedded note inside element", 1, true))
    end)
  end)

  describe("Indentation and Style Control", function()
    it("formats with custom indentation string (e.g. 4 spaces)", function()
      local src = [[
        local el = <div>
          <span>Item</span>
        </div>
      ]]

      local formatted2 = formatter.format(src, { indent_str = "  " })
      local formatted4 = formatter.format(src, { indent_str = "    " })

      assert.truthy(formatted2:find("\n  <span>Item</span>", 1, true))
      assert.truthy(formatted4:find("\n    <span>Item</span>", 1, true))
    end)

    it("formats boolean attributes and self-closing tags canonically", function()
      local src = "<input disabled checked />"
      local formatted = formatter.format(src)

      assert.truthy(formatted:find("<input disabled checked />", 1, true))
    end)
  end)

end)
