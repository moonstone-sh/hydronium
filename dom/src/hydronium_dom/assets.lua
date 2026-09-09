--[[
  hydronium_dom.assets -- resolves a static file (image/font/svg/etc.)
  reference to its real, build-time-hashed, cache-busted URL. See
  docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 3.

  Zero new .luax syntax, same reasoning as hydronium_dom.css: component
  authors write an ordinary function call.

    local assets = require("hydronium_dom.assets")
    <d.img src={assets.url("assets/logo.png")} alt="Hydronium" />

  UNLIKE hydronium_dom.css's scoping (a pure function needing no runtime
  lookup at all), a hashed asset URL genuinely cannot be computed without
  knowing the file's own content hash -- which only
  hydronium_ballad.plugins.assets, at build time, actually has. So this
  module DOES need a real manifest lookup, with an explicit, one-time
  `configure()` call (no automatic discovery/magic paths -- an app
  decides where its own build output lives).

  DEV FALLBACK: before configure() is ever called (or if it's given a
  path that doesn't exist -- a genuinely unbuilt project, not a build
  error), `url(path)` returns the raw `"/" .. path` unchanged and the
  app is expected to serve the source tree directly. Same call site,
  no `if dev` branch needed in application code -- exactly the property
  that makes this usable identically in development and production.
--]]

local M = {}

-- nil = configure() never called; false = called but no manifest found
-- (dev); a table = a real loaded manifest.
local manifest = nil

--- @param manifest_path string Real path to a build's own `hydronium-manifest.lua` (NOT the `.json` sibling -- see docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 3.3 for why this codebase prefers a plain Lua table literal over a hand-rolled JSON reader: zero runtime dependencies, matching every other part of hydronium).
function M.configure(manifest_path)
  local chunk = loadfile(manifest_path)
  if not chunk then
    manifest = false
    return
  end
  local ok, result = pcall(chunk)
  manifest = (ok and type(result) == "table") and result or false
end

--- Real, explicit reset for tests/tooling -- not part of the normal app
--- lifecycle (an app calls `configure()` once, not this).
function M.reset()
  manifest = nil
end

--- @param source_path string Project-relative path exactly as it was given to `p.source.files` at build time (the join key `hydronium_ballad.plugins.assets.hash` records under `metadata.hydronium.source`).
--- @return string A real hashed, cache-busted URL once a real manifest is configured; the raw `"/" .. source_path` otherwise (dev, or that particular file was never part of the asset pipeline).
function M.url(source_path)
  if manifest and manifest.assets and manifest.assets[source_path] then
    return manifest.assets[source_path].url
  end
  return "/" .. source_path
end

return M
