--[[
  hydronium_ballad -- Ballad build plugins for Hydronium projects.

  See docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md (package boundary,
  milestones), docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md (the luax/style/assets
  plugins), and docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md (the client
  plugin) in the hydronium repo for the full design.
--]]

local M = {}

M.plugins = {
  luax = require("hydronium_ballad.plugins.luax"),
  client = require("hydronium_ballad.plugins.client"),
  style = require("hydronium_ballad.plugins.style"),
  assets = require("hydronium_ballad.plugins.assets"),
  site = require("hydronium_ballad.plugins.site"),
}

return M
