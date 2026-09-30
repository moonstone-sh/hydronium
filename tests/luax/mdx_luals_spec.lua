local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
package.path = "./luax/src/?.lua;./luax/src/?/init.lua;" .. package.path
local mdx = require("hydronium_luax.luals.mdx")

-- Applies OnSetText-style hunks to the original text.
local function apply(text, hunks)
  local out, position = {}, 1
  for _, hunk in ipairs(hunks) do
    out[#out + 1] = text:sub(position, hunk.start - 1)
    out[#out + 1] = hunk.text
    position = hunk.finish + 1
  end
  out[#out + 1] = text:sub(position)
  return table.concat(out)
end

local DOC = [[---
title: Guide
---
```lua setup
local Card = require("Card")
```

# Hello {props.name}

Prose with `{not code}` and \{escaped}.

<Card
  title={props.title}
/>

```lua
print("example {x}")
```

- item {props.count + 1} and inline <Card title="x" />
]]

describe("MDX LuaLS projection", function()
  it("projects a document to valid Lua whose hunks reproduce it", function()
    local hunks = mdx.project(DOC, "file:///p/Guide.mdx")
    assert.truthy((loadstring or load)(hunks.text, "=virtual"))
    assert.equal(apply(DOC, hunks), hunks.text)
  end)

  it("keeps every code byte outside the hunks", function()
    local hunks = mdx.project(DOC, "file:///p/Guide.mdx")
    local function untouched(needle)
      local start = DOC:find(needle, 1, true)
      local finish = start + #needle - 1
      for _, hunk in ipairs(hunks) do
        if hunk.start <= finish and hunk.finish >= start then return false end
      end
      return true
    end
    assert.truthy(untouched('local Card = require("Card")'))
    assert.truthy(untouched("props.name"))
    assert.truthy(untouched("props.title"))
    assert.truthy(untouched("props.count + 1"))
  end)

  it("never projects prose, code spans, escapes or example fences as code", function()
    local text = mdx.project(DOC, "file:///p/Guide.mdx").text
    assert.falsy(text:find("not code", 1, true))
    assert.falsy(text:find("escaped", 1, true))
    assert.falsy(text:find("example", 1, true))
    assert.falsy(text:find("Prose", 1, true))
  end)

  it("stays valid Lua while a document is half typed", function()
    local text = mdx.project("```lua setup\nlocal A = 1\n```\n\nHi {props.na", "file:///p/b.mdx").text
    assert.truthy((loadstring or load)(text, "=virtual"))
    text = mdx.project("Hi <Card title=", "file:///p/c.mdx").text
    assert.truthy((loadstring or load)(text, "=virtual"))
  end)

  it("types plain Markdown as a component module", function()
    local text = mdx.project("# Plain\n\ntext {x}\n", "file:///p/README.md").text
    assert.falsy(text:find("x", 1, true) and text:find("_(x)", 1, true))
    assert.truthy((loadstring or load)(text, "=virtual"))
  end)
end)
