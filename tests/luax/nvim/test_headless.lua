--[[
  Hydronium Headless Neovim Integration Tests
  Verifies:
  1. Filetype detection (*.luax -> filetype=luax)
  2. Tree-sitter parser loading and query compilation (highlights.scm)
  3. :checkhealth hydronium reporting OK
--]]

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  ✓ PASS " .. name)
  else
    failed = failed + 1
    table.insert(errors, { name = name, err = tostring(err) })
    print("  ✗ FAIL " .. name .. " - " .. tostring(err))
  end
end

print("=== Running LUAX Headless Neovim Integration Suite ===")

local info = debug.getinfo(1, "S")
local this_file = info.source:gsub("^@", "")
local workspace_root = this_file:match("^(.*)/tests/luax/nvim/test_headless%.lua$")
assert(workspace_root, "Could not determine workspace root from test file path")
local luax_root = workspace_root .. "/luax"
local luax_entry = luax_root .. "/nvim/lua/luax/init.lua"

-- The canonical runtime module is `luax`, never the Hydronium core package
-- or a compatibility alias.
test("Plugin Loading > canonical luax.nvim API is loaded", function()
  local plugin = require("luax")
  assert(type(plugin.setup) == "function", "Expected canonical plugin setup() API")
  assert(type(plugin.remove_tag_at_cursor) == "function", "Expected canonical tag-editing API")
  assert(plugin.get_root_dir() == luax_root, "Expected LUAX root, got: " .. plugin.get_root_dir())
  plugin.setup({ autotag = false })
  assert(
    vim.fn.index(vim.api.nvim_list_runtime_paths(), luax_root) >= 0,
    "Expected setup() to add the self-located LUAX package root to runtimepath"
  )
end)

-- Test 1: Filetype detection
test("Filetype Detection > detects *.luax files as filetype=luax", function()
  local ft = vim.filetype.match({ filename = "MyComponent.luax" })
  assert(ft == "luax", "Expected filetype 'luax', got: " .. tostring(ft))

  -- Buffer test
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "test_file.luax")
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("filetype detect")
  end)
  local buf_ft = vim.bo[buf].filetype
  assert(buf_ft == "luax", "Expected buffer filetype 'luax', got: " .. tostring(buf_ft))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Test 2: Tree-sitter parser loading
test("Tree-sitter > loads 'luax' parser and generates valid AST", function()
  local sample_code = [[
    local function Counter()
      return (
        <d.div class="counter">
          <d.h1>Hydronium Counter</d.h1>
          <d.button disabled={false} onClick={handleClick}>
            Increment
          </d.button>
          <d.input type="text" placeholder="Value..." />
        </d.div>
      )
    end
    return Counter
  ]]

  local parser = vim.treesitter.get_string_parser(sample_code, "luax")
  assert(parser ~= nil, "Expected vim.treesitter.get_string_parser to return parser for 'luax'")

  local trees = parser:parse()
  assert(trees and #trees > 0, "Expected parser:parse() to return syntax trees")

  local root = trees[1]:root()
  assert(root:type() == "program", "Expected root node type 'program', got: " .. root:type())
  assert(not root:has_error(), "Expected valid syntax tree without syntax errors")
end)

-- Test 3: Tree-sitter query compilation
test("Tree-sitter > compiles 'luax' highlights query successfully", function()
  local query = vim.treesitter.query.get("luax", "highlights")
  assert(query ~= nil, "Expected vim.treesitter.query.get('luax', 'highlights') to return compiled query")
  assert(query.captures and #query.captures > 0, "Expected compiled query to contain capture groups")
end)

-- Test 4: :checkhealth luax
test("Healthcheck > :checkhealth luax returns OK", function()
  -- Intercept health reporting to verify OK status
  local reported_oks = 0
  local reported_errors = 0

  local orig_ok = vim.health.ok
  local orig_error = vim.health.error

  vim.health.ok = function(msg)
    reported_oks = reported_oks + 1
    if orig_ok then orig_ok(msg) end
  end

  vim.health.error = function(msg)
    reported_errors = reported_errors + 1
    if orig_error then orig_error(msg) end
  end

  -- The health module resolves Neovim's reporting functions when it is
  -- loaded. Reload it after installing our interceptors so this test observes
  -- the real healthcheck contract rather than an implementation detail.
  package.loaded["luax.health"] = nil
  local health_mod = require("luax.health")
  assert(type(health_mod.check) == "function", "Expected luax.health to export check function")

  local ok, err = pcall(health_mod.check)

  vim.health.ok = orig_ok
  vim.health.error = orig_error

  assert(ok, "health.check() raised unexpected error: " .. tostring(err))
  assert(reported_errors == 0, "health.check() reported " .. reported_errors .. " errors")
  assert(reported_oks >= 3, "Expected at least 3 health.ok checks, got: " .. reported_oks)
end)

-- Test 5: nvim-ts-autotag "linked editing" integration (luax.nvim's
-- M.setup_autotag). This is an *optional* peer plugin, not a LUAX
-- dependency, so this test degrades gracefully rather than failing hard
-- when it isn't installed on the machine running the suite -- but if it
-- IS available (as it is on a machine that has it in its plugin manager's
-- data dir), it exercises the real thing: registers tree-sitter-luax's
-- node names into nvim-ts-autotag's per-filetype config and verifies an
-- actual auto-close-on-`>` edit through real insert-mode keystrokes.
test("Autotag > registers luax tag config and auto-closes tags when nvim-ts-autotag is available", function()
  -- Look for nvim-ts-autotag under common plugin-manager data dirs and add
  -- it to rtp if found; otherwise this test asserts only the graceful
  -- no-op contract.
  local candidates = {
    vim.fn.stdpath("data") .. "/lazy/nvim-ts-autotag",
    vim.fn.stdpath("data") .. "/site/pack/packer/start/nvim-ts-autotag",
    -- run_nvim_tests.sh runs with an isolated XDG_DATA_HOME, which hides a
    -- real, already-installed plugin under the actual home directory --
    -- check there too so this test exercises the real integration on a
    -- machine that has it, instead of only ever taking the degraded path.
    vim.fn.expand("~/.local/share/nvim/lazy/nvim-ts-autotag"),
  }
  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
    end
  end

  local luax = dofile(luax_entry)

  local ts_autotag_available = pcall(require, "nvim-ts-autotag.config.init")
  if not ts_autotag_available then
    -- Graceful degradation contract: must not error when the peer plugin
    -- is absent.
    local ok = luax.setup_autotag()
    assert(ok == false, "Expected setup_autotag() to return false when nvim-ts-autotag isn't installed")
    print("    (nvim-ts-autotag not installed in this environment -- skipping the deeper behavioral check)")
    return
  end

  local registered = luax.setup_autotag()
  assert(registered == true, "Expected setup_autotag() to return true when nvim-ts-autotag is available")

  local TagConfigs = require("nvim-ts-autotag.config.init")
  local patterns = TagConfigs:get_patterns("luax")
  assert(patterns, "Expected a registered 'luax' tag config in nvim-ts-autotag")
  assert(patterns.element_tag[1] == "element_expression", "Expected element_tag to reference element_expression")

  -- Real end-to-end check: open a buffer, attach, and drive
  -- nvim-ts-autotag's own internal close/rename functions directly (the
  -- exact functions its own `>`/InsertLeave keymaps call) against real
  -- tree-sitter-luax-parsed buffer content. This is run via `-l` (Neovim's
  -- headless Lua-script mode), where simulating raw insert-mode keystrokes
  -- through nvim_feedkeys is not reliably pumped through the normal
  -- typeahead/event loop the way it is in an interactive `-c` session --
  -- calling the plugin's own internal functions directly tests the same
  -- pattern-matching/tree-sitter logic without depending on that.
  local internal = require("nvim-ts-autotag.internal")

  vim.cmd("enew")
  vim.bo.filetype = "luax"
  vim.wait(300)
  luax.setup_autotag(vim.api.nvim_get_current_buf())

  -- Auto-close: buffer already has the `>` a keymap would have just
  -- inserted (mirrors internal.lua's own M.close_tag contract: it expects
  -- the triggering `>` to already be in the buffer, with the cursor
  -- positioned right after it).
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = <div>" })
  vim.api.nvim_win_set_cursor(0, { 1, string.len("local x = <div>") })
  internal.close_tag()
  local closed = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(closed == "local x = <div></div>", "Expected auto-closed tag, got: " .. closed)

  -- Rename: edit the opening tag's name in place, then call the same
  -- function nvim-ts-autotag's InsertLeave autocmd calls.
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = <span></div>" })
  vim.api.nvim_win_set_cursor(0, { 1, string.len("local x = <span") - 1 })
  internal.rename_tag()
  local renamed = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(renamed == "local x = <span></span>", "Expected renamed closing tag, got: " .. renamed)

  -- Lexical/dotted tag: same rename path must work symmetrically for
  -- `<d.button>`-style tags, not just bare ones.
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = <d.header></d.button>" })
  vim.api.nvim_win_set_cursor(0, { 1, string.len("local x = <d.head") - 1 })
  internal.rename_tag()
  local renamed_dotted = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(
    renamed_dotted == "local x = <d.header></d.header>",
    "Expected renamed dotted closing tag, got: " .. renamed_dotted
  )
end)

-- Test 6: Tag removal (luax.nvim's M.remove_tag_at_cursor) -- real
-- tree-sitter-based edits against real tree-sitter-luax parses, not
-- an LSP code action (no server exposes "remove tag" as one).
test("Tag Removal > deletes, unwraps, and refuses to unwrap a childless tag", function()
  local luax = dofile(luax_entry)

  local function with_buf(lines, fn)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("filetype", "luax", { buf = buf })
    vim.api.nvim_set_current_buf(buf)
    fn(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  local function text_of(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  with_buf({ 'return <div><meta charset="utf-8" /></div>' }, function(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 15 }) -- inside 'meta'
    local ok = luax.remove_tag_at_cursor({ keep_children = false })
    assert(ok, "expected remove_tag_at_cursor to succeed on a self-closing tag")
    assert(text_of(buf) == "return <div></div>", "got: " .. text_of(buf))
  end)

  with_buf({ "return <div><span>hi</span></div>" }, function(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 14 }) -- inside 'span'
    local ok = luax.remove_tag_at_cursor({ keep_children = false })
    assert(ok, "expected full removal to succeed")
    assert(text_of(buf) == "return <div></div>", "got: " .. text_of(buf))
  end)

  with_buf({ "return <div><span>hi</span></div>" }, function(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 14 }) -- inside 'span'
    local ok = luax.remove_tag_at_cursor({ keep_children = true })
    assert(ok, "expected unwrap to succeed")
    assert(text_of(buf) == "return <div>hi</div>", "got: " .. text_of(buf))
  end)

  with_buf({ 'return <div><meta charset="utf-8" /></div>' }, function(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 15 }) -- inside 'meta'
    local ok = luax.remove_tag_at_cursor({ keep_children = true })
    assert(ok == false, "expected unwrap on a self-closing tag to be refused")
    assert(
      text_of(buf) == 'return <div><meta charset="utf-8" /></div>',
      "expected buffer to be untouched, got: " .. text_of(buf)
    )
  end)

  with_buf({ "return <div>", "  <span>hi</span>", "</div>" }, function(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 9 }) -- inside the outer 'div'
    local ok = luax.remove_tag_at_cursor({ keep_children = true })
    assert(ok, "expected multi-line unwrap to succeed")
    assert(text_of(buf) == "return \n  <span>hi</span>\n", "got: " .. text_of(buf))
  end)
end)

-- Test 7: Explicit rename (luax.nvim's M.rename_tag_at_cursor) --
-- prompt-driven, updates opening and closing tag names atomically.
-- Complements (doesn't replace) nvim-ts-autotag's typing-based linked
-- editing already covered by Test 5.
test("Rename Tag > updates open+close atomically via a stubbed prompt", function()
  local luax = dofile(luax_entry)

  local orig_input = vim.ui.input

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "return <div><span>hi</span></div>" })
  vim.api.nvim_set_option_value("filetype", "luax", { buf = buf })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 14 }) -- inside 'span'
  vim.ui.input = function(_, callback) callback("em") end
  local ok = luax.rename_tag_at_cursor()
  vim.ui.input = orig_input
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(ok, "expected rename_tag_at_cursor to succeed")
  assert(text == "return <div><em>hi</em></div>", "got: " .. text)
  vim.api.nvim_buf_delete(buf, { force = true })

  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "return <br/>" })
  vim.api.nvim_set_option_value("filetype", "luax", { buf = buf2 })
  vim.api.nvim_set_current_buf(buf2)
  vim.api.nvim_win_set_cursor(0, { 1, 9 })
  vim.ui.input = function(_, callback) callback("hr") end
  local ok2 = luax.rename_tag_at_cursor()
  vim.ui.input = orig_input
  local text2 = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
  assert(ok2, "expected rename_tag_at_cursor to succeed on a self-closing tag")
  assert(text2 == "return <hr/>", "got: " .. text2)
  vim.api.nvim_buf_delete(buf2, { force = true })
end)

-- Test 8: Emmet expansion for luax buffers via the real, installed
-- emmet-ls (github.com/aca/emmet-ls) -- not a hand-rolled abbreviation
-- expander. emmet-ls treats any languageId it doesn't specifically
-- special-case (see its own source: only a handful of non-HTML markup
-- languages are listed) as HTML-syntax markup by default, so "luax"
-- needs no server-side config at all -- only attaching the client to
-- luax buffers, done here directly rather than through
-- nvim-lspconfig/LazyVim's plugin loading (out of scope for this
-- headless harness). Degrades gracefully if emmet-ls isn't installed,
-- same contract as the autotag test above.
test("Emmet > expands a real abbreviation for a luax buffer via emmet-ls", function()
  local candidates = {
    vim.fn.exepath("emmet-ls"),
    vim.fn.expand("~/.local/share/nvim/mason/bin/emmet-ls"),
  }
  local emmet_bin = nil
  for _, c in ipairs(candidates) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      emmet_bin = c
      break
    end
  end
  if not emmet_bin then
    print("    (emmet-ls not installed in this environment -- skipping the live expansion check)")
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local line = "return div.hero"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_set_option_value("filetype", "luax", { buf = buf })

  local client_id = vim.lsp.start({
    name = "emmet_ls",
    cmd = { emmet_bin, "--stdio" },
    root_dir = vim.fn.getcwd(),
  }, { bufnr = buf })
  assert(client_id, "expected emmet-ls client to start")

  local attached = vim.wait(5000, function()
    local c = vim.lsp.get_client_by_id(client_id)
    return c ~= nil and c.initialized == true
  end, 100)
  assert(attached, "expected emmet-ls client to finish initializing within 5s")

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = { line = 0, character = #line },
  }
  local results = vim.lsp.buf_request_sync(buf, "textDocument/completion", params, 3000)
  assert(results, "expected a completion response from emmet-ls")

  local found = nil
  for _, res in pairs(results) do
    if res.result then
      for _, item in ipairs(res.result) do
        if item.textEdit and item.textEdit.newText then
          found = item.textEdit.newText
          break
        end
      end
    end
  end
  assert(found, "expected at least one completion item with a textEdit")
  assert(
    found:find('<div class="hero">', 1, true) ~= nil,
    "expected a real HTML-shaped expansion of div.hero, got: " .. tostring(found)
  )

  vim.lsp.get_client_by_id(client_id):stop()
end)

print("\n" .. string.rep("=", 60))
if failed == 0 then
  print(string.format("SUMMARY: %d Total | %d Passed | 0 Failed\n", passed + failed, passed))
  vim.cmd("qall!")
else
  print(string.format("SUMMARY: %d Total | %d Passed | %d Failed\n", passed + failed, passed, failed))
  for _, e in ipairs(errors) do
    print("  FAILED: " .. e.name .. "\n    " .. e.err)
  end
  vim.cmd("cquit 1")
end
