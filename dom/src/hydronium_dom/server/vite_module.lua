--[[
  hydronium_dom.server.vite_module -- hy_asset_ref resolution for JS
  islands, per M2 of docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md.

  WHAT THIS IS. `hy_asset_ref` is already specified (not by this file) in
  docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md's Contract 3: a table
  carrying `asset_id` (the join key) and `specifier` (as written in the
  component), resolved to a final URL rather than having that URL baked in
  at compile time. That contract was designed for `luax.compile`-time
  static-asset references and is, per the plan's own verification ledger,
  "designed but unimplemented -- zero occurrences in real plugin source."
  This file is the first real implementation of that SHAPE, applied to a
  different producer: `d.js.island module=...` specifiers, resolved here
  at SSR RENDER TIME (not compile time, since there is no luax.compile
  pass over JS island specifiers) by hydronium_dom.server.init's ISLAND
  branch, replacing what used to be a bare `raw_props.module` passthrough.

  WHY asset_id == specifier (for now). Contract 3 assumes a compiler pass
  that mints a stable id distinct from the specifier text (so a later
  rename/relocation can keep the same join key). No such pass exists yet
  for JS island specifiers -- `hydronium_ballad.plugins.luax` emits
  `asset_ids = {}` unconditionally today (see plugins/luax.lua:115). Until
  that exists, the specifier IS the only stable identity available, so
  `hy_asset_ref(specifier).asset_id == specifier`. This is a disclosed
  scope limitation, not a misreading of the contract: a real
  compiler-assigned id is future work, not invented here as a "parallel
  mechanism."

  WHY UNCONFIGURED MEANS PASSTHROUGH. Existing callers already write a
  real, final, absolute URL as `module` (see bootstrap.js's own header:
  "d.js.island's module prop MUST be an absolute path or a full URL") --
  examples/meteorite_ssr's `/mixed` route and hydronium-create's islands
  template both do this today, with zero Vite involvement. Resolving
  through this module must never change their behavior. So: call
  M.configure(...) to opt an app into Vite-backed resolution; until then,
  M.resolve returns whatever specifier it was given, byte-for-byte.

  WHY "PROD" DELEGATES TO hydronium_dom.assets INSTEAD OF READING
  dist/.vite/manifest.json ITSELF. An earlier version of this file parsed
  Vite's own manifest.json directly for prod resolution -- a second,
  parallel "read a manifest, look up a key, fall back on miss" mechanism
  sitting right next to the one this codebase ALREADY has:
  hydronium_dom.assets.configure(path)/.url(source). M3 (the production
  manifest merge, docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md) re-emits each
  Vite-built file as a plain `hy_asset` with `metadata.hydronium.source
  == specifier`, fed into hydronium_ballad.plugins.site's EXISTING merge
  -- the exact same merge that already produces the `hydronium-manifest.lua`
  hydronium_dom.assets reads. So once M3 has run, a JS island specifier
  is just another `source` key in that one shared manifest, and prod
  resolution here is nothing more than `assets.url(specifier)`. This is
  the "do not invent a parallel mechanism" instruction taken literally:
  the mechanism to not invent a second copy of was sitting one file over.
--]]

local assets = require("hydronium_dom.assets")

local M = {}

-- Module-local, like hydronium_dom.server.init's own render_state --
-- correct because rendering is single-threaded/non-reentrant in this
-- runtime (see that file's own comment on render_state). Configured once
-- at app startup (dev supervisor or production boot), not per-request.
local state = { mode = nil, vite_origin = nil }

--- Constructs an hy_asset_ref table for a JS island `module` specifier.
--- See this file's header for why `asset_id == specifier` today.
--- @param specifier string as written by the component (`d.js.island`'s `module` prop)
--- @return table { kind = "hy_asset_ref", asset_id, specifier }
function M.hy_asset_ref(specifier)
  if type(specifier) ~= "string" then
    error("hydronium_dom.server.vite_module: hy_asset_ref requires a string specifier", 2)
  end
  return { kind = "hy_asset_ref", asset_id = specifier, specifier = specifier }
end

--- Configures dev/prod resolution. Call once at app startup, before any
--- render that uses a `d.js.island` module Vite should resolve.
--- @param config table|nil
---   { mode = "dev", vite_origin = "http://localhost:5173" }, or
---   { mode = "prod" } -- prod needs no config of its own: it delegates to
---   hydronium_dom.assets, which the app configures once (with the path
---   to its own hydronium-manifest.lua) for every hashed asset it has,
---   JS islands included once M3's vite_assets plugin has run.
---   Passing nil (or omitting mode) is equivalent to M.reset().
function M.configure(config)
  config = config or {}
  if config.mode ~= nil and config.mode ~= "dev" and config.mode ~= "prod" then
    error('hydronium_dom.server.vite_module: mode must be "dev", "prod", or nil', 2)
  end
  if config.mode == "dev" and type(config.vite_origin) ~= "string" then
    error("hydronium_dom.server.vite_module: dev mode requires a string vite_origin, e.g. \"http://localhost:5173\"", 2)
  end
  state = { mode = config.mode, vite_origin = config.vite_origin }
end

--- Restores the unconfigured (pure passthrough) state. Module state is
--- process-global and outlives any one request, so a test suite (or a
--- long-lived dev process switching modes) must call this to clean up.
function M.reset()
  state = { mode = nil, vite_origin = nil }
end

function M.is_configured()
  return state.mode ~= nil
end

function M.mode()
  return state.mode
end

--- Resolves one specifier (a bare string, or an hy_asset_ref table from
--- M.hy_asset_ref) to the URL the browser should actually import.
---
--- Unconfigured: returns the specifier UNCHANGED (see this file's header).
--- mode="dev": prefixes with the configured Vite origin.
--- mode="prod": delegates to hydronium_dom.assets.url(specifier) -- see
---   this file's header for why. Inherits that function's own dev-fallback
---   policy verbatim: a specifier with no manifest entry (assets never
---   configured, or this particular one wasn't in the merged manifest)
---   resolves to the raw `"/" .. specifier`, not an error -- consistent
---   with every other asset URL in this codebase rather than a
---   Vite-specific exception to it.
--- @param ref table|string an hy_asset_ref table, or a bare specifier string
--- @return string the resolved URL (or the original value, unresolved and
---   unchanged, if it isn't a string at all -- e.g. `nil` for an island
---   with no module)
function M.resolve(ref)
  local specifier = ref
  if type(ref) == "table" then
    specifier = ref.specifier
  end
  if type(specifier) ~= "string" then
    return ref
  end

  if state.mode == nil then
    return specifier
  end

  if state.mode == "dev" then
    local origin = (state.vite_origin:gsub("/+$", ""))
    local path = specifier
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return origin .. path
  end

  -- mode == "prod"
  return assets.url(specifier)
end

return M
