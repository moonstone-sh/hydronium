--[[
  Hydronium LUAX Shared Language Conformance Corpus Specification
  Tests all corpus files under tests/luax/corpus/:
  - lexical_tags.txt: <d.main>, <d.h1>, <d.button>, <UI.Card>
  - components.txt: <Button variant="primary" />
  - spreads_and_attrs.txt: <d.button disabled {...props} onClick={fn} />
  - nested_children.txt: <d.div><d.span>Hello</d.span></d.div>
  - fragments.txt: <><d.h1>1</d.h1><d.h2>2</d.h2></>
  - incomplete_states.txt: <d., <d.button , <d.button onClick={
  Asserts both compiler CST parser and Tree-sitter AST parse all corpus files without crashing.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local parser = require("hydronium_luax.parser")

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    error("Could not open corpus file: " .. tostring(path))
  end
  local content = f:read("*a")
  f:close()
  return content
end

-- Root of the hydronium checkout, so the standalone headless-nvim fallback
-- below can find the real compiled tree-sitter-luax parser (parser/luax.so)
-- and queries on its runtimepath -- without this, `nvim --headless` starts
-- with no `luax` parser registered at all.
local HYDRONIUM_ROOT = (function()
  local info = debug.getinfo(1, "S")
  local src = info and info.source and info.source:gsub("^@", "") or ""
  return src:match("^(.*)/tests/luax/corpus_spec%.lua$") or "."
end)()

--- Parses source with the REAL tree-sitter-luax grammar (not plain "lua" --
--- Neovim's stock Lua grammar has its own error recovery and will produce a
--- non-empty tree for almost anything, including raw JSX syntax it doesn't
--- understand, which made this check pass vacuously without ever loading
--- tree-sitter-luax at all).
local function parse_treesitter_ast(source)
  if _G.vim and _G.vim.treesitter then
    local ok, res = pcall(function()
      local p = _G.vim.treesitter.get_string_parser(source, "luax")
      local trees = p:parse()
      return trees and #trees > 0
    end)
    return ok and res
  end

  -- Standalone fallback via headless Neovim (this is the path actually
  -- taken by `luajit tests/runner.lua`, which has no `_G.vim`).
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if not f then return false, "Cannot write temp file" end
  f:write(source)
  f:close()

  local cmd = string.format(
    'nvim --headless --clean -u NONE -c "set rtp+=%s" -c "lua local fh = io.open(\'%s\', \'r\'); local s = fh:read(\'*a\'); fh:close(); local p = vim.treesitter.get_string_parser(s, \'luax\'); local t = p:parse(); assert(t and #t > 0); os.exit(0)" -c "q" >/dev/null 2>&1',
    HYDRONIUM_ROOT, tmp
  )
  local exit_code = os.execute(cmd)
  os.remove(tmp)
  return exit_code == 0 or exit_code == true
end

describe("LUAX: Shared Language Conformance Corpus", function()

  describe("Lexical Tags Corpus (lexical_tags.txt)", function()
    local path = "tests/luax/corpus/lexical_tags.txt"
    local content = read_file(path)

    it("compiler CST parser constructs AST for <d.main>, <d.h1>, <d.button>, <UI.Card>", function()
      local prog = parser.parse(content, "lexical_tags.luax")
      assert.is_table(prog)
      assert.equal(prog.type, "Program")
      assert.truthy(#prog.body >= 4)

      -- Verify tag names in statements
      local el1 = prog.body[1].values[1]
      assert.equal(el1.type, "JSXElement")
      assert.equal(el1.opening_element.name.object.name, "d")
      assert.equal(el1.opening_element.name.property.name, "main")

      local el2 = prog.body[2].values[1]
      assert.equal(el2.opening_element.name.object.name, "d")
      assert.equal(el2.opening_element.name.property.name, "h1")

      local el3 = prog.body[3].values[1]
      assert.equal(el3.opening_element.name.object.name, "d")
      assert.equal(el3.opening_element.name.property.name, "button")

      local el4 = prog.body[4].values[1]
      assert.equal(el4.opening_element.name.object.name, "UI")
      assert.equal(el4.opening_element.name.property.name, "Card")
    end)

    it("Tree-sitter AST parses lexical_tags.txt without crashing", function()
      local ok = parse_treesitter_ast(content)
      assert.truthy(ok, "Tree-sitter parse of lexical_tags.txt should succeed")
    end)
  end)

  describe("Components Corpus (components.txt)", function()
    local path = "tests/luax/corpus/components.txt"
    local content = read_file(path)

    it("compiler CST parser constructs AST for <Button variant='primary' />", function()
      local prog = parser.parse(content, "components.luax")
      assert.is_table(prog)
      local fn_stmt = prog.body[1]
      local ret_stmt = fn_stmt.body[1]
      local el = ret_stmt.values[1]

      assert.equal(el.type, "JSXElement")
      assert.equal(el.opening_element.name.name, "Button")
      assert.truthy(el.opening_element.self_closing)
      assert.equal(#el.opening_element.attributes, 1)
      assert.equal(el.opening_element.attributes[1].name, "variant")
      assert.equal(el.opening_element.attributes[1].value.value, "primary")
    end)

    it("Tree-sitter AST parses components.txt without crashing", function()
      local ok = parse_treesitter_ast(content)
      assert.truthy(ok, "Tree-sitter parse of components.txt should succeed")
    end)
  end)

  describe("Spreads and Attributes Corpus (spreads_and_attrs.txt)", function()
    local path = "tests/luax/corpus/spreads_and_attrs.txt"
    local content = read_file(path)

    it("compiler CST parser constructs AST for <d.button disabled {...props} onClick={fn} />", function()
      local prog = parser.parse(content, "spreads_and_attrs.luax")
      assert.is_table(prog)
      local fn_stmt = prog.body[1]
      local ret_stmt = fn_stmt.body[1]
      local el = ret_stmt.values[1]

      assert.equal(el.type, "JSXElement")
      assert.equal(el.opening_element.name.property.name, "button")
      assert.equal(#el.opening_element.attributes, 3)

      -- 1: boolean disabled
      assert.equal(el.opening_element.attributes[1].name, "disabled")
      assert.equal(el.opening_element.attributes[1].value.value, true)

      -- 2: spread {...props}
      assert.equal(el.opening_element.attributes[2].type, "JSXSpreadAttribute")
      assert.equal(el.opening_element.attributes[2].argument.name, "props")

      -- 3: expression onClick={fn}
      assert.equal(el.opening_element.attributes[3].name, "onClick")
      assert.equal(el.opening_element.attributes[3].value.type, "JSXExpressionContainer")
    end)

    it("Tree-sitter AST parses spreads_and_attrs.txt without crashing", function()
      local ok = parse_treesitter_ast(content)
      assert.truthy(ok, "Tree-sitter parse of spreads_and_attrs.txt should succeed")
    end)
  end)

  describe("Nested Children Corpus (nested_children.txt)", function()
    local path = "tests/luax/corpus/nested_children.txt"
    local content = read_file(path)

    it("compiler CST parser constructs AST for <d.div><d.span>Hello</d.span></d.div>", function()
      local prog = parser.parse(content, "nested_children.luax")
      assert.is_table(prog)
      local el = prog.body[1].values[1]

      assert.equal(el.type, "JSXElement")
      assert.equal(el.opening_element.name.property.name, "div")
      assert.equal(#el.children, 1)

      local child_el = el.children[1]
      assert.equal(child_el.type, "JSXElement")
      assert.equal(child_el.opening_element.name.property.name, "span")
      assert.equal(#child_el.children, 1)
      assert.equal(child_el.children[1].value, "Hello")
    end)

    it("Tree-sitter AST parses nested_children.txt without crashing", function()
      local ok = parse_treesitter_ast(content)
      assert.truthy(ok, "Tree-sitter parse of nested_children.txt should succeed")
    end)
  end)

  describe("Fragments Corpus (fragments.txt)", function()
    local path = "tests/luax/corpus/fragments.txt"
    local content = read_file(path)

    it("compiler CST parser constructs AST for <><d.h1>1</d.h1><d.h2>2</d.h2></>", function()
      local prog = parser.parse(content, "fragments.luax")
      assert.is_table(prog)
      local frag = prog.body[1].values[1]

      assert.equal(frag.type, "JSXFragment")
      assert.equal(#frag.children, 2)
      assert.equal(frag.children[1].opening_element.name.property.name, "h1")
      assert.equal(frag.children[2].opening_element.name.property.name, "h2")
    end)

    it("Tree-sitter AST parses fragments.txt without crashing", function()
      local ok = parse_treesitter_ast(content)
      assert.truthy(ok, "Tree-sitter parse of fragments.txt should succeed")
    end)
  end)

  describe("Incomplete States Corpus (incomplete_states.txt)", function()
    local path = "tests/luax/corpus/incomplete_states.txt"
    local content = read_file(path)

    local snippets = {
      "<d.",
      "<d.button ",
      "<d.button onClick={",
    }

    for idx, snippet in ipairs(snippets) do
      it(string.format("compiler CST parser handles incomplete snippet %d (%q) without crashing", idx, snippet), function()
        local ok, err = pcall(parser.parse, snippet, "incomplete.luax")
        -- Incomplete syntax must raise a clean Lua error rather than crashing
        assert.falsy(ok, "Incomplete syntax should not produce valid AST")
        assert.is_string(err)
      end)

      it(string.format("Tree-sitter AST parses incomplete snippet %d (%q) without crashing", idx, snippet), function()
        local ok = parse_treesitter_ast(snippet)
        assert.truthy(ok, "Tree-sitter must recover from incomplete syntax without crashing")
      end)
    end
  end)
end)
