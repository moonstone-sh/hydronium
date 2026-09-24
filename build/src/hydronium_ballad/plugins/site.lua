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

  The optional `modules` section is a public seed for client graph tooling.
  It exposes logical IDs and build semantics only: never `origin` or a source
  path, which are host-private details even in development.
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

--- @class HydroniumBalladMountOptions
--- @field title? string Page `<title>`. Default "Hydronium App".
--- @field container? string CSS id selector mount() targets, e.g. "#app". Default "#app".
--- @field hydrate? boolean Passed straight through to mount()'s `hydrate`. Default false (a static SPA has no SSR markup to claim).
--- @field js_bootstrap_url? string URL of the real `mount.js` (`@hydronium-js/dom-client`) the page imports. Default "/js/bootstrap/mount.js" -- this plugin does not vendor that file into the sink itself; the project is responsible for serving it at that URL (or overriding this to wherever it does).
--- @field asset_manifest_url? string Passed as mount()'s `assetManifestUrl`. Default "/<name>.lua" (the Lua-table sibling this same node emits, since wasmoon has no filesystem for `loadfile()`).
--- @field lua_globals? { module: string, import: string } Optional extra ESM import whose named export is CALLED (`import()()`) and passed as mount()'s `luaGlobals` -- e.g. `{ module = "/js/router/hash_history.js", import = "createHashHistoryGlobals" }` for an app that uses hydronium_router's hash history adapter. This plugin has no router awareness of its own; a partiture that needs one supplies it explicitly.
--- @field vendor? { dir: string, url_prefix: string }[] Real, on-disk directory trees to copy into the sink VERBATIM (recursively, preserving relative paths) under `url_prefix` (a site-relative path with no leading "/", e.g. "js/bootstrap"). Exists because `index.html` references `js_bootstrap_url`/`lua_globals.module` as absolute site paths, and this plugin does not assume anything serves those bytes except what the build itself produces (a plain `ballad play`'s dist/ must be deployable to a dumb static file server with nothing else running -- docs/HYDRONIUM_SPA_MODE_PLAN.md section 2.1). Declared here, not copied by a CLI, for the same reason `mount` itself is declared here: the partiture that knows it needs `/js/bootstrap/mount.js` and `/js/router/hash_history.js` is the one that says where those real files live on disk, e.g. `{ dir = "../../dom/src/hydronium_dom/client", url_prefix = "js/bootstrap" }`. No default: an app that serves its own bootstrap JS some other way (a CDN, a bundler-owned path) is not forced to vendor anything.

--- @class HydroniumBalladSiteManifestOptions
--- @field name? string Default "hydronium-manifest". Both emitted files share this basename (`.json`/`.lua`).
--- @field mount? HydroniumBalladMountOptions|false Opt-in `index.html` shell emission (M4). Nil/absent: no index.html -- the safe default for e.g. an SSR example whose `hy_chunk` is fetched by a server-rendered route, not mounted from a static shell. A partiture that wants a complete, hostable static site (the SPA case) passes a table; `false` is the same as omitting it. Requires exactly one `hy_chunk` input asset with `metadata.hydronium.entry` set (client.bundle's `entry` option) -- zero means nothing to mount (silently skipped, since plenty of legitimate partitures merge no chunk at all through this node), more than one is an unresolvable ambiguity (which entry is "the" page?) and fails the build loudly rather than guessing.

--- Renders the mount() bootstrap `<script type="module">` this plugin's
--- `index.html` embeds. Kept separate from M.manifest for the same reason
--- serialize_lua_value is its own function: an isolated, unit-testable
--- string builder with no ballad/graph dependency of its own.
---
--- PUBLIC CONTRACT of the emitted page (fail loudly, not silently -- a
--- static SPA has no SSR fallback, so a mount error with nowhere to go
--- is a blank page and nothing else): once mount() settles, exactly one
--- of these is true --
---   window.__hydroniumMounted == true, __hydroniumMountError undefined: ok
---   window.__hydroniumMounted == true, __hydroniumMountError == "<message>": mount() rejected
--- A page never has to guess whether mounting is still in flight versus
--- silently stalled; `js/tests/spa_hash_demo.browser.test.mjs` polls this
--- exact contract against the real built shell.
--- @param chunk_urls string[] Already "/"-prefixed, in a stable (sorted) order.
--- @param app_module_id string
--- @param styles_url? string
--- @param opts HydroniumBalladMountOptions
--- @param manifest_url string
--- @return string html
local function render_index_html(chunk_urls, app_module_id, styles_url, opts, manifest_url)
  local title = opts.title or "Hydronium App"
  local container = opts.container or "#app"
  local container_id = container:gsub("^#", "")
  local js_bootstrap_url = opts.js_bootstrap_url or "/js/bootstrap/mount.js"

  local chunk_urls_js = {}
  for _, url in ipairs(chunk_urls) do
    chunk_urls_js[#chunk_urls_js + 1] = string.format("%q", url)
  end

  local extra_import, lua_globals_expr = "", "undefined"
  if opts.lua_globals then
    extra_import = "\n  import { " .. opts.lua_globals.import .. " } from "
      .. string.format("%q", opts.lua_globals.module) .. ";"
    lua_globals_expr = opts.lua_globals.import .. "()"
  end

  local style_link = ""
  if styles_url then
    style_link = "\n<link rel=\"stylesheet\" href=\"" .. styles_url .. "\">"
  end

  return table.concat({
    "<!doctype html>",
    "<html><head><meta charset=\"utf-8\"><title>" .. title .. "</title></head>",
    "<body>" .. style_link,
    "<div id=\"" .. container_id .. "\"></div>",
    "<script type=\"module\">",
    "  import { mount } from " .. string.format("%q", js_bootstrap_url) .. ";" .. extra_import,
    "",
    "  mount({",
    "    chunkUrls: [" .. table.concat(chunk_urls_js, ", ") .. "],",
    "    appModuleId: " .. string.format("%q", app_module_id) .. ",",
    "    container: " .. string.format("%q", container) .. ",",
    "    hydrate: " .. tostring(opts.hydrate == true) .. ",",
    "    assetManifestUrl: " .. string.format("%q", manifest_url) .. ",",
    "    luaGlobals: " .. lua_globals_expr .. ",",
    "  }).then(() => { window.__hydroniumMounted = true; })",
    "    .catch((e) => {",
    "      window.__hydroniumMountError = String((e && e.stack) || e);",
    "      window.__hydroniumMounted = true;",
    "      console.error(e);",
    "    });",
    "</script>",
    "</body></html>",
  }, "\n")
end

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
  local assets_map, styles_info, modules = {}, {}, {}
  -- M4: hy_chunk assets (client.bundle's output) are collected alongside
  -- the manifest's existing categories so a `mount` option can derive
  -- index.html's chunkUrls/appModuleId from the SAME data the manifest
  -- itself is built from, rather than re-deriving them a second way.
  local chunks = {}

  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      out:add(asset)
      local h = asset.metadata and asset.metadata.hydronium
      if h then
        if asset.kind == "hy_asset" and h.source then
          assets_map[h.source] = { url = h.url, integrity = h.integrity }
        elseif asset.kind == "hy_style_bundle" then
          styles_info = { url = h.url, sheet_count = h.sheet_count, reset = h.reset }
        elseif asset.kind == "hy_module" and h.module_id then
          modules[h.module_id] = {
            target = h.target,
            transform = h.transform or "lua",
            update = h.update or "restart",
            effects = h.effects or "restart",
            revision = h.revision,
          }
        elseif asset.kind == "hy_chunk" and asset.virtual_path then
          table.insert(chunks, { url = "/" .. asset.virtual_path, entry = h.entry })
        end
      end
    end
  end

  local manifest_table = {
    version = 1,
    assets = assets_map,
    styles = styles_info,
    modules = modules,
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

  -- M4: index.html, opt-in (see HydroniumBalladSiteManifestOptions.mount's
  -- own doc comment for why this is opt-in rather than automatic).
  if opts.mount and opts.mount ~= false then
    table.sort(chunks, function(a, b) return a.url < b.url end)
    local entry_chunks = {}
    for _, c in ipairs(chunks) do
      if c.entry then table.insert(entry_chunks, c) end
    end
    if #entry_chunks > 1 then
      ctx.fail("hydronium_ballad.plugins.site.manifest: mount was requested but " .. #entry_chunks
        .. " hy_chunk assets declare an entry (client.bundle's `entry` option) -- ambiguous which one "
        .. "is the mounted page. Give each its own site.manifest({ mount = ... }) node, or pass "
        .. "mount = false and build the shell(s) yourself.")
    elseif #entry_chunks == 1 then
      local chunk_urls = {}
      for _, c in ipairs(chunks) do chunk_urls[#chunk_urls + 1] = c.url end
      local manifest_url = opts.mount.asset_manifest_url or ("/" .. name .. ".lua")
      local html = render_index_html(chunk_urls, entry_chunks[1].entry,
        styles_info and styles_info.url, opts.mount, manifest_url)
      out:add(ctx.graph:add_asset({
        kind = "hy_index_html",
        generated = true,
        virtual_path = "index.html",
        content = html,
        metadata = { hydronium = { manifest = "site", format = "html" } },
      }))

      -- The shell above references js_bootstrap_url/lua_globals.module as
      -- absolute site paths; without this, they 404 on any host that only
      -- serves this sink's own output (verified for real: `python3 -m
      -- http.server` inside a build's dist/ 404s on both before this).
      if opts.mount.vendor then
        local fs = require("ballad.fs")
        local path = require("ballad.path")
        for _, v in ipairs(opts.mount.vendor) do
          if not v.dir or not v.url_prefix then
            ctx.fail("hydronium_ballad.plugins.site.manifest: mount.vendor entries need both `dir` and `url_prefix`")
          end
          local found = fs.list_files(v.dir)
          if #found == 0 then
            ctx.fail("hydronium_ballad.plugins.site.manifest: mount.vendor dir '" .. v.dir
              .. "' has no files -- refusing to silently ship an empty (or missing) directory "
              .. "that index.html depends on")
          end
          local prefix = (v.url_prefix:gsub("^/", ""):gsub("/$", ""))
          for _, source in ipairs(found) do
            local rel = path.relative(source, v.dir)
            out:add(ctx.graph:add_asset({
              kind = "file",
              source_path = source,
              virtual_path = path.join(prefix, rel),
            }))
          end
        end
      end
    end
    -- #entry_chunks == 0: nothing to mount. Not an error -- mount was
    -- requested but there is simply no hy_chunk input to this node run
    -- (e.g. a partiture that only ever produces styles/assets here).
  end

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
