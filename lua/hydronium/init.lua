-- Hydronium Neovim Plugin Entrypoint
local M = {}

function M.setup(opts)
  opts = opts or {}
  -- Ensure luax filetype is recognized
  vim.filetype.add({
    extension = {
      luax = "luax",
    },
  })
end

return M
