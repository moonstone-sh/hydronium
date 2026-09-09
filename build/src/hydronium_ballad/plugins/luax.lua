--[[
  hydronium_ballad.plugins.luax -- Ballad plugin: compiles .luax source
  files to plain Lua.

  M1: real compilation via hydronium_luax.compile, emitting `hy_module`
  assets shaped exactly per docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md's
  "Contract 1" and docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md.

  NOT YET DONE (real, separate future slices, not silently faked here):
  style/asset extraction (style_ids/asset_ids are always emitted empty --
  see the CSS/assets plan), and cache_salt/cacheable=false override
  wiring for compiler-development runs (see this module's own contract
  comment below on why cacheable=true is a real footgun here).
--]]

local graph = require("ballad.graph")
local luax = require("hydronium_luax")

local M = {}

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then
    error("hydronium_ballad.plugins.luax: cannot read " .. tostring(path) .. ": " .. tostring(err), 0)
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- Mirrors the convention docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md fixes:
--- `views/App.luax` (source-relative virtual_path, ".lua" extension) ->
--- module id `views.App`.
--- @param compiled_virtual_path string Already has ".lua", not ".luax".
--- @return string
local function module_id_from_virtual_path(compiled_virtual_path)
  local without_ext = compiled_virtual_path:gsub("%.lua$", "")
  return (without_ext:gsub("/", "."))
end

--- @param ctx PluginCtx
--- @param inputs AssetSet[] One entry per input node (see pipeline.lua's
---   PluginProxy dispatch -- a single positional argument becomes
---   inputs[1]; `depends_on` handles are appended after it, in order).
--- @param opts table|nil
---   @field target? "client"|"server"|"shared" Stamped onto every emitted
---     module's metadata.hydronium.target -- REQUIRED by contract, but
---     read from here (the partiture author's own choice for this
---     particular compile() call), never inferred by the compiler itself
---     (it has no way to know what's client-reachable).
---   @field runtime? string Passed straight through to hydronium_luax.compile (default "hydronium").
---   @field development? boolean Passed straight through (default false).
---   @field strict_tags? boolean Fail the build on any bare (non-lexical)
---     tag usage instead of only warning. Default false -- every real
---     example in this repo still uses bare tags (see CLAUDE.md), so
---     defaulting this to an error would fail on files nobody has asked
---     to migrate yet.
--- @return AssetSet
function M.compile(ctx, inputs, opts)
  opts = opts or {}
  local target = opts.target or "shared"
  local strict_tags = opts.strict_tags == true

  local out = graph.AssetSet.new()

  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      if asset.virtual_path and asset.virtual_path:match("%.luax$") then
        if not asset.source_path then
          ctx.fail("hydronium_ballad.plugins.luax.compile: asset '" .. tostring(asset.virtual_path)
            .. "' has no source_path (only real files can be compiled, not already-generated assets)")
        else
          local source = read_file(asset.source_path)
          local compile_opts = {
            filename = asset.source_path,
            runtime = opts.runtime or "hydronium",
            development = opts.development == true,
          }
          local ok, result = pcall(luax.compile, source, compile_opts)
          if not ok then
            ctx.fail("hydronium_ballad.plugins.luax.compile: failed to compile " .. asset.source_path
              .. ": " .. tostring(result))
          else
            local bare = result.bare_tags_without_alias or {}
            if #bare > 0 then
              local msg = asset.source_path .. " has " .. #bare
                .. " bare tag(s) without a lexical alias (see CLAUDE.md's bare-vs-lexical-tag migration note): "
                .. table.concat(bare, ", ")
              if strict_tags then
                ctx.fail("hydronium_ballad.plugins.luax.compile: " .. msg)
              else
                ctx.warn("hydronium_ballad.plugins.luax.compile: " .. msg)
              end
            end

            local compiled_vpath = asset.virtual_path:gsub("%.luax$", ".lua")
            local module_id = module_id_from_virtual_path(compiled_vpath)

            out:add(ctx.graph:add_asset({
              kind = "hy_module",
              generated = true,
              virtual_path = compiled_vpath,
              content = result.code,
              metadata = { hydronium = {
                kind = "lua_module",
                origin = asset.source_path,
                module_id = module_id,
                target = target,
                sourcemap = result.map_json,
                style_ids = {},
                asset_ids = {},
                diagnostics = { bare_tags_without_alias = bare },
              }},
            }))
          end
        end
      else
        -- Pass through anything that isn't .luax unchanged -- lets a
        -- partiture feed a mixed set of .luax and already-plain .lua
        -- files through the same compile() call without needing two
        -- separate source nodes.
        out:add(asset)
      end
    end
  end

  return out
end

return {
  name = "hydronium_ballad.plugins.luax",
  version = "0.1.0",
  methods = {
    -- cacheable=true is real and works (ballad hashes each input asset's
    -- real file content), but is a genuine footgun: the cache key
    -- includes contract.version, and hydronium_luax's own _VERSION string
    -- is hand-maintained (still "0.1.0" as of this writing) -- a compiler
    -- change with no version bump would produce a stale cache hit. Pass
    -- `opts.cacheable = false` explicitly during compiler development
    -- (PluginProxy reads this override, see pipeline.lua).
    compile = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = true,
      parallel_safe = true,
    },
  },
  compile = M.compile,
}
