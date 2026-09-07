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
end

return M
