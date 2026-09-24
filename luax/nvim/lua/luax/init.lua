--[[
  LUAX Neovim Plugin
  Provides relocatable syntax, tree-sitter integration, LuaLS plugin configuration,
  formatting commands, and health checking with zero absolute paths.
--]]

local M = {}

local defaults = {
  treesitter = true,
  format_on_save = false,
  -- Tag-close/rename ("linked editing") via nvim-ts-autotag if the user has
  -- it installed. Set to false to skip registration entirely.
  autotag = true,
  lsp = {
    auto_configure_luals = true,
  },
}

--- Resolves the LUAX package root from this standalone Neovim plugin using
--- the location of this script, with zero absolute paths.
--- @return string root_dir
function M.get_root_dir()
  local info = debug.getinfo(1, "S")
  local src = (info and info.source and info.source:gsub("^@", "")) or ""
  -- Match nvim/lua/luax/init.lua -> LUAX package root. Keeping the editor
  -- plugin beneath the package makes parser, query, CLI, source, and type
  -- discovery independent of the former Hydronium workspace layout.
  local package_root = src:match("^(.-)/nvim/lua/luax/init%.lua$")
  if package_root and package_root ~= "" then
    return package_root
  end

  -- Fallback: check Neovim runtime file resolution
  local rtp_matches = vim.api.nvim_get_runtime_file("lua/luax/init.lua", true)
  if rtp_matches and #rtp_matches > 0 then
    for _, match in ipairs(rtp_matches) do
      local p = match:match("^(.-)/nvim/lua/luax/init%.lua$")
      if p then return p end
    end
  end

  -- Fallback: current working directory
  return vim.fn.getcwd()
end

--- Returns the relocatable path to the LuaLS virtual source plugin
--- @return string plugin_path
function M.get_luals_plugin_path()
  local root = M.get_root_dir()
  local candidate = root .. "/src/hydronium_luax/luals/init.lua"
  if vim.fn.filereadable(candidate) == 1 then
    return candidate
  end
  return root .. "/luals/init.lua"
end

--- Returns the types directory path for LuaLS library configuration
--- @return string types_path
function M.get_types_path()
  local root = M.get_root_dir()
  return root .. "/types"
end

--- Formats the current buffer or given buffer number
--- @param bufnr number?
function M.format(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local root = M.get_root_dir()
  local bin_path = root .. "/bin/luax"

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")

  -- If bin/luax is executable, run format via stdin/stdout
  if vim.fn.executable(bin_path) == 1 then
    local res = vim.fn.system({ bin_path, "format", "-" }, text)
    if vim.v.shell_error == 0 and res and #res > 0 then
      local formatted_lines = vim.split(res, "\n")
      if #formatted_lines > 0 and formatted_lines[#formatted_lines] == "" then
        table.remove(formatted_lines, #formatted_lines)
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, formatted_lines)
      return true
    end
  end

  -- Fallback: pure-Lua formatter via the LUAX package module.
  local ok, formatter = pcall(require, "hydronium_luax.formatter")
  if ok and formatter and formatter.format then
    local formatted, err = formatter.format(text)
    if formatted then
      local formatted_lines = vim.split(formatted, "\n")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, formatted_lines)
      return true
    end
  end

  return false
end

--- Registers `.luax` with nvim-ts-autotag (tag-close-on-`>` and
--- rename-tag-on-edit, i.e. "linked editing") if it's installed, using its
--- officially documented per-filetype extension API (its README's
--- "Extending the default config" section) rather than bespoke tag-editing
--- machinery. tree-sitter-luax's node names
--- (opening_element/closing_element/self_closing_element, each wrapping a
--- `tag_expression` name node -- verified via a real parse:
--- `(opening_element name: (tag_expression (dotted_identifier ...)))`) slot
--- directly into nvim-ts-autotag's generic, node-type-name-driven config, so
--- this works symmetrically for both `<button>` and `<d.button>` -- no-op,
--- safely, if nvim-ts-autotag isn't installed.
--- @param bufnr number? Buffer to attach immediately (defaults to current)
function M.setup_autotag(bufnr)
  -- No explicit plugin-manager load call needed: lazy.nvim (and most other
  -- managers) put every installed plugin's Lua modules on `require()`'s
  -- search path at startup regardless of whether its `config`/`opts` have
  -- run yet, so this `require` succeeds even before nvim-ts-autotag's own
  -- setup() has fired.
  local ok_cfg, TagConfigs = pcall(require, "nvim-ts-autotag.config.init")
  local ok_ft, FiletypeConfig = pcall(require, "nvim-ts-autotag.config.ft")
  if not (ok_cfg and ok_ft) then
    return false
  end

  if not TagConfigs:get("luax") then
    TagConfigs:add(FiletypeConfig.new("luax", {
      start_tag_pattern = { "opening_element" },
      start_name_tag_pattern = { "tag_expression" },
      end_tag_pattern = { "closing_element" },
      end_name_tag_pattern = { "tag_expression" },
      close_tag_pattern = { "closing_element" },
      close_name_tag_pattern = { "tag_expression" },
      element_tag = { "element_expression" },
      -- Void-ish HTML tags: don't auto-insert a closing tag for these (same
      -- defaults nvim-ts-autotag ships for html/jsx).
      skip_tag_pattern = {
        "area", "base", "br", "col", "command", "embed", "hr", "img",
        "slot", "input", "keygen", "link", "meta", "param", "source",
        "track", "wbr", "menuitem",
      },
    }))
  end

  -- Ensure nvim-ts-autotag's own setup() has run before we call attach()
  -- ourselves below. Its internal.attach() has a fallback path for the
  -- not-yet-set-up case that assumes `pcall(require, "nvim-treesitter.configs")`'s
  -- second return value is a boolean -- it's actually the required module
  -- (truthy) or an error *string* (also truthy), so on a modern
  -- nvim-treesitter without that legacy module, this fallback mis-detects
  -- "not set up" as "set up" and then errors calling a method on the error
  -- string, silently swallowed since our own attach() call is pcall'd.
  -- Calling setup() ourselves sidesteps that path entirely; it already
  -- no-ops safely if some other config in the user's setup already did this.
  local ok_setup, autotag = pcall(require, "nvim-ts-autotag")
  if ok_setup then
    pcall(autotag.setup, {})
  end

  -- Attach directly rather than relying on nvim-ts-autotag's own FileType
  -- autocmd having fired after this one -- attach() is idempotent, it no-ops
  -- if the buffer is already attached.
  local ok_internal, internal = pcall(require, "nvim-ts-autotag.internal")
  if ok_internal then
    pcall(internal.attach, bufnr)
  end
  return true
end

--- Finds the JSX element (element_expression, i.e. a tag with a
--- separate opening_element/closing_element pair, or a standalone
--- self_closing_element) enclosing the given tree-sitter node, walking
--- up the parent chain. Returns nil if none is found (cursor isn't
--- inside any tag).
--- @param node userdata? A TSNode to start walking up from
--- @return userdata? element
local function find_enclosing_element(node)
  while node do
    local t = node:type()
    if t == "element_expression" or t == "self_closing_element" then
      return node
    end
    node = node:parent()
  end
  return nil
end

--- Returns the element_expression/self_closing_element node enclosing
--- the cursor in the current window, or nil (with a user-facing
--- warning) if the buffer isn't luax, has no active parser, or the
--- cursor isn't inside any tag.
--- @return userdata? element
--- @return number? bufnr
local function element_at_cursor()
  if vim.bo.filetype ~= "luax" then
    vim.notify("luax.nvim: this only works in a luax buffer", vim.log.levels.WARN)
    return nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "luax")
  if not ok then
    vim.notify("luax.nvim: no tree-sitter parser for this buffer", vim.log.levels.ERROR)
    return nil
  end
  local tree = parser:parse()[1]
  local row0, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  row0 = row0 - 1
  local node = tree:root():named_descendant_for_range(row0, col0, row0, col0)
  local element = find_enclosing_element(node)
  if not element then
    vim.notify("luax.nvim: no JSX tag found at cursor", vim.log.levels.WARN)
    return nil
  end
  return element, bufnr
end

--- Removes the JSX tag at cursor. With `opts.keep_children = true`
--- ("unwrap"), the opening and closing tags are dropped but everything
--- between them is kept in place verbatim; otherwise the whole element
--- (tag and children) is deleted. A self_closing_element has no
--- children by construction (verified via tree-sitter-luax's grammar:
--- self_closing_element never has a `children` field, only
--- element_expression does), so `keep_children` on one is refused
--- rather than silently doing a full delete instead of what was asked.
--- @param opts { keep_children: boolean? }?
--- @return boolean ok
function M.remove_tag_at_cursor(opts)
  opts = opts or {}
  local element, bufnr = element_at_cursor()
  if not element then
    return false
  end

  local srow, scol, erow, ecol = element:range()

  if opts.keep_children then
    if element:type() == "self_closing_element" then
      vim.notify(
        "luax.nvim: self-closing tags have no children to keep -- use :LuaxRemoveTag to delete it",
        vim.log.levels.WARN
      )
      return false
    end
    local open_fields = element:field("open")
    local close_fields = element:field("close")
    local open_node = open_fields and open_fields[1]
    local close_node = close_fields and close_fields[1]
    if not (open_node and close_node) then
      vim.notify(
        "luax.nvim: element is missing an opening or closing tag (unterminated?), refusing to unwrap",
        vim.log.levels.WARN
      )
      return false
    end
    local _, _, open_erow, open_ecol = open_node:range()
    local close_srow, close_scol = close_node:range()
    local inner_lines = vim.api.nvim_buf_get_text(bufnr, open_erow, open_ecol, close_srow, close_scol, {})
    vim.api.nvim_buf_set_text(bufnr, srow, scol, erow, ecol, inner_lines)
  else
    vim.api.nvim_buf_set_text(bufnr, srow, scol, erow, ecol, {})
  end
  return true
end

--- Prompts for a new tag name and renames the JSX element at cursor,
--- updating its opening and closing tag names (or the single name of a
--- self_closing_element) atomically. Complements nvim-ts-autotag's
--- typing-based "linked editing" (edit one side, the other follows
--- live) with an explicit, prompt-driven rename that doesn't require
--- retyping the name character by character, and works even when
--- nvim-ts-autotag isn't installed.
--- @return boolean ok
function M.rename_tag_at_cursor()
  local element, bufnr = element_at_cursor()
  if not element then
    return false
  end

  local name_nodes = {}
  if element:type() == "self_closing_element" then
    local fields = element:field("name")
    if fields and fields[1] then table.insert(name_nodes, fields[1]) end
  else
    for _, field_name in ipairs({ "open", "close" }) do
      local fields = element:field(field_name)
      local tag_node = fields and fields[1]
      if tag_node then
        local name_fields = tag_node:field("name")
        if name_fields and name_fields[1] then
          table.insert(name_nodes, name_fields[1])
        end
      end
    end
  end

  if #name_nodes == 0 then
    vim.notify("luax.nvim: could not find a tag name to rename", vim.log.levels.WARN)
    return false
  end

  local current_name = vim.treesitter.get_node_text(name_nodes[1], bufnr)

  vim.ui.input({ prompt = "Rename <" .. current_name .. "> to: ", default = current_name }, function(new_name)
    if not new_name or new_name == "" or new_name == current_name then
      return
    end
    -- Apply the later (by buffer position) edit first so replacing the
    -- opening tag's name -- which always comes before the closing
    -- tag's in the buffer -- can't shift the closing tag's
    -- already-captured range out from under it.
    table.sort(name_nodes, function(a, b)
      local ar, br = { a:range() }, { b:range() }
      if ar[1] ~= br[1] then return ar[1] > br[1] end
      return ar[2] > br[2]
    end)
    for _, n in ipairs(name_nodes) do
      local sr, sc, er, ec = n:range()
      vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, { new_name })
    end
  end)
  return true
end

--- The last visual selection as 0-indexed, end-EXCLUSIVE coordinates.
--- Reads the `'<`/`'>` marks rather than taking a command `-range`, because a
--- range only carries lines and these commands need columns for a charwise
--- selection. Linewise (`V`) is widened to the full first/last line, and a
--- charwise end column is clamped -- `getpos("'>")` returns `v:maxcol` for a
--- linewise selection, which is not a real column.
--- Returns nil when there is no usable selection: an unset mark reports line
--- 0, which would otherwise arithmetic down to row -1 and be mistaken for a
--- real (inverted) range in a buffer that has never been visually selected.
--- @return integer? srow, integer? scol, integer? erow, integer? ecol
local function selection_range()
  local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  if s[2] == 0 or e[2] == 0 then
    return nil
  end
  local srow, scol = s[2] - 1, s[3] - 1
  local erow, ecol = e[2] - 1, e[3]
  local last = vim.api.nvim_buf_get_lines(0, erow, erow + 1, false)[1] or ""
  if vim.fn.visualmode() == "V" then
    scol, ecol = 0, #last
  elseif ecol > #last then
    ecol = #last
  end
  return srow, scol, erow, ecol
end

--- The smallest element/fragment node that fully spans a range.
---
--- This is why these commands do not need to "fix up" a sloppy selection so
--- tag pairs balance: `named_descendant_for_range` returns the smallest node
--- covering the range, and walking up to the nearest element snaps OUTWARD to
--- a node that is structurally whole by construction. Half-selecting a tag
--- pair therefore yields the enclosing element, never a broken fragment of one.
--- @param bufnr integer
--- @return userdata? element
local function element_spanning(bufnr, srow, scol, erow, ecol)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "luax")
  if not ok then
    vim.notify("luax.nvim: no tree-sitter parser for this buffer", vim.log.levels.ERROR)
    return nil
  end
  local tree = parser:parse()[1]
  local node = tree:root():named_descendant_for_range(srow, scol, erow, ecol)
  while node do
    local t = node:type()
    if t == "element_expression" or t == "self_closing_element" or t == "fragment" then
      return node
    end
    node = node:parent()
  end
  return nil
end

--- The `tag_expression` nodes naming an element -- one for a
--- self_closing_element, two (open and close) for an element_expression.
--- Shared by rename and syntax-toggle so they cannot disagree about where a
--- tag name lives. Note the grammar wraps every name in a `tag_expression`
--- whose single child is an `identifier`, `dotted_identifier` or
--- `hyphenated_identifier`.
--- @param element userdata
--- @return userdata[] tag_expressions
local function tag_expression_nodes(element)
  local out = {}
  if element:type() == "self_closing_element" then
    local f = element:field("name")
    if f and f[1] then out[#out + 1] = f[1] end
    return out
  end
  for _, side in ipairs({ "open", "close" }) do
    local fields = element:field(side)
    local tag = fields and fields[1]
    if tag then
      local nf = tag:field("name")
      if nf and nf[1] then out[#out + 1] = nf[1] end
    end
  end
  return out
end

--- Applies text edits to a buffer strictly last-to-first in buffer order, so
--- an earlier edit can never shift a later edit's already-captured range.
--- @param bufnr integer
--- @param edits { srow: integer, scol: integer, erow: integer, ecol: integer, lines: string[] }[]
local function apply_edits_reverse(bufnr, edits)
  table.sort(edits, function(a, b)
    if a.srow ~= b.srow then return a.srow > b.srow end
    return a.scol > b.scol
  end)
  for _, ed in ipairs(edits) do
    vim.api.nvim_buf_set_text(bufnr, ed.srow, ed.scol, ed.erow, ed.ecol, ed.lines)
  end
end

--- Wraps the visual selection in a new tag -- the exact inverse of
--- :LuaxUnwrapTag, which drops a tag and keeps its children.
---
--- Operates on the raw selection rather than snapping to an element, because
--- wrapping several sibling elements (or a run of text) in one parent is the
--- normal reason to reach for this, and snapping outward would wrap their
--- parent instead, which is never what was asked.
--- @return boolean ok
function M.wrap_selection_in_tag()
  if vim.bo.filetype ~= "luax" then
    vim.notify("luax.nvim: this only works in a luax buffer", vim.log.levels.WARN)
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local srow, scol, erow, ecol = selection_range()
  if not srow or srow > erow or (srow == erow and scol >= ecol) then
    vim.notify("luax.nvim: nothing selected -- select the markup to wrap first", vim.log.levels.WARN)
    return false
  end

  vim.ui.input({ prompt = "Wrap selection in <", default = "div" }, function(name)
    if not name or name == "" then return end
    local inner = vim.api.nvim_buf_get_text(bufnr, srow, scol, erow, ecol, {})
    -- nvim_buf_set_text places the FIRST replacement line at the selection's
    -- own column and every continuation line at column 0 -- it does not
    -- re-indent. So the opening tag needs no prefix (it inherits scol) while
    -- every line after it must carry the base indent explicitly, plus one
    -- level for the now-nested children.
    local base = string.rep(" ", scol)
    local shift = string.rep(" ", vim.fn.shiftwidth())
    local out = { "<" .. name .. ">" }
    for _, line in ipairs(inner) do
      out[#out + 1] = (line == "" and "" or base .. shift .. line)
    end
    out[#out + 1] = base .. "</" .. name .. ">"
    vim.api.nvim_buf_set_text(bufnr, srow, scol, erow, ecol, out)
  end)
  return true
end

--- The local bound to hydronium_dom's `d` table in this buffer, if any.
---
--- Recognises both shapes that appear in real code:
---   local d = require("hydronium_dom").d
---   local dom = require("hydronium_dom") ; local d = dom.d
--- Returns nil when neither is present, which matters because toggling a tag
--- TO lexical form without such a binding produces code that does not compile.
--- @param bufnr integer
--- @return string? alias
local function detect_dom_alias(bufnr)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local direct = line:match('^%s*local%s+([%w_]+)%s*=%s*require%s*%(?%s*["\']hydronium_dom["\']%s*%)?%s*%.d%s*$')
    if direct then return direct end
    local via = line:match('^%s*local%s+([%w_]+)%s*=%s*[%w_]+%s*%.d%s*$')
    if via then return via end
  end
  return nil
end

--- Toggles the tag at the cursor between bare (`<button>`) and lexical
--- (`<d.button>`) form, updating the opening and closing tags together.
---
--- This is the one refactor specific to this project: hydronium supports both
--- syntaxes, the lexical one is the documented canonical form, and every
--- example still uses bare tags. Doing it by hand is why that migration has
--- not happened.
---
--- Refuses on a capitalised name. Only INTRINSICS live on the `d` table --
--- `<JsCounter>` is a component resolved as an ordinary Lua local, and
--- `<d.JsCounter>` would be a nil index at runtime.
--- @return boolean ok
function M.toggle_tag_syntax_at_cursor()
  local element, bufnr = element_at_cursor()
  if not element then return false end

  local tags = tag_expression_nodes(element)
  if #tags == 0 then
    vim.notify("luax.nvim: could not find a tag name to toggle", vim.log.levels.WARN)
    return false
  end

  local current = vim.treesitter.get_node_text(tags[1], bufnr)
  local kind = tags[1]:named_child(0) and tags[1]:named_child(0):type() or "identifier"

  local replacement
  if kind == "dotted_identifier" then
    local bare = current:match("%.([%w_]+)$")
    if not bare then
      vim.notify("luax.nvim: could not parse '" .. current .. "' as <alias.tag>", vim.log.levels.WARN)
      return false
    end
    replacement = bare
  elseif kind == "hyphenated_identifier" then
    vim.notify(
      "luax.nvim: '" .. current .. "' is a hyphenated tag; it has no lexical form (d.foo-bar is not valid Lua)",
      vim.log.levels.WARN
    )
    return false
  else
    if current:match("^%u") then
      vim.notify(
        "luax.nvim: <" .. current .. "> is a component, not an intrinsic -- only intrinsics live on the `d` table",
        vim.log.levels.WARN
      )
      return false
    end
    local alias = detect_dom_alias(bufnr)
    if not alias then
      alias = "d"
      vim.notify(
        'luax.nvim: no `d` binding found in this buffer -- add `local d = require("hydronium_dom").d`',
        vim.log.levels.WARN
      )
    end
    replacement = alias .. "." .. current
  end

  local edits = {}
  for _, tag in ipairs(tags) do
    local sr, sc, er, ec = tag:range()
    edits[#edits + 1] = { srow = sr, scol = sc, erow = er, ecol = ec, lines = { replacement } }
  end
  apply_edits_reverse(bufnr, edits)
  return true
end

--- Every `identifier` node under `root` that is a genuine variable REFERENCE.
---
--- Excluded, because none of them name a variable in scope: tag names (any
--- descendant of a `tag_expression`), attribute names, the `property` half of
--- a `dotted_identifier` or `field_expression` (`props.foo` references `props`,
--- not `foo`), and table-constructor keys.
---
--- STATED LIMITATION: this is a syntactic filter, not a resolver. It does not
--- track shadowing introduced inside `root` itself -- a `for i` loop variable
--- used in the body is reported as a reference. Callers intersect the result
--- with locals declared OUTSIDE `root`, which discards those in practice,
--- but a name that is both an outer local and an inner loop variable would
--- still be treated as a reference.
--- @param root userdata
--- @param bufnr integer
--- @return table<string, userdata[]> by_name
local function collect_free_identifiers(root, bufnr)
  local by_name = {}

  --- @param node userdata
  --- @return boolean
  local function excluded(node)
    local parent = node:parent()
    if not parent then return true end
    local pt = parent:type()

    if pt == "dotted_identifier" or pt == "field_expression" then
      local prop = parent:field("property")
      if prop and prop[1] and prop[1]:equal(node) then return true end
    end
    if pt == "attribute" then
      local name = parent:field("name")
      if name and name[1] and name[1]:equal(node) then return true end
    end
    if pt == "field" then
      -- `{ key = value }` -- the key is not a reference.
      local name = parent:field("name")
      if name and name[1] and name[1]:equal(node) then return true end
    end

    -- Any tag name, at any nesting depth inside the wrapper node.
    local n = parent
    while n and not n:equal(root) do
      if n:type() == "tag_expression" then return true end
      n = n:parent()
    end
    return false
  end

  local function walk(node)
    if node:type() == "identifier" and not excluded(node) then
      local name = vim.treesitter.get_node_text(node, bufnr)
      by_name[name] = by_name[name] or {}
      table.insert(by_name[name], node)
    end
    for child in node:iter_children() do
      if child:named() then walk(child) end
    end
  end
  walk(root)
  return by_name
end

--- Names of locals and parameters visible at `node`, from enclosing scopes.
--- Only declarations that START BEFORE `node` count, so a local declared
--- further down the same function is not mistaken for one in scope.
--- @param node userdata
--- @param bufnr integer
--- @return table<string, true> names
local function visible_locals(node, bufnr)
  local names = {}
  local target_row, target_col = node:range()

  local function add_identifier_list(list)
    if not list then return end
    for child in list:iter_children() do
      if child:type() == "identifier" then
        names[vim.treesitter.get_node_text(child, bufnr)] = true
      end
    end
  end

  local scope = node:parent()
  while scope do
    local st = scope:type()
    if st == "function_definition" or st == "function_declaration" or st == "local_function_declaration" then
      local params = scope:field("parameters")
      if params and params[1] then
        for child in params[1]:iter_children() do
          if child:type() == "identifier_list" then add_identifier_list(child) end
          if child:type() == "identifier" then
            names[vim.treesitter.get_node_text(child, bufnr)] = true
          end
        end
      end
    end
    -- Sibling declarations earlier in this same block.
    --
    -- Every statement in a function body is wrapped in a `statement` node by
    -- the grammar (`repeat($.statement)`), so `local title = ...` is NOT a
    -- direct child of the enclosing local_function_declaration -- it is a
    -- local_variable_declaration inside a statement. Missing that unwrap is
    -- why an earlier version of this found zero props for markup that plainly
    -- referenced an outer local.
    for child in scope:iter_children() do
      if child:named() then
        local decl = (child:type() == "statement") and child:named_child(0) or child
        if decl then
          local crow, ccol = decl:range()
          local before = crow < target_row or (crow == target_row and ccol < target_col)
          if before then
            if decl:type() == "local_variable_declaration" then
              for g in decl:iter_children() do
                if g:type() == "identifier_list" then add_identifier_list(g) end
              end
            elseif decl:type() == "local_function_declaration" then
              local nf = decl:field("name")
              if nf and nf[1] then
                names[vim.treesitter.get_node_text(nf[1], bufnr)] = true
              end
            end
          end
        end
      end
    end
    scope = scope:parent()
  end
  return names
end

--- The innermost function declaration containing `node`, used as the insertion
--- point for an extracted component (which must land beside its sibling
--- components, not nested inside the one it came from).
--- @param node userdata
--- @return userdata? fn
local function enclosing_function(node)
  local n = node:parent()
  local last = nil
  while n do
    local t = n:type()
    if t == "local_function_declaration" or t == "function_declaration" then
      last = n
    end
    n = n:parent()
  end
  return last
end

--- Extracts the selected (or cursor-enclosing) markup into a new component
--- defined above the enclosing function, threading every outer local it
--- references through as a prop, and replaces the original with a call site.
---
--- Emits a `---@class <Name>Props` block with one `@field` per prop, which is
--- what makes `props.` complete in LuaLS rather than being an untyped table --
--- the annotation, not the `local function` line, is the part that pays off.
--- @param opts { use_selection: boolean? }? `use_selection` comes from the
--- command being invoked with a range (i.e. from visual mode). It is NOT
--- inferred from whether `'<`/`'>` happen to be set: those marks survive after
--- visual mode is left, so a normal-mode invocation would otherwise silently
--- extract a selection made minutes ago instead of the tag under the cursor.
--- @return boolean ok
function M.extract_component(opts)
  opts = opts or {}
  if vim.bo.filetype ~= "luax" then
    vim.notify("luax.nvim: this only works in a luax buffer", vim.log.levels.WARN)
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()

  -- The selection when invoked on a range, otherwise the tag at the cursor.
  local element
  local srow, scol, erow, ecol
  if opts.use_selection then
    srow, scol, erow, ecol = selection_range()
  end
  if srow and (srow < erow or (srow == erow and scol < ecol)) then
    element = element_spanning(bufnr, srow, scol, erow, ecol)
  else
    element = element_at_cursor()
  end
  if not element then
    vim.notify("luax.nvim: no JSX element found to extract", vim.log.levels.WARN)
    return false
  end

  local esrow, escol, eerow, eecol = element:range()
  local outer = visible_locals(element, bufnr)
  local refs = collect_free_identifiers(element, bufnr)

  -- Props are exactly the outer locals the markup actually uses. Sorted so the
  -- generated signature and call site are stable across runs.
  local props, prop_nodes = {}, {}
  for name, nodes in pairs(refs) do
    if outer[name] then
      props[#props + 1] = name
      prop_nodes[name] = nodes
    end
  end
  table.sort(props)

  vim.ui.input({ prompt = "Extract component as: ", default = "Extracted" }, function(name)
    if not name or name == "" then return end
    if not name:match("^%u") then
      vim.notify(
        "luax.nvim: '" .. name .. "' must be capitalised -- a lowercase tag is treated as an intrinsic",
        vim.log.levels.WARN
      )
      return
    end

    -- Rewrite each referenced outer local to `props.<name>` inside the
    -- extracted copy. Done on region-relative coordinates against the text we
    -- lifted, so the buffer is untouched until the single replacement below.
    local region = vim.api.nvim_buf_get_text(bufnr, esrow, escol, eerow, eecol, {})
    local rewrites = {}
    for _, pname in ipairs(props) do
      for _, n in ipairs(prop_nodes[pname]) do
        local nsrow, nscol, _, necol = n:range()
        rewrites[#rewrites + 1] = { row = nsrow - esrow, scol = nscol, ecol = necol, name = pname }
      end
    end
    -- Last-to-first, so an earlier rewrite cannot shift a later one's columns.
    table.sort(rewrites, function(a, b)
      if a.row ~= b.row then return a.row > b.row end
      return a.scol > b.scol
    end)
    for _, rw in ipairs(rewrites) do
      local line = region[rw.row + 1]
      if line then
        -- Column 0 of the first region line sits at `escol` in the buffer.
        local off = (rw.row == 0) and escol or 0
        local s, e = rw.scol - off, rw.ecol - off
        region[rw.row + 1] = line:sub(1, s) .. "props." .. rw.name .. line:sub(e + 1)
      end
    end

    local fn = enclosing_function(element)
    local insert_row = fn and select(1, fn:range()) or esrow
    local indent = string.rep(" ", fn and select(2, fn:range()) or escol)
    local step = string.rep(" ", vim.fn.shiftwidth())

    local def = {}
    def[#def + 1] = indent .. "---@class " .. name .. "Props"
    for _, pname in ipairs(props) do
      def[#def + 1] = indent .. "---@field " .. pname .. " any"
    end
    -- @class alone declares a shape; it does not bind `props` to it. The
    -- @param is what actually makes `props.` complete in LuaLS, which is the
    -- entire reason to emit annotations rather than a bare function.
    def[#def + 1] = indent .. "---@param props " .. name .. "Props"
    def[#def + 1] = indent .. "local function " .. name .. "(props)"
    def[#def + 1] = indent .. step .. "return ("
    for i, line in ipairs(region) do
      -- The first region line arrives without its original leading indent,
      -- since the lift started at the element's own column.
      local body = (i == 1) and line or line:gsub("^" .. indent, "")
      def[#def + 1] = (body == "" and "" or indent .. step .. step .. body)
    end
    def[#def + 1] = indent .. step .. ")"
    def[#def + 1] = indent .. "end"
    def[#def + 1] = ""

    -- Call site, with each prop forwarded by name.
    local attrs = {}
    for _, pname in ipairs(props) do
      attrs[#attrs + 1] = pname .. "={" .. pname .. "}"
    end
    local call = "<" .. name .. (#attrs > 0 and (" " .. table.concat(attrs, " ")) or "") .. " />"

    -- Replace first, then insert above: the replacement uses coordinates
    -- captured before any edit, and inserting earlier lines afterwards cannot
    -- invalidate an edit that has already been applied.
    vim.api.nvim_buf_set_text(bufnr, esrow, escol, eerow, eecol, { call })
    vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, def)

    vim.notify(
      "luax.nvim: extracted <" .. name .. "> with "
        .. #props .. " prop" .. (#props == 1 and "" or "s")
        .. (#props > 0 and (": " .. table.concat(props, ", ")) or ""),
      vim.log.levels.INFO
    )
  end)
  return true
end

--- Plugin setup function
--- @param opts table? User configuration table
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Modern filetype registration (does not require a scanned ftdetect/ file to
  -- have run first, and works even when a plugin manager only puts this
  -- nvim/ directory -- not the LUAX package root -- on rtp).
  vim.filetype.add({ extension = { luax = "luax" } })

  -- The compiled tree-sitter parser (parser/luax.so) and queries
  -- (queries/luax/*.scm) live at the LUAX package root, not inside this
  -- nvim/ plugin directory. A plugin manager spec that points at luax/nvim
  -- can still discover them because the package root is resolved from this
  -- module's own path; it would otherwise never find
  -- them, so make the project root discoverable on rtp too.
  local root = M.get_root_dir()
  local root_on_rtp = false
  for _, entry in ipairs(vim.api.nvim_list_runtime_paths()) do
    if entry == root then
      root_on_rtp = true
      break
    end
  end
  if root and root ~= "" and not root_on_rtp then
    if vim.fn.isdirectory(root .. "/parser") == 1 or vim.fn.isdirectory(root .. "/queries") == 1 then
      vim.opt.rtp:append(root)
    end
  end

  -- Register tree-sitter filetype mapping if treesitter is active
  if opts.treesitter and vim.treesitter then
    if vim.treesitter.language and vim.treesitter.language.register then
      pcall(vim.treesitter.language.register, "luax", "luax")
    end
  end

  if opts.autotag then
    -- Register the tag config once now (cheap, no buffer/treesitter side
    -- effects), then attach it to every .luax buffer as it's opened --
    -- setup() itself typically runs once at startup, before any .luax
    -- buffer exists yet.
    M.setup_autotag()
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "luax",
      group = vim.api.nvim_create_augroup("luax_nvim_autotag", { clear = true }),
      callback = function(args)
        M.setup_autotag(args.buf)
      end,
    })
  end

  -- Register user command :LuaxFormat
  vim.api.nvim_create_user_command("LuaxFormat", function()
    M.format()
  end, { desc = "Format current LUAX buffer" })

  -- Format on save autocmd if configured
  if opts.format_on_save then
    local group = vim.api.nvim_create_augroup("LuaxFormatOnSave", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      pattern = "*.luax",
      callback = function(args)
        M.format(args.buf)
      end,
    })
  end

  -- :LuaxVirtualSource -- shows exactly what LuaLS sees for the current
  -- buffer (via the same hydronium.luax.plugin.virtual_lower the live
  -- OnSetText hook calls). Invaluable when hover/completion/rename behave
  -- unexpectedly: it's usually because the virtual projection isn't what
  -- you'd expect, not because LuaLS itself is wrong.
  vim.api.nvim_create_user_command("LuaxVirtualSource", function()
    local root = M.get_root_dir()
    package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path
    local ok, plugin_mod = pcall(require, "hydronium_luax.plugin")
    if not ok then
      vim.notify("luax.nvim: could not load hydronium_luax.plugin (" .. tostring(plugin_mod) .. ")", vim.log.levels.ERROR)
      return
    end
    local bufnr = vim.api.nvim_get_current_buf()
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local uri = vim.api.nvim_buf_get_name(bufnr)
    local virt_ok, virt = pcall(plugin_mod.virtual_lower, text, uri)
    if not virt_ok then
      vim.notify("luax.nvim: virtual_lower failed: " .. tostring(virt), vim.log.levels.ERROR)
      return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(virt, "\n"))
    vim.bo[buf].filetype = "lua"
    vim.bo[buf].buftype = "nofile"
    vim.api.nvim_buf_set_name(buf, "LuaxVirtualSource://" .. vim.fn.fnamemodify(uri, ":t"))
    vim.cmd.split()
    vim.api.nvim_win_set_buf(0, buf)
  end, { desc = "Show the virtual Lua source LuaLS sees for this .luax buffer" })

  -- :LuaxTree -- thin, discoverable wrapper around Neovim's built-in
  -- :InspectTree for the luax parser specifically (useful when a user
  -- doesn't know :InspectTree exists, or wants a one-word command scoped to
  -- this filetype).
  vim.api.nvim_create_user_command("LuaxTree", function()
    if vim.bo.filetype ~= "luax" then
    vim.notify("luax.nvim: :LuaxTree only works in a luax buffer", vim.log.levels.WARN)
      return
    end
    vim.cmd.InspectTree()
  end, { desc = "Inspect the Tree-sitter syntax tree for this .luax buffer" })

  -- :LuaxInfo -- one-shot status dump: everything :checkhealth luax
  -- checks, plus what's actually attached/active for THIS buffer right now.
  vim.api.nvim_create_user_command("LuaxInfo", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = {}
    local function add(s) table.insert(lines, s) end

    add("LUAX buffer info")
    add(("  file:     %s"):format(vim.api.nvim_buf_get_name(bufnr)))
    add(("  filetype: %s"):format(vim.bo[bufnr].filetype))
    add(("  root_dir: %s"):format(M.get_root_dir()))

    local ts_ok = pcall(vim.treesitter.get_parser, bufnr, "luax")
    add(("  tree-sitter parser active: %s"):format(tostring(ts_ok)))

    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    if #clients == 0 then
      add("  LSP clients attached: (none)")
    else
      add("  LSP clients attached:")
      for _, c in ipairs(clients) do
        add(("    - %s (root: %s)"):format(c.name, c.config and c.config.root_dir or "?"))
      end
    end

    local luals_plugin_path = M.get_luals_plugin_path()
    add(("  LuaLS plugin file: %s (%s)"):format(
      luals_plugin_path,
      vim.fn.filereadable(luals_plugin_path) == 1 and "found" or "MISSING"
    ))

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "LUAX" })
  end, { desc = "Show LUAX filetype/tree-sitter/LSP status for the current buffer" })

  -- :LuaxRemoveTag / :LuaxUnwrapTag -- tree-sitter-based tag removal.
  -- Not an LSP code action (neither lua_ls nor any JSX/HTML server
  -- exposes "remove tag" as one); these operate directly on the real
  -- tree-sitter-luax parse of the buffer. No default keymap is bound --
  -- map these yourself, e.g. `vim.keymap.set("n", "dst", "<cmd>LuaxUnwrapTag<cr>")`.
  vim.api.nvim_create_user_command("LuaxRemoveTag", function()
    M.remove_tag_at_cursor({ keep_children = false })
  end, { desc = "Remove the JSX tag at cursor, including its children" })

  vim.api.nvim_create_user_command("LuaxUnwrapTag", function()
    M.remove_tag_at_cursor({ keep_children = true })
  end, { desc = "Remove the JSX tag at cursor, keeping its children in place" })

  -- :LuaxRenameTag -- prompt-based rename updating both the opening and
  -- closing tag name atomically. Complements nvim-ts-autotag's
  -- typing-based linked editing (setup_autotag above); works even
  -- without it installed.
  vim.api.nvim_create_user_command("LuaxRenameTag", function()
    M.rename_tag_at_cursor()
  end, { desc = "Rename the JSX tag at cursor (prompts for the new name)" })

  -- :LuaxWrapTag -- the inverse of :LuaxUnwrapTag. `range = true` so it can
  -- be invoked straight from a visual selection (`:'<,'>LuaxWrapTag`, which
  -- is what pressing `:` in visual mode gives you); the range itself is
  -- unused, since the selection's COLUMNS are read from the '<,'> marks.
  vim.api.nvim_create_user_command("LuaxWrapTag", function()
    M.wrap_selection_in_tag()
  end, { desc = "Wrap the visual selection in a new JSX tag", range = true })

  -- :LuaxToggleTagSyntax -- bare <button> <-> lexical <d.button>.
  -- The one refactor unique to hydronium: both syntaxes are supported, the
  -- lexical form is documented as canonical, and every example still uses
  -- bare tags. See docs/LUAX_DX_CURRENT_STATE.md.
  vim.api.nvim_create_user_command("LuaxToggleTagSyntax", function()
    M.toggle_tag_syntax_at_cursor()
  end, { desc = "Toggle the tag at cursor between bare and lexical (d.tag) form" })

  -- :LuaxExtractComponent -- extract selection (or the tag at cursor) into a
  -- new typed component above the enclosing function, threading referenced
  -- outer locals through as props.
  vim.api.nvim_create_user_command("LuaxExtractComponent", function(cmd)
    M.extract_component({ use_selection = (cmd.range or 0) > 0 })
  end, { desc = "Extract the selected JSX into a new component with typed props", range = true })
end

return M
