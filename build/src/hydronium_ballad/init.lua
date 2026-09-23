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
  topology = require("hydronium_ballad.plugins.topology"),
  style = require("hydronium_ballad.plugins.style"),
  assets = require("hydronium_ballad.plugins.assets"),
  site = require("hydronium_ballad.plugins.site"),
  -- Ingests a built Vite dist/ and re-emits it as ordinary hy_asset entries
  -- for site.manifest's merge -- see docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md
  -- M3. Belongs in a consuming app's partiture, never the root one (it would
  -- make the framework's own registry export depend on a JS build).
  vite_assets = require("hydronium_ballad.plugins.vite_assets"),
}

return M
