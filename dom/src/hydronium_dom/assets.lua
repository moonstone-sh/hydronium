--[[
  hydronium_dom.assets -- resolves a static file (image/font/svg/etc.)
  reference to its real, build-time-hashed, cache-busted URL, AND (STEP 1
  of docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md) a small PROVIDER interface
  so a Document component can ask for an entry's full markup (its own
  <link>/<script> tag plus any CSS its build pulled in) without caring
  whether that entry was built by hydronium_ballad's own bundler or by
  Vite, in dev or in prod. See docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md
  section 3 for the original (pre-Vite) design this extends.

  Zero new .luax syntax, same reasoning as hydronium_dom.css: component
  authors write an ordinary function call.

    local assets = require("hydronium_dom.assets")
    <d.img src={assets.url("assets/logo.png")} alt="Hydronium" />
    <head>{assets.tags("src/main.js")}</head>

  THE PROVIDER CONTRACT (STEP 1). Hydronium owns this contract; Vite is
  one implementation of it, never a hard dependency -- the whole point of
  the adapter pattern this module is part of. Three providers:

    "static" (DEFAULT, zero Node) -- hydronium_ballad's own hashed
      `hydronium-manifest.lua` (unchanged from before this step). A
      manifest entry is one file; `tags()` on it emits exactly one tag.

    "vite-dev" -- Vite's dev server origin (e.g. "http://localhost:5173"),
      reused from `hydronium_dom.server.vite_module`'s own dev-origin
      reasoning: Meteorite can't serve websockets, so Vite's HMR socket
      (and, in dev, every asset URL) must be absolute to Vite's own
      origin. No manifest to read in dev -- Vite resolves the module
      graph itself once the browser starts importing.

    "vite-manifest" -- a real Vite `dist/.vite/manifest.json`, read and
      decoded DIRECTLY (hydronium_dom.server.json.decode -- see that
      module for why this is the one place in `dom/` that reads actual
      JSON rather than a Lua table literal: it is the one manifest shape
      in this pipeline that a tool OUTSIDE this codebase produces).
      Unlike "static", a Vite manifest entry carries `css`/`imports`, so
      `tags()` walks the import graph and emits every CSS file the entry
      transitively pulls in before the entry's own script tag -- the
      same "add the CSS files used by dynamic imports too, or you get a
      flash of unstyled content" rule Vite's own SSR docs describe.

  SELECTION. One call, once, at app startup (main.lua / the Meteorite
  bootstrap for the app in question) -- no automatic discovery, matching
  this module's existing "no magic paths" stance:

    local assets = require("hydronium_dom.assets")
    if os.getenv("HYDRONIUM_VITE_MODE") == "dev" then
      assets.configure_provider({ provider = "vite-dev", vite_origin = os.getenv("HYDRONIUM_VITE_ORIGIN") })
    else
      assets.configure_provider({ provider = "vite-manifest", manifest_path = "dist/.vite/manifest.json" })
      -- or, for an app with no Vite build at all:
      -- assets.configure_provider({ provider = "static", manifest_path = "dist/hydronium-manifest.lua" })
    end

  `HYDRONIUM_VITE_MODE`/`HYDRONIUM_VITE_ORIGIN` are a documented
  CONVENTION for how a project's own bootstrap reads dev-vs-prod, not
  something this module inspects itself -- `create/src/create/vite.lua`'s
  scaffolded `main.lua` is the reference implementation.

  BACK-COMPAT. `configure(manifest_path)`/`configure_table(table)`/`url()`
  behave EXACTLY as before this step (both existing call sites and
  hydronium_dom.server.vite_module's own "prod mode delegates to
  hydronium_dom.assets" behavior are unchanged) -- they are sugar for
  `configure_provider({ provider = "static", ... })`.

  DEV FALLBACK (unchanged invariant, ALL providers). `url(source)` never
  raises: an unconfigured provider, a missing manifest, or a source with
  no matching entry all resolve to the raw `"/" .. source`, exactly as
  before this step. `tags(entry)`, introduced by this step, is the one
  STRICTER exception: a "vite-manifest" entry that isn't in the manifest
  is very likely a real build misconfiguration (an island that was never
  declared as a Vite input), so it raises loudly rather than silently
  rendering a broken tag -- mirroring `@hydronium-js/vite`'s own
  `resolveIslandModule` (js/packages/vite/src/islands.ts), which throws
  for the identical reason.

  BROWSER/SPA: `configure()`/`configure_table()` are SERVER-SIDE entry
  points (`configure()` calls `loadfile`; there is no filesystem inside
  wasmoon). A client-side (SPA) app hands over an already-loaded table via
  `configure_table`, exactly as before.
--]]

local M = {}

-- ===========================================================================
-- Provider state
-- ===========================================================================

-- "static" | "vite-dev" | "vite-manifest". Always "static" until
-- configure_provider() says otherwise -- the zero-Node default.
local current_provider = "static"

-- "static" provider state (unchanged from before this step).
-- nil = configure() never called; false = called but no manifest found
-- (dev); a table = a real loaded manifest.
local manifest = nil

-- "vite-dev" provider state.
local dev_origin = nil -- trailing-slash-trimmed origin string, e.g. "http://localhost:5173"

-- "vite-manifest" provider state.
-- nil = never configured; false = configured but no/invalid manifest found
-- (dev fallback, same policy as "static"); a table = Vite's own decoded
-- manifest.json (entry key -> { file, css, imports, isEntry, ... }).
local vite_manifest = nil
local vite_manifest_base = "/"

--- @return string the active provider name ("static" is the default).
function M.provider()
  return current_provider
end

-- ===========================================================================
-- Configuration
-- ===========================================================================

--- @param manifest_path string Real path to a build's own `hydronium-manifest.lua` (NOT the `.json` sibling -- see docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 3.3 for why this codebase prefers a plain Lua table literal over a hand-rolled JSON reader: zero runtime dependencies, matching every other part of hydronium).
function M.configure(manifest_path)
  current_provider = "static"
  local chunk = loadfile(manifest_path)
  if not chunk then
    manifest = false
    return
  end
  local ok, result = pcall(chunk)
  manifest = (ok and type(result) == "table") and result or false
end

--- Configures from an already-loaded manifest table -- the browser path,
--- where `configure()`'s `loadfile` has no filesystem to read (see the
--- module header). Anything that is not a table is treated exactly like a
--- missing manifest file: the dev fallback, not an error.
--- @param manifest_table table A loaded `hydronium-manifest.lua` result.
function M.configure_table(manifest_table)
  current_provider = "static"
  manifest = type(manifest_table) == "table" and manifest_table or false
end

--- @class HydroniumAssetsProviderConfig
--- @field provider? '"static"'|'"vite-dev"'|'"vite-manifest"' Default "static".
--- @field manifest_path? string "static": passed to `configure()`. "vite-manifest": a real `dist/.vite/manifest.json` path, read and JSON-decoded now.
--- @field manifest_table? table "static": passed to `configure_table()`. "vite-manifest": an already-decoded manifest table (e.g. a test fixture, or a caller that already read the file itself).
--- @field vite_origin? string "vite-dev" only, REQUIRED: Vite's dev server origin, e.g. "http://localhost:5173" (see @hydronium-js/vite's `resolveDevOrigin`, js/packages/vite/src/dev-origin.ts, which computes exactly this string on the JS side of one dev session).
--- @field base? string "vite-manifest" only: URL prefix built files are served under. Default "/".

--- The single entry point STEP 1 adds: selects and configures one of the
--- three providers described in this module's own header. Call once at
--- app startup; see the header for the documented dev/prod selection
--- convention.
--- @param config HydroniumAssetsProviderConfig|nil
function M.configure_provider(config)
  config = config or {}
  local provider = config.provider or "static"

  if provider == "static" then
    if config.manifest_table ~= nil then
      M.configure_table(config.manifest_table)
    elseif config.manifest_path then
      M.configure(config.manifest_path)
    else
      current_provider = "static"
      manifest = nil
    end
    return
  end

  if provider == "vite-dev" then
    if type(config.vite_origin) ~= "string" or config.vite_origin == "" then
      error("hydronium_dom.assets.configure_provider: \"vite-dev\" requires a string vite_origin, e.g. \"http://localhost:5173\"", 2)
    end
    current_provider = "vite-dev"
    dev_origin = (config.vite_origin:gsub("/+$", ""))
    return
  end

  if provider == "vite-manifest" then
    current_provider = "vite-manifest"
    vite_manifest_base = config.base or "/"
    if config.manifest_table ~= nil then
      vite_manifest = type(config.manifest_table) == "table" and config.manifest_table or false
    elseif config.manifest_path then
      local f = io.open(config.manifest_path, "r")
      if not f then
        vite_manifest = false
      else
        local raw = f:read("*a")
        f:close()
        local json = require("hydronium_dom.server.json")
        local ok, decoded = pcall(json.decode, raw)
        vite_manifest = (ok and type(decoded) == "table") and decoded or false
      end
    else
      vite_manifest = false
    end
    return
  end

  error("hydronium_dom.assets.configure_provider: unknown provider "
    .. string.format("%q", tostring(provider)) .. " -- expected \"static\", \"vite-dev\", or \"vite-manifest\"", 2)
end

--- Real, explicit reset for tests/tooling -- not part of the normal app
--- lifecycle (an app calls configure_provider() once, not this). Clears
--- ALL provider state and returns to the "static", unconfigured default.
function M.reset()
  current_provider = "static"
  manifest = nil
  dev_origin = nil
  vite_manifest = nil
  vite_manifest_base = "/"
end

-- ===========================================================================
-- url() -- single-file resolution, provider-dispatched. Never raises (see
-- module header's "DEV FALLBACK" note): every branch below degrades to
-- the raw "/"..source_path.
-- ===========================================================================

local function static_url(source_path)
  if manifest and manifest.assets and manifest.assets[source_path] then
    return manifest.assets[source_path].url
  end
  return "/" .. source_path
end

local function dev_url(source_path)
  local path = source_path
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  return dev_origin .. path
end

local function join_base(base, vpath)
  base = (base or "/"):gsub("/+$", "")
  return base .. "/" .. (vpath:gsub("^/+", ""))
end

local function vite_manifest_url(source_path)
  if vite_manifest and type(vite_manifest) == "table" then
    local entry = vite_manifest[source_path]
    if type(entry) == "table" and type(entry.file) == "string" then
      return join_base(vite_manifest_base, entry.file)
    end
  end
  return "/" .. source_path
end

--- @param source_path string Project-relative path exactly as it was given to `p.source.files` at build time (the join key `hydronium_ballad.plugins.assets.hash` records under `metadata.hydronium.source`), or a Vite entry specifier when the "vite-manifest"/"vite-dev" provider is active.
--- @return string A real hashed/dev-server URL once a provider is configured with real data; the raw `"/" .. source_path` otherwise.
function M.url(source_path)
  if current_provider == "vite-dev" then
    return dev_url(source_path)
  elseif current_provider == "vite-manifest" then
    return vite_manifest_url(source_path)
  end
  return static_url(source_path)
end

-- ===========================================================================
-- tags() -- entry markup, provider-dispatched. See module header for why
-- this is the one place that raises on a genuine misconfiguration rather
-- than falling back.
-- ===========================================================================

local function tag_for_file(url)
  local dom = require("hydronium_dom.dom")
  if url:match("%.css$") then
    return dom.d.link({ rel = "stylesheet", href = url })
  end
  return dom.d.script({ type = "module", src = url })
end

local function static_tags(entry)
  return { tag_for_file(static_url(entry)) }
end

local function dev_tags(entry)
  return { tag_for_file(dev_url(entry)) }
end

--- Recursively collects the CSS files a Vite manifest entry pulls in,
--- following `imports` (statically-imported chunks) exactly as Vite's own
--- SSR-manifest documentation prescribes -- an import's CSS is not listed
--- on the entry itself. `seen`/`css_seen` are separate: a chunk can be
--- imported by more than one path (diamond dependency) and must only be
--- walked, and its CSS only emitted, once.
local function collect_css(map, key, seen, css_list, css_seen)
  if seen[key] then return end
  seen[key] = true
  local entry = map[key]
  if type(entry) ~= "table" then return end
  if type(entry.css) == "table" then
    for _, css_vpath in ipairs(entry.css) do
      if not css_seen[css_vpath] then
        css_seen[css_vpath] = true
        css_list[#css_list + 1] = css_vpath
      end
    end
  end
  if type(entry.imports) == "table" then
    for _, imported_key in ipairs(entry.imports) do
      collect_css(map, imported_key, seen, css_list, css_seen)
    end
  end
end

local function vite_manifest_tags(entry_key)
  if not vite_manifest or vite_manifest == false then
    error("hydronium_dom.assets.tags: the \"vite-manifest\" provider has no manifest loaded -- "
      .. "call configure_provider({ provider = \"vite-manifest\", manifest_path = ... }) with a real "
      .. "dist/.vite/manifest.json first", 2)
  end
  local entry = vite_manifest[entry_key]
  if type(entry) ~= "table" or type(entry.file) ~= "string" then
    error("hydronium_dom.assets.tags: " .. string.format("%q", entry_key) .. " is not in the Vite build "
      .. "manifest -- declare it as a Vite build input (e.g. @hydronium-js/vite's `islands` option, or "
      .. "rollupOptions.input) so it actually gets built", 2)
  end

  local css_list, seen, css_seen = {}, {}, {}
  collect_css(vite_manifest, entry_key, seen, css_list, css_seen)

  local out = {}
  for _, css_vpath in ipairs(css_list) do
    out[#out + 1] = tag_for_file(join_base(vite_manifest_base, css_vpath))
  end
  out[#out + 1] = tag_for_file(join_base(vite_manifest_base, entry.file))
  return out
end

--- Resolves one build entry (a `p.source.files` source key, or a Vite
--- entry specifier) to the real, orderable list of `<link>`/`<script>`
--- elements a Document component should render for it -- CSS first (so a
--- browser never paints unstyled content while the script downloads),
--- then the entry's own tag. The returned values are ordinary hydronium
--- vnodes (`d.link(...)`/`d.script(...)`), directly embeddable as a
--- child array from a `.luax` component (`hydronium.core.element`'s
--- `flattenChildren` already flattens array children):
---
---   <head>{assets.tags("src/main.js")}</head>
---
--- @param entry string
--- @return table[] an array of hydronium vnodes, in render order.
function M.tags(entry)
  if type(entry) ~= "string" then
    error("hydronium_dom.assets.tags: entry must be a string specifier, got " .. type(entry), 2)
  end
  if current_provider == "vite-dev" then
    return dev_tags(entry)
  elseif current_provider == "vite-manifest" then
    return vite_manifest_tags(entry)
  end
  return static_tags(entry)
end

return M
