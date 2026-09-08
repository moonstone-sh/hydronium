--[[
  LUAX Health Check Module (:checkhealth luax)
  Verifies runtime, tree-sitter parser/queries, LuaLS configuration, and CLI tools.
--]]

local M = {}

local health = vim.health or {}
local report_start = health.start or health.report_start or function(msg) print("=== " .. msg .. " ===") end
local report_ok = health.ok or health.report_ok or function(msg) print("[OK] " .. msg) end
local report_warn = health.warn or health.report_warn or function(msg) print("[WARN] " .. msg) end
local report_error = health.error or health.report_error or function(msg) print("[ERROR] " .. msg) end
local report_info = health.info or health.report_info or function(msg) print("[INFO] " .. msg) end

function M.check()
  report_start("LUAX Environment & Tooling")

  -- 1. Check Lua / LuaJIT runtime
  if jit then
    report_ok("LuaJIT detected: " .. tostring(jit.version))
  else
    report_ok("Standard Lua runtime detected: " .. tostring(_VERSION))
  end

  -- 2. Check the canonical LUAX Neovim plugin module. It is independent of
  -- the optional Hydronium core package.
  local ok, plugin = pcall(require, "luax")
  if ok and plugin and type(plugin.get_root_dir) == "function" then
    report_ok("luax.nvim plugin loaded successfully")
  else
    report_warn("luax.nvim plugin not found in Neovim runtimepath")
  end

  -- 3. Check CLI binary bin/luax
  local root = (ok and plugin and plugin.get_root_dir and plugin.get_root_dir()) or vim.fn.getcwd()
  local bin_luax = root .. "/bin/luax"
  if vim.fn.filereadable(bin_luax) == 1 then
    if vim.fn.executable(bin_luax) == 1 then
      report_ok("Executable CLI found: " .. bin_luax)
    else
      report_warn("CLI found at " .. bin_luax .. " but is not marked executable (run `chmod +x " .. bin_luax .. "`)")
    end
  else
    report_info("Local CLI bin/luax not found at " .. bin_luax .. " (using pure-Lua runtime fallback)")
  end

  report_start("Tree-sitter Parser & Queries")

  -- 4. Check Tree-sitter parser for luax
  local has_ts, parsers = pcall(require, "nvim-treesitter.parsers")
  if has_ts and parsers and parsers.has_parser and parsers.has_parser("luax") then
    report_ok("Tree-sitter 'luax' parser installed")
  else
    report_info("Tree-sitter 'luax' parser not installed in nvim-treesitter (optional; standard Lua highlights active)")
  end

  -- 5. Check Queries in runtimepath
  local highlights = vim.api.nvim_get_runtime_file("queries/luax/highlights.scm", true)
  if highlights and #highlights > 0 then
    report_ok("Tree-sitter highlights query found: " .. highlights[1])
  else
    report_info("Custom Tree-sitter queries/luax/highlights.scm not in runtimepath")
  end

  report_start("LuaLS Language Server Integration")

  -- 6. Check LuaLS plugin file
  local plugin_path = root .. "/src/hydronium_luax/luals/init.lua"
  if vim.fn.filereadable(plugin_path) == 1 then
    report_ok("LuaLS virtual source plugin file verified: " .. plugin_path)
  else
    report_warn("LuaLS plugin file not found at " .. plugin_path)
  end

  -- 7. Check Types definitions
  local types_dir = root .. "/types"
  if vim.fn.isdirectory(types_dir) == 1 then
    report_ok("LUAX typing directory verified: " .. types_dir)
  else
    report_warn("Typing definitions directory not found at " .. types_dir)
  end
end

return M
