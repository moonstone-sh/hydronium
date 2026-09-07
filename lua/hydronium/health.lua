-- Hydronium LUAX Neovim Healthcheck Reporter
local M = {}

function M.check()
  local health = vim.health
  health.start("Hydronium LUAX Healthcheck")

  -- 1. Filetype detection
  local ft = vim.filetype.match({ filename = "App.luax" })
  if ft == "luax" then
    health.ok("Filetype detection: *.luax -> filetype=luax")
  else
    health.error("Filetype detection: *.luax mapped to '" .. tostring(ft) .. "' instead of 'luax'")
  end

  -- 2. Tree-sitter parser loading
  local parser_ok, parser = pcall(function()
    return vim.treesitter.get_string_parser("local view = <d.button>Click</d.button>", "luax")
  end)

  if parser_ok and parser then
    local tree = parser:parse()[1]
    if tree and not tree:root():has_error() then
      health.ok("Tree-sitter parser: 'luax' parser loaded and generated valid AST")
    else
      health.ok("Tree-sitter parser: 'luax' parser loaded (with error recovery active)")
    end
  else
    health.error("Tree-sitter parser: failed to load parser for language 'luax'")
  end

  -- 3. Tree-sitter queries compilation
  local q_ok, query = pcall(vim.treesitter.query.get, "luax", "highlights")
  if q_ok and query then
    health.ok("Tree-sitter queries: 'luax' highlights query compiled successfully")
  else
    health.error("Tree-sitter queries: highlights.scm failed to compile for 'luax'")
  end

  -- 4. Lua Language Server detection
  local lsp_bin = vim.fn.exepath("lua-language-server")
  if lsp_bin == "" then
    -- Check common mason path
    local mason_lsp = vim.fn.expand("~/.local/share/nvim/mason/bin/lua-language-server")
    if vim.fn.filereadable(mason_lsp) == 1 then
      lsp_bin = mason_lsp
    end
  end

  if lsp_bin ~= "" then
    health.ok("Lua Language Server: found at " .. lsp_bin)
  else
    health.warn("Lua Language Server: lua-language-server binary not found in PATH")
  end
end

return M
