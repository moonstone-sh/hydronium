--[[
  hydronium_ballad.plugins.assets -- content-hashed static asset files
  (images, fonts, SVGs, arbitrary files) for cache-busting. See
  docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 3.

  Input: `kind = "file"` assets (real files on disk, `source_path` set).
  Output: one `hy_asset` per input, `source_path` PRESERVED (never read
  into `content`) so `write_asset_to_directory` takes the real
  `fs.copy_file` branch -- a multi-megabyte image never becomes an
  in-memory Lua string, and binary content is never at risk of being
  mangled by anything that assumes text.

  Content-hash here (not path-hash, unlike hydronium_dom.css's scoping):
  cache-busting and safe far-future immutable caching are the entire
  point, so the hash must change whenever the FILE'S BYTES change, not
  just whenever its path changes.
--]]

local graph = require("ballad.graph")
local process = require("ballad.process")

local M = {}

--- @param hash string
--- @return string
local function require_real_hash(ctx, hash)
  if hash == "" then
    ctx.fail("hydronium_ballad.plugins.assets.hash: b3sum is not available -- ballad's own cache "
      .. "silently degrades without it; this plugin refuses to proceed rather than emit an unhashed asset URL")
  end
  return hash
end

--- @class HydroniumBalladAssetsHashOptions
--- @field hash_length? integer Default 10.
--- @field out_prefix? string Default "assets/".

--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts HydroniumBalladAssetsHashOptions
--- @return AssetSet
function M.hash(ctx, inputs, opts)
  opts = opts or {}
  local hash_length = opts.hash_length or 10
  local out_prefix = opts.out_prefix or "assets/"

  local out = graph.AssetSet.new()
  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      if asset.kind == "file" and asset.source_path and asset.virtual_path then
        local digest = require_real_hash(ctx, process.b3sum(asset.source_path)):sub(1, hash_length)
        local basename = asset.virtual_path:match("([^/]+)$") or asset.virtual_path
        local stem, ext = basename:match("^(.*)%.([%w]+)$")
        local hashed_name = (stem and ext) and (stem .. "." .. digest .. "." .. ext) or (basename .. "." .. digest)
        local vpath = out_prefix .. hashed_name

        out:add(ctx.graph:add_asset({
          kind = "hy_asset",
          source_path = asset.source_path,
          virtual_path = vpath,
          metadata = { hydronium = {
            kind = "asset",
            source = asset.virtual_path,
            url = "/" .. vpath,
            integrity = "b3:" .. digest,
          }},
        }))
      else
        out:add(asset)
      end
    end
  end
  return out
end

return {
  name = "hydronium_ballad.plugins.assets",
  version = "0.1.0",
  methods = {
    -- cacheable=true: pure content transform (the hash IS the content's
    -- own digest), plain-data opts only.
    hash = { inputs = { "asset_set" }, outputs = { "asset_set" }, cacheable = true, parallel_safe = true },
  },
  hash = M.hash,
}
