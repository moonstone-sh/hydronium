--[[
  hydronium_ballad.plugins.site -- merges the outputs of the other
  plugins (hashed assets, the CSS bundle) into ONE shared manifest, per
  docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 3.3/4. This is intentionally
  the LAST node before a real sink -- `p.sink.directory` accepts exactly
  one input handle (see docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md
  section 3.1), so a real app partiture feeds every branch (compiled
  modules, styles, hashed assets) into this node via `depends_on`, and
  sinks ITS output.

  Emits the manifest TWICE, deliberately: `hydronium-manifest.json` (for
  external/JS tooling) and `hydronium-manifest.lua` (`return {...}`, a
  plain Lua table literal -- what hydronium_dom.assets/css actually
  `loadfile()`s at runtime). This mirrors dom/tools/gen_client_manifest.lua's
  own reasoning for hand-rolling JSON emission rather than adding a
  dependency: hydronium has zero non-stdlib Lua runtime dependencies
  anywhere, by design (see docs/BUNDLING.md section 1.1) -- a
  `loadstring`-able table literal is free for the Lua side to produce
  AND consume; a JSON *reader* would be new, avoidable risk. `dkjson`
  (used here for the `.json` sibling only, a real ballad-provided
  dependency already on this plugin's own LUA_PATH -- see
  hydronium-ballad's moonstone.toml) never needs to be required by
  application code at all.

  NOT YET DONE (real, separate future work, not silently faked): merging
  compiled-module/require-graph info into the manifest (the `modules`
  field docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 3.3 sketches) --
  hydronium_ballad.plugins.client already has its own real chunk manifest
  concept (docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md's "Contract 5"),
  and reconciling the two manifest shapes needs a real design pass, not
  a guess made here.
--]]

local graph = require("ballad.graph")
local dkjson = require("dkjson")

local M = {}

--- Serializes a plain-data Lua value (string/number/boolean/table of
--- those, no functions -- exactly what this node ever builds) into real
--- Lua source. Not a general serializer -- e.g. does not detect cycles,
--- because the manifest table this module builds cannot contain one.
--- @param v any
--- @param indent string
--- @return string
local function serialize_lua_value(v, indent)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "nil" then
    return "nil"
  elseif t == "table" then
    local inner = indent .. "  "
    local parts = {}
    if #v > 0 then
      for _, item in ipairs(v) do
        table.insert(parts, inner .. serialize_lua_value(item, inner))
      end
    else
      local keys = {}
      for k in pairs(v) do
        table.insert(keys, k)
      end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        local key_str
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          key_str = k
        else
          key_str = "[" .. serialize_lua_value(k, inner) .. "]"
        end
        table.insert(parts, inner .. key_str .. " = " .. serialize_lua_value(v[k], inner))
      end
    end
    if #parts == 0 then
      return "{}"
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  error("hydronium_ballad.plugins.site: cannot serialize a " .. t .. " value into the manifest", 0)
end

--- @class HydroniumBalladSiteManifestOptions
--- @field name? string Default "hydronium-manifest". Both emitted files share this basename (`.json`/`.lua`).

--- Passes every input asset through UNCHANGED (this node is additive: it
--- adds two manifest assets to whatever it received, it never removes
--- or replaces anything) -- so a partiture's final sink sees the
--- compiled modules, the CSS bundle, the hashed assets, AND the manifest,
--- all in one `AssetSet`.
--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts HydroniumBalladSiteManifestOptions
--- @return AssetSet
function M.manifest(ctx, inputs, opts)
  opts = opts or {}
  local name = opts.name or "hydronium-manifest"

  local out = graph.AssetSet.new()
  local assets_map, styles_info = {}, {}

  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      out:add(asset)
      local h = asset.metadata and asset.metadata.hydronium
      if h then
        if asset.kind == "hy_asset" and h.source then
          assets_map[h.source] = { url = h.url, integrity = h.integrity }
        elseif asset.kind == "hy_style_bundle" then
          styles_info = { url = h.url, sheet_count = h.sheet_count, reset = h.reset }
        end
      end
    end
  end

  local manifest_table = {
    version = 1,
    assets = assets_map,
    styles = styles_info,
  }

  out:add(ctx.graph:add_asset({
    kind = "hy_manifest",
    generated = true,
    virtual_path = name .. ".json",
    content = dkjson.encode(manifest_table, { indent = true }),
    metadata = { hydronium = { manifest = "site", format = "json" } },
  }))
  out:add(ctx.graph:add_asset({
    kind = "hy_manifest",
    generated = true,
    virtual_path = name .. ".lua",
    content = "return " .. serialize_lua_value(manifest_table, "") .. "\n",
    metadata = { hydronium = { manifest = "site", format = "lua" } },
  }))

  return out
end

return {
  name = "hydronium_ballad.plugins.site",
  version = "0.1.0",
  methods = {
    -- cacheable=false: this node embeds a run-wide view assembled from
    -- every other asset's metadata (never hashed by ballad's cache key,
    -- see docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md section 3.1) -- a
    -- stale hit here would be a silent wrong-manifest failure, and the
    -- node itself does negligible work, so there is no real cost to
    -- always re-running it.
    manifest = { inputs = { "asset_set" }, outputs = { "asset_set" }, cacheable = false, parallel_safe = true },
  },
  manifest = M.manifest,
}
