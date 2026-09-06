--[[
  Hydronium Neovim Plugin
  Provides relocatable syntax, tree-sitter integration, LuaLS plugin configuration,
  formatting commands, and health checking with zero absolute paths.
--]]

local M = {}

local defaults = {
  treesitter = true,
  format_on_save = false,
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

--- Plugin setup function
--- @param opts table? User configuration table
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Register tree-sitter filetype mapping if treesitter is active
  if opts.treesitter and vim.treesitter then
    if vim.treesitter.language and vim.treesitter.language.register then
      pcall(vim.treesitter.language.register, "luax", "luax")
    end
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
end

return M
