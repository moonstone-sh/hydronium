# Hydronium .luax Neovim Plugin Architecture & Integration Guide

## 1. Relocatable Design & Zero Absolute Paths

The Hydronium Neovim plugin (`extra/nvim/`) is designed with **100% relocatability**. It strictly avoids any hardcoded absolute user home paths (e.g. `/Users/...` or `/home/...`), allowing it to be installed via any plugin manager, embedded as a submodule, or symlinked into `runtimepath`.

Dynamic path resolution relies on Lua's reflection API (`debug.getinfo(1, "S")`) and Neovim's runtime discovery (`vim.api.nvim_get_runtime_file`):

```mermaid
flowchart LR
    NVIM["Neovim Startup"] --> FT["ftdetect/luax.vim\n*.luax -> filetype=luax"]
    NVIM --> SETUP["require('hydronium').setup()"]
    SETUP --> DYN["Dynamic Root Discovery\n(get_root_dir)"]
    DYN --> LUALS_CFG["LuaLS Plugin Path\nget_luals_plugin_path()"]
    DYN --> TYPES_CFG["LuaCATS Types Path\nget_types_path()"]
    SETUP --> CMD[":HydroniumFormat Command"]
    NVIM --> HEALTH[":checkhealth hydronium"]
```

---

## 2. Plugin File Structure

```
extra/nvim/
├── ftdetect/
│   └── luax.vim                # Auto-detects *.luax as filetype 'luax'
└── lua/
    └── hydronium/
        ├── init.lua            # Plugin setup, formatting, and dynamic paths
        └── health.lua          # :checkhealth hydronium verification suite
```

---

## 3. Installation Guide

### Using `lazy.nvim`
```lua
{
  "hydronium-ui/hydronium",
  -- If using local path during development:
  -- dir = "~/Workbench/user/hydronium/extra/nvim",
  ft = { "luax", "lua" },
  config = function()
    require("hydronium").setup({
      treesitter = true,
      format_on_save = true,
    })
  end,
}
```

### Using `packer.nvim`
```lua
use({
  "hydronium-ui/hydronium",
  rtp = "extra/nvim",
  config = function()
    require("hydronium").setup()
  end,
})
```

---

## 4. LuaLS Configuration with `nvim-lspconfig`

To enable real-time 1:1 type diagnostics, prop autocompletion, and hover inspection on `.luax` files, configure `lua_ls` to load the Hydronium virtual source plugin:

```lua
local lspconfig = require("lspconfig")
local hydronium = require("hydronium")

lspconfig.lua_ls.setup({
  settings = {
    Lua = {
      runtime = {
        version = "LuaJIT",
      },
      workspace = {
        checkThirdParty = false,
        library = {
          -- Dynamically injects types without hardcoded absolute paths
          hydronium.get_types_path(),
          vim.env.VIMRUNTIME,
        },
      },
      plugin = {
        -- Dynamically injects the LuaLS plugin hook
        path = hydronium.get_luals_plugin_path(),
      },
      diagnostics = {
        globals = { "Hydronium", "d", "H" },
      },
    },
  },
})
```

---

## 5. Commands & Features

### `:HydroniumFormat`
Formats the active buffer using the pure-Lua CST idempotent formatter or `bin/luax format`:
```vim
:HydroniumFormat
```

### Format on Save
Enable automatic formatting on buffer write in your setup configuration:
```lua
require("hydronium").setup({
  format_on_save = true,
})
```

### `:checkhealth hydronium`
Runs comprehensive environment verification:
- LuaJIT / Lua runtime detection.
- Hydronium library availability.
- `bin/luax` CLI executable permissions.
- Tree-sitter `luax` parser and query files.
- LuaLS virtual source plugin and typing directory presence.
