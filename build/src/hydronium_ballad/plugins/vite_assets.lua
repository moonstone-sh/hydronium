--[[
  hydronium_ballad.plugins.vite_assets -- M3 of
  docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md: ingests a real Vite production
  build (dist/.vite/manifest.json plus the files it names) and re-emits
  each entry as a plain `hy_asset`, in EXACTLY the shape
  hydronium_ballad.plugins.assets.hash already produces (see that file's
  own `hash` method). `site.lua`'s manifest merge already generalizes
  over any `hy_asset` with `metadata.hydronium.source` (site.lua's
  `manifest` method) -- this plugin needs ZERO changes there. If you find
  yourself wanting to edit site.lua to make this work, this plugin's
  output shape is wrong instead.

  INTAKE. The same `p.source.files` shape hydronium_ballad.plugins.assets
  already consumes: `kind = "file"` assets with `source_path`/
  `virtual_path`, pointed at a built Vite `dist/` directory -- so
  `dist/.vite/manifest.json` itself is one of the ingested assets,
  alongside every file it names.

  DEGRADE GRACEFULLY (plan hazard #1). A framework-level partiture must
  never depend on this plugin failing loudly when Vite was never run --
  CI has no node/npm step at all. If the manifest isn't among the
  ingested assets, every input passes through UNCHANGED and this node is
  a no-op. `vite_assets` belongs in a CONSUMING APP's partiture, never
  the root one.

  INTEGRITY. Vite's own manifest carries no content hash.
  `plugins.assets.hash` b3sums the real file on disk for its `hy_asset`s;
  this plugin does the exact same thing over each Vite-built file,
  keeping the same "b3:" prefix so the merged manifest stays homogeneous
  -- a consumer reading `metadata.hydronium.integrity` never needs to
  know which plugin produced a given entry.

  JOIN KEY. `metadata.hydronium.source` is set to the manifest entry's
  OWN KEY -- the specifier exactly as Vite's `rollupOptions.input` (or an
  app's own `d.js.island module=...` value) named it, e.g.
  "src/counter-island.js". This is deliberately the SAME string
  `hydronium_dom.server.vite_module`'s dev-mode resolver prefixes with
  the Vite origin, and the SAME string `hydronium_dom.assets.url(...)`
  looks up at runtime -- one join key, every mode, no translation table.
--]]

local graph = require("ballad.graph")
local process = require("ballad.process")
local dkjson = require("dkjson")

local M = {}

--- @class HydroniumBalladViteAssetsIngestOptions
--- @field manifest_path? string Virtual path (within the ingested asset_set, i.e. relative to the built Vite `dist/` root) of Vite's manifest.json. Default ".vite/manifest.json" -- Vite's own default location.

--- @param ctx PluginCtx
--- @param inputs AssetSet[] -- p.source.files(...) over a built Vite dist/ directory
--- @param opts HydroniumBalladViteAssetsIngestOptions
--- @return AssetSet
function M.ingest(ctx, inputs, opts)
  opts = opts or {}
  local manifest_vpath = opts.manifest_path or ".vite/manifest.json"

  local by_vpath = {}
  local order = {}
  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      if not by_vpath[asset.virtual_path] then
        order[#order + 1] = asset.virtual_path
      end
      by_vpath[asset.virtual_path] = asset
    end
  end

  local out = graph.AssetSet.new()
  local manifest_asset = by_vpath[manifest_vpath]

  if not manifest_asset then
    -- No Vite build present in this input set -- see this file's own
    -- "DEGRADE GRACEFULLY" note. Pass everything through untouched.
    for _, vpath in ipairs(order) do
      out:add(by_vpath[vpath])
    end
    return out
  end

  if not manifest_asset.source_path then
    ctx.fail("hydronium_ballad.plugins.vite_assets: the asset at " .. manifest_vpath
      .. " has no source_path -- expected a real p.source.files() file asset, not generated content")
    return out
  end

  local f = io.open(manifest_asset.source_path, "r")
  if not f then
    ctx.fail("hydronium_ballad.plugins.vite_assets: could not open " .. manifest_asset.source_path)
    return out
  end
  local raw = f:read("*a")
  f:close()

  local ok, manifest = pcall(dkjson.decode, raw)
  if not ok or type(manifest) ~= "table" then
    ctx.fail("hydronium_ballad.plugins.vite_assets: failed to parse " .. manifest_asset.source_path
      .. " as JSON: " .. tostring(manifest))
    return out
  end

  -- Which built files (by their virtual_path within dist/) have already
  -- been re-emitted as an hy_asset, so a file named by more than one
  -- manifest entry (or by both an entry's `file` and its own `css` list)
  -- is only ever emitted once.
  local consumed = { [manifest_vpath] = true }

  local function emit_hy_asset(source_key, file_vpath)
    if consumed[file_vpath] then return end
    local built = by_vpath[file_vpath]
    if not built or not built.source_path then return end
    consumed[file_vpath] = true
    local digest = process.b3sum(built.source_path)
    out:add(ctx.graph:add_asset({
      kind = "hy_asset",
      source_path = built.source_path,
      virtual_path = built.virtual_path,
      metadata = { hydronium = {
        kind = "asset",
        source = source_key,
        url = "/" .. built.virtual_path,
        integrity = "b3:" .. digest,
      }},
    }))
  end

  -- Deterministic iteration order: Vite's manifest is a JSON object
  -- (unordered by definition), but ballad's own graph/cache layers
  -- fingerprint an AssetSet's CONTENT, not the order asset ids happen to
  -- be minted in, so sorting here is for readable diagnostics/diffs, not
  -- correctness.
  local specifiers = {}
  for specifier in pairs(manifest) do
    specifiers[#specifiers + 1] = specifier
  end
  table.sort(specifiers)

  for _, specifier in ipairs(specifiers) do
    local entry = manifest[specifier]
    if type(entry) == "table" and type(entry.file) == "string" then
      emit_hy_asset(specifier, entry.file)
      if type(entry.css) == "table" then
        for _, css_vpath in ipairs(entry.css) do
          -- CSS pulled in as a side effect of a JS entry has no specifier
          -- of its own in the manifest -- keyed by its own built path,
          -- which is at least stable and unique within this one build
          -- (content-hashed, so it changes on every real content change,
          -- same as any other hy_asset's source_path-derived identity).
          emit_hy_asset(css_vpath, css_vpath)
        end
      end
    end
  end

  -- Anything in the ingested set the manifest never named (an image only
  -- reachable via a bare `url()`/copied public/ file, say) passes through
  -- unchanged -- this plugin re-tags what the manifest identifies, it
  -- does not decide what belongs in the final site.
  for _, vpath in ipairs(order) do
    if not consumed[vpath] then
      out:add(by_vpath[vpath])
    end
  end

  return out
end

return {
  name = "hydronium_ballad.plugins.vite_assets",
  version = "0.1.0",
  methods = {
    -- cacheable=true: a pure function of the ingested asset_set's own
    -- content (the manifest.json's bytes and every built file's own
    -- bytes, both already part of ballad's cache key via the input
    -- asset_set) -- same reasoning as plugins.assets.hash.
    ingest = { inputs = { "asset_set" }, outputs = { "asset_set" }, cacheable = true, parallel_safe = true },
  },
  ingest = M.ingest,
}
