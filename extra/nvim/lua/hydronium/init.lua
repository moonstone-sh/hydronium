--[[
  Hydronium Neovim Plugin
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

--- Resolves the root directory of the hydronium repository or plugin
--- dynamically using the location of this script, with zero absolute paths.
--- @return string root_dir
function M.get_root_dir()
  local info = debug.getinfo(1, "S")
  local src = (info and info.source and info.source:gsub("^@", "")) or ""
  -- Match extra/nvim/lua/hydronium/init.lua -> project root
  local project_root = src:match("^(.-)/extra/nvim/lua/hydronium/init%.lua$")
  if project_root and project_root ~= "" then
    return project_root
  end

  -- Fallback: check Neovim runtime file resolution
  local rtp_matches = vim.api.nvim_get_runtime_file("lua/hydronium/init.lua", true)
  if rtp_matches and #rtp_matches > 0 then
    for _, match in ipairs(rtp_matches) do
      local p = match:match("^(.-)/extra/nvim/lua/hydronium/init%.lua$")
      if p then return p end
      local p2 = match:match("^(.-)/lua/hydronium/init%.lua$")
      if p2 then return p2 end
    end
  end

  -- Fallback: current working directory
  return vim.fn.getcwd()
end

--- Returns the relocatable path to the LuaLS virtual source plugin
--- @return string plugin_path
function M.get_luals_plugin_path()
  local root = M.get_root_dir()
  local candidate = root .. "/src/hydronium/luax/plugin.lua"
  if vim.fn.filereadable(candidate) == 1 then
    return candidate
  end
  return root .. "/plugin.lua"
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

  -- Fallback: pure-Lua formatter via hydronium.luax.formatter
  local ok, formatter = pcall(require, "hydronium.luax.formatter")
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
    vim.notify("hydronium.nvim: this only works in a luax buffer", vim.log.levels.WARN)
    return nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "luax")
  if not ok then
    vim.notify("hydronium.nvim: no tree-sitter parser for this buffer", vim.log.levels.ERROR)
    return nil
  end
  local tree = parser:parse()[1]
  local row0, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  row0 = row0 - 1
  local node = tree:root():named_descendant_for_range(row0, col0, row0, col0)
  local element = find_enclosing_element(node)
  if not element then
    vim.notify("hydronium.nvim: no JSX tag found at cursor", vim.log.levels.WARN)
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
        "hydronium.nvim: self-closing tags have no children to keep -- use :LuaxRemoveTag to delete it",
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
        "hydronium.nvim: element is missing an opening or closing tag (unterminated?), refusing to unwrap",
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
    vim.notify("hydronium.nvim: could not find a tag name to rename", vim.log.levels.WARN)
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

--- Plugin setup function
--- @param opts table? User configuration table
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Modern filetype registration (does not require a scanned ftdetect/ file to
  -- have run first, and works even when a plugin manager only puts this
  -- extra/nvim/ directory -- not the hydronium project root -- on rtp).
  vim.filetype.add({ extension = { luax = "luax" } })

  -- The compiled tree-sitter parser (parser/luax.so) and queries
  -- (queries/luax/*.scm) live at the hydronium project root, not inside this
  -- extra/nvim/ plugin directory. A plugin manager spec that only points at
  -- extra/nvim (as documented for hydronium.nvim) would otherwise never find
  -- them, so make the project root discoverable on rtp too.
  local root = M.get_root_dir()
  local already_on_rtp = vim.api.nvim_get_runtime_file("parser/luax.so", false)
  if root and root ~= "" and #already_on_rtp == 0 then
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
      group = vim.api.nvim_create_augroup("hydronium_luax_autotag", { clear = true }),
      callback = function(args)
        M.setup_autotag(args.buf)
      end,
    })
  end

  -- Register user command :HydroniumFormat
  vim.api.nvim_create_user_command("HydroniumFormat", function()
    M.format()
  end, { desc = "Format current LUAX buffer" })

  -- Format on save autocmd if configured
  if opts.format_on_save then
    local group = vim.api.nvim_create_augroup("HydroniumFormatOnSave", { clear = true })
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
    local ok, plugin_mod = pcall(require, "hydronium.luax.plugin")
    if not ok then
      vim.notify("hydronium.nvim: could not load hydronium.luax.plugin (" .. tostring(plugin_mod) .. ")", vim.log.levels.ERROR)
      return
    end
    local bufnr = vim.api.nvim_get_current_buf()
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local uri = vim.api.nvim_buf_get_name(bufnr)
    local virt_ok, virt = pcall(plugin_mod.virtual_lower, text, uri)
    if not virt_ok then
      vim.notify("hydronium.nvim: virtual_lower failed: " .. tostring(virt), vim.log.levels.ERROR)
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
      vim.notify("hydronium.nvim: :LuaxTree only works in a luax buffer", vim.log.levels.WARN)
      return
    end
    vim.cmd.InspectTree()
  end, { desc = "Inspect the Tree-sitter syntax tree for this .luax buffer" })

  -- :LuaxInfo -- one-shot status dump: everything :checkhealth hydronium
  -- checks, plus what's actually attached/active for THIS buffer right now.
  vim.api.nvim_create_user_command("LuaxInfo", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = {}
    local function add(s) table.insert(lines, s) end

    add("Hydronium LUAX buffer info")
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

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Hydronium LUAX" })
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
end

return M
