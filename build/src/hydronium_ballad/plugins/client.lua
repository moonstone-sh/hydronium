--[[
  hydronium_ballad.plugins.client -- module resolution and amalgamation
  for the WASM (wasmoon) browser runtime.

  M1: `resolve` (real static require-graph resolution) + `bundle` (real
  amalgamation into ONE `hy_chunk`, `format = "package_preload_v1"`).
  M2: `minify` -- a real, lexer-based, string-literal-preserving "safe"
  minifier (whitespace/comments only -- no renaming, no folding, no tree
  shaking; see this file's own `minify_source` doc comment and
  docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md's §4 for the full
  rationale). Runs BEFORE `bundle` in a real pipeline (per-module, on the
  `hy_module` AssetSet `resolve()` produces), not after -- minifying
  whole already-concatenated chunks would make the mandatory per-module
  `load()` gate below unable to name which single module actually broke.

  See that same doc for the full rationale behind every non-obvious
  choice below (Form B chunk encoding vs. inline closures, the two
  amalgamation hazards, why `resolve` is cacheable=false, etc.) -- this
  file's comments summarize, not repeat, that design doc.
--]]

local graph = require("ballad.graph")
local process = require("ballad.process")

local M = {}

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then
    error("hydronium_ballad.plugins.client: cannot read " .. tostring(path) .. ": " .. tostring(err), 0)
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- @param compiled_virtual_path string Ends in ".lua".
--- @return string
local function module_id_from_virtual_path(compiled_virtual_path)
  local without_ext = compiled_virtual_path:gsub("%.lua$", "")
  return (without_ext:gsub("/", "."))
end

--- Normalizes either a `hy_module` asset (from plugins.luax.compile) or a
--- plain `kind = "file"` `.lua` asset (e.g. the framework's own runtime
--- source, fed in directly by the partiture with no compile step) into
--- one common shape. This is a deliberate, load-bearing design choice:
--- the client bundle needs BOTH the app's own compiled .luax output AND
--- hydronium's plain-.lua framework modules in the same module graph,
--- and only the former ever passes through plugins.luax.compile.
--- @param asset Asset
--- @return { module_id: string, origin: string, target: string, content: string, sourcemap: string|nil }|nil
local function normalize_module_asset(asset)
  local vpath = asset.virtual_path
  if not vpath or not vpath:match("%.lua$") then
    return nil
  end
  local h = asset.metadata and asset.metadata.hydronium
  local content = asset.content
  if not content and asset.source_path then
    content = read_file(asset.source_path)
  end
  if not content then
    return nil
  end
  return {
    module_id = (h and h.module_id) or module_id_from_virtual_path(vpath),
    origin = (h and h.origin) or asset.source_path or vpath,
    target = (h and h.target) or "shared",
    content = content,
    sourcemap = h and h.sourcemap or nil,
  }
end

--- Static scan for `require("<literal>")` / `require '<literal>'` /
--- `require "<literal>"` call sites. Deliberately NOT a real Lua parse --
--- this is the same class of technique dom/tools/gen_client_manifest.lua
--- already uses (there: tracing real execution; here: scanning compiled
--- source text without executing it, since a build step must not run
--- application code). Misses computed requires (this codebase has
--- exactly one, dom/src/hydronium_dom/server/init.lua's lazy meteorite
--- adapter behind an __index metamethod -- server-side, outside the
--- client graph today). gen_client_manifest.lua remains the verification
--- oracle for this gap (see docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md's G3).
--- @param source string
--- @return string[]
local function scan_requires(source)
  local ids, seen, order = {}, {}, {}
  local function add(id)
    if id and not seen[id] then
      seen[id] = true
      table.insert(order, id)
    end
  end
  for id in source:gmatch("require%s*%(%s*[\"']([%w_%.]+)[\"']%s*%)") do
    add(id)
  end
  for id in source:gmatch("require%s*[\"']([%w_%.]+)[\"']") do
    add(id)
  end
  return order
end

-- mount.js's own final bootstrap script `require()`s these four modules
-- DIRECTLY, itself -- independent of whatever the app's own root
-- component happens to require. They are NOT reachable by walking from
-- the app's entry module alone (found live: a real Playwright run with
-- `entries = {"App"}` only produced a bundle missing
-- hydronium_dom.host.dom entirely, since nothing in App's own transitive
-- require graph ever mentions it -- mount.js requires it directly,
-- orthogonal to app content). Always included so a partiture author
-- doesn't have to know mount.js's own internals to get a working bundle;
-- see docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md and mount.js's own
-- final `lua.doString` block for the real, current list this must track.
local MOUNT_BOOTSTRAP_ENTRIES = {
  "hydronium",
  "hydronium.core.element",
  "hydronium_dom",
  "hydronium_dom.host.dom",
  "hydronium.core.reconciler",
}

--- @class HydroniumBalladResolveOptions
--- @field entries string[] REQUIRED. Module ids to walk from (the app's own root component, typically). `MOUNT_BOOTSTRAP_ENTRIES` above is always added on top of these, automatically.
--- @field include? string[] Which `metadata.hydronium.target` values to consider. Default `{"client","shared"}`.
--- @field deny_getinfo? boolean Refuse (ctx.fail) any reachable module whose source uses `debug.getinfo` for self-location -- amalgamation changes chunknames, breaking that pattern. Default true.

--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts HydroniumBalladResolveOptions
--- @return AssetSet
function M.resolve(ctx, inputs, opts)
  opts = opts or {}
  local app_entries = opts.entries
  if not app_entries or #app_entries == 0 then
    ctx.fail("hydronium_ballad.plugins.client.resolve: opts.entries is required (a list of module ids to walk from)")
  end
  local entries = {}
  for _, id in ipairs(MOUNT_BOOTSTRAP_ENTRIES) do
    table.insert(entries, id)
  end
  for _, id in ipairs(app_entries) do
    table.insert(entries, id)
  end

  local include = {}
  for _, t in ipairs(opts.include or { "client", "shared" }) do
    include[t] = true
  end
  local deny_getinfo = opts.deny_getinfo
  if deny_getinfo == nil then
    deny_getinfo = true
  end

  local by_id = {}
  -- init_alias_target[base] = "base.init" for every module whose OWN id
  -- ends in ".init" -- e.g. hydronium/init.lua's real module_id is
  -- "hydronium.init", but application code writes `require("hydronium")`.
  -- package.preload has no ?.lua/?/init.lua equivalence (unlike
  -- package.path), so the bundle must synthesize this alias itself. See
  -- docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md's "Hazard 1."
  local init_alias_target = {}
  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      local norm = normalize_module_asset(asset)
      if norm and include[norm.target] then
        if by_id[norm.module_id] and by_id[norm.module_id].content ~= norm.content then
          ctx.warn("hydronium_ballad.plugins.client.resolve: module '" .. norm.module_id
            .. "' provided more than once with different content -- keeping the first one seen")
        end
        by_id[norm.module_id] = by_id[norm.module_id] or norm
        local base = norm.module_id:match("^(.*)%.init$")
        if base and not init_alias_target[base] then
          init_alias_target[base] = norm.module_id
        end
      end
    end
  end

  local order, seen, aliases = {}, {}, {}

  --- Resolves the requested require() id to the real module id it should
  --- be emitted under -- either directly (by_id has it) or via the
  --- ".init" alias above. Returns nil if truly not found.
  local function resolve_real_id(id)
    if by_id[id] then
      return id
    end
    local alias_target = init_alias_target[id]
    if alias_target then
      aliases[id] = alias_target
      return alias_target
    end
    return nil
  end

  local function visit(id)
    local real_id = resolve_real_id(id)
    if not real_id then
      if not seen[id] then
        seen[id] = true
        ctx.warn("hydronium_ballad.plugins.client.resolve: module '" .. id
          .. "' not found in the provided asset set -- it will not be bundled")
      end
      return
    end
    if seen[real_id] then
      return
    end
    seen[real_id] = true
    local mod = by_id[real_id]
    if deny_getinfo and mod.content:find("debug%.getinfo", 1, true) then
      ctx.fail("hydronium_ballad.plugins.client.resolve: module '" .. real_id
        .. "' (" .. mod.origin .. ") uses debug.getinfo for self-location and cannot be safely "
        .. "amalgamated -- amalgamation changes its chunkname, breaking whatever path it derives "
        .. "from debug.getinfo(1,\"S\").source. See docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md 'Hazard 2'.")
    end
    table.insert(order, real_id)
    for _, req_id in ipairs(scan_requires(mod.content)) do
      visit(req_id)
    end
  end

  for _, entry_id in ipairs(entries) do
    visit(entry_id)
  end

  table.sort(order)

  local out = graph.AssetSet.new()
  for _, id in ipairs(order) do
    local mod = by_id[id]
    out:add(ctx.graph:add_asset({
      kind = "hy_module",
      generated = true,
      virtual_path = id:gsub("%.", "/") .. ".lua",
      content = mod.content,
      metadata = { hydronium = {
        module_id = id,
        origin = mod.origin,
        target = mod.target,
        sourcemap = mod.sourcemap,
      }},
    }))
  end

  -- hy_module_graph: a canonical, deterministic serialization of the
  -- whole resolution result (sorted module ids, entries, aliases). Its
  -- CONTENT is what makes bundle()/minify() safe to mark cacheable=true
  -- despite ballad never hashing Asset.metadata -- any join-key change
  -- (e.g. a partiture flipping a module's `target`) changes this asset's
  -- content, which IS hashed, and therefore changes bundle's cache key
  -- transitively. See the bundler plan's §3 for the full reasoning.
  local dkjson = require("dkjson")
  local sorted_aliases = {}
  for base, real in pairs(aliases) do
    table.insert(sorted_aliases, { base = base, real = real })
  end
  table.sort(sorted_aliases, function(a, b) return a.base < b.base end)
  local graph_json = dkjson.encode({
    entries = entries,
    modules = order,
    aliases = sorted_aliases,
  }, { indent = false })

  out:add(ctx.graph:add_asset({
    kind = "hy_module_graph",
    generated = true,
    content = graph_json,
    metadata = { hydronium = { entries = entries, aliases = aliases } },
  }))

  return out
end

--- Computes the minimum long-bracket level (number of `=` signs) that is
--- guaranteed not to prematurely close when wrapping `content`.
---
--- Two real subtleties, both found by a failing build rather than by
--- reading (see this file's own history):
---
--- 1. **The scan must allow OVERLAPPING matches.** `gmatch` resumes after
---    the end of each match, so on `]]=]` it finds `]]` (level 0) and then
---    resumes past the middle `]`, never seeing the longer `]=]` that
---    starts there -- yielding level 1 and a chunk that closes early.
---    A `find`-with-`init = start + 1` loop sees every candidate.
---
--- 2. **The closing delimiter's own leading `]` must be accounted for.**
---    The emitted text is `content .. "]" .. eq .. "]"`, so a `content`
---    ENDING in `]` (plus any run of `=`) forms a premature closer
---    together with the closer's own first `]`. Scanning `content .. "]"`
---    instead of bare `content` covers exactly that adjacency. Real and
---    reachable: any source file with no trailing newline whose last
---    character is `]` (e.g. `return t["n"]`) previously produced a chunk
---    that failed to parse -- silently, since `bundle` writes the chunk
---    without ever `load()`ing it, so the break only surfaced in the
---    browser.
--- @param content string
--- @return integer
local function long_bracket_level(content)
  local max_len = -1
  -- The trailing "]" stands in for the closing delimiter's own first
  -- character; see subtlety 2 above.
  local haystack = content .. "]"
  local init = 1
  while true do
    local s, _, eqs = haystack:find("%](=*)%]", init)
    if not s then
      break
    end
    if #eqs > max_len then
      max_len = #eqs
    end
    init = s + 1 -- overlapping scan; see subtlety 1 above
  end
  return max_len + 1
end

--- @param module_id string
--- @param content string
--- @return string
local function wrap_module_source(module_id, content)
  local level = long_bracket_level(content)
  local eq = string.rep("=", level)
  return string.format("S[%q] = [%s[\n%s]%s]\n", module_id, eq, content, eq)
end

--- Emits real Lua source implementing `format = "package_preload_v1"`
--- (see docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md §2): a chunk that,
--- when `load()`ed and called, installs `package.preload[id]` for every
--- module it carries (Form B: a deferred `load()` of the raw module
--- source held in a long-bracket string, NOT an inlined nested closure --
--- this preserves real module chunknames/line numbers in stack traces
--- and keeps each module's own sourcemap valid with zero remapping).
--- @param modules { module_id: string, content: string }[] Already sorted by module_id.
--- @param aliases table<string, string> base module id -> real (".init") module id.
--- @return string
local function build_chunk_source(modules, aliases)
  local buf = {}
  table.insert(buf, "local _load = loadstring or load")
  table.insert(buf, "local _assert, _pairs, _require, _preload = assert, pairs, require, package.preload")
  table.insert(buf, "local S, A = {}, {}")
  table.insert(buf, "")
  for _, mod in ipairs(modules) do
    table.insert(buf, wrap_module_source(mod.module_id, mod.content))
  end
  local sorted_aliases = {}
  for base, real in pairs(aliases) do
    table.insert(sorted_aliases, { base = base, real = real })
  end
  table.sort(sorted_aliases, function(a, b) return a.base < b.base end)
  for _, a in ipairs(sorted_aliases) do
    table.insert(buf, string.format("A[%q] = %q", a.base, a.real))
  end
  table.insert(buf, "")
  table.insert(buf, "for id, src in _pairs(S) do")
  table.insert(buf, "  _preload[id] = function(...) return _assert(_load(src, \"@\" .. id))(...) end")
  table.insert(buf, "end")
  table.insert(buf, "for a, id in _pairs(A) do")
  table.insert(buf, "  _preload[a] = function() return _require(id) end")
  table.insert(buf, "end")
  return table.concat(buf, "\n") .. "\n"
end

--- Mandatory, unconditional gate on every emitted chunk: a chunk that
--- does not even PARSE is a build failure, not a runtime surprise in a
--- browser with no Lua devtools. This is the chunk-level counterpart to
--- `minify`'s existing per-module `load()` gate -- and it is the gate
--- that was missing when a module source ending in `]` produced a
--- silently unloadable chunk (see `long_bracket_level`'s doc comment).
---
--- Dialect-independent by construction, so it cannot false-positive on
--- module code targeting a different Lua version than the build host:
--- the chunk body is only the fixed `package.preload` harness plus each
--- module's source held inside a LONG STRING, so whether it parses
--- depends on the harness and the bracket levels, never on any module's
--- own syntax.
--- @param ctx PluginCtx
--- @param chunk_id string
--- @param body string
local function assert_chunk_loads(ctx, chunk_id, body)
  local loader, load_err = load(body, "@" .. chunk_id)
  if not loader then
    ctx.fail("hydronium_ballad.plugins.client.bundle: the emitted chunk '" .. tostring(chunk_id)
      .. "' does not parse: " .. tostring(load_err)
      .. " -- this is a real bug in the chunk encoder (build_chunk_source/long_bracket_level), "
      .. "not in any one module's own source")
  end
end

--- @param hash string
--- @return string
local function require_real_hash(ctx, hash)
  if hash == "" then
    ctx.fail("hydronium_ballad.plugins.client.bundle: b3sum is not available -- ballad's own cache "
      .. "silently degrades without it (see docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md §8); "
      .. "this plugin refuses to proceed rather than emit an unhashed chunk URL")
  end
  return hash
end

--- @class HydroniumBalladBundleOptions
--- @field shared_chunk_id? string Default "runtime".
--- @field hash_length? integer Default 8.
--- @field chunk_prefix? string Default "client/". Prefixed onto the emitted chunk's virtual_path (its public URL).
--- @field entry? string `split="none"` only: module id to record as this chunk's `metadata.hydronium.entry`.
--- @field split? "none"|"entry" Default "none" (one chunk containing every resolved module -- M1/M2 behavior, unchanged). "entry": real code-splitting -- see `bundle_split` below for the real, load-bearing requirement this places on the CALLER (multiple `resolve()` outputs, not one combined set).
--- @field entry_names? string[] REQUIRED when `split="entry"`.
--- @field shared_roots? string[] `split="entry"` only. Module-id prefixes always pinned into the shared chunk regardless of refcount. Default `{"hydronium.", "hydronium_dom."}` -- this is what gives the real cross-page cache-reuse win even on a single-entry site (see the bundler plan's §5.2).

--- Single-chunk bundling (M1/M2 behavior, `split="none"`, the default):
--- every resolved module goes into exactly ONE chunk.
--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts HydroniumBalladBundleOptions
--- @return AssetSet
local function bundle_single(ctx, inputs, opts)
  local chunk_id = opts.shared_chunk_id or "runtime"
  local hash_length = opts.hash_length or 8
  local chunk_prefix = opts.chunk_prefix or "client/"

  local modules, module_ids, aliases = {}, {}, {}
  local any_minified, any_unminified = false, false
  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      if asset.kind == "hy_module" then
        local h = asset.metadata and asset.metadata.hydronium
        local id = h and h.module_id
        if id then
          table.insert(modules, { module_id = id, content = asset.content })
          table.insert(module_ids, id)
          if h and h.minified then
            any_minified = true
          else
            any_unminified = true
          end
        end
      elseif asset.kind == "hy_module_graph" then
        local h = asset.metadata and asset.metadata.hydronium
        if h and h.aliases then
          for base, real in pairs(h.aliases) do
            aliases[base] = real
          end
        end
      end
    end
  end

  if #modules == 0 then
    ctx.fail("hydronium_ballad.plugins.client.bundle: no hy_module assets in the input -- did resolve() run first?")
  end
  if any_minified and any_unminified then
    ctx.warn("hydronium_ballad.plugins.client.bundle: mixing minified and unminified modules in one chunk -- "
      .. "did minify() only run on part of the input? Chunk metadata.hydronium.minified reflects the majority case only.")
  end

  table.sort(modules, function(a, b) return a.module_id < b.module_id end)
  table.sort(module_ids)

  local body = build_chunk_source(modules, aliases)
  assert_chunk_loads(ctx, chunk_id, body)
  local hash = require_real_hash(ctx, process.b3sum_string(body))
  local short_hash = hash:sub(1, hash_length)
  local vpath = chunk_prefix .. chunk_id .. "-" .. short_hash .. ".lua"

  local out = graph.AssetSet.new()
  out:add(ctx.graph:add_asset({
    kind = "hy_chunk",
    generated = true,
    virtual_path = vpath,
    content = body,
    metadata = { hydronium = {
      chunk_id = chunk_id,
      module_ids = module_ids,
      entry = opts.entry,
      requires = {},
      minified = any_minified,
      format = "package_preload_v1",
    }},
  }))
  return out
end

--- @param name string
--- @return string
local function sanitize_chunk_id(name)
  return (tostring(name):gsub("[^%w_%-]", "_"))
end

--- Real code-splitting (M3), anchored on real per-entry reachability --
--- NOT anything this function can compute from a single flat module set
--- (that information is already lost once resolve() merges everything
--- into one AssetSet). The load-bearing requirement this places on the
--- CALLER: `inputs` must be MULTIPLE separate resolve() outputs, one per
--- real entry point, fed in via `depends_on` -- e.g.
---   local r1 = client.resolve(compiled, { entries = {"App1"} })
---   local r2 = client.resolve(compiled, { entries = {"App2"}, depends_on = { r1 } })
---   client.bundle(r2, { split = "entry", entry_names = {"App1", "App2"} })
--- (both r1/r2 already include MOUNT_BOOTSTRAP_ENTRIES automatically, so
--- shared framework modules appear in every one of them, in inputs[1],
--- inputs[2], etc. -- exactly what makes the refcount below correct: a
--- module is only "shared" because it was actually reachable from ≥2
--- real entries' own resolve() calls, not by assumption.) See the
--- bundler plan's §5.2/§5.3 for the algorithm and its stated coupling
--- risk (this whole approach depends on the caller supplying real
--- per-entry resolve() outputs -- there is no way for bundle() itself to
--- recover per-entry reachability from an already-merged set).
--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts HydroniumBalladBundleOptions
--- @return AssetSet
local function bundle_split(ctx, inputs, opts)
  local entry_names = opts.entry_names
  if not entry_names or #entry_names ~= #inputs then
    ctx.fail("hydronium_ballad.plugins.client.bundle: split=\"entry\" requires opts.entry_names with exactly "
      .. "one name per input AssetSet (got " .. tostring(entry_names and #entry_names or 0)
      .. " name(s) for " .. #inputs .. " input(s) -- see bundle_split's own doc comment for the expected shape)")
  end

  local shared_roots = opts.shared_roots or { "hydronium.", "hydronium_dom." }
  local hash_length = opts.hash_length or 8
  local chunk_prefix = opts.chunk_prefix or "client/"
  local shared_chunk_id = opts.shared_chunk_id or "runtime"

  -- module_id -> { content, minified, entry_indices = { [input_index]=true, ... } }
  local modules, module_order, aliases = {}, {}, {}

  for idx, input_set in ipairs(inputs) do
    for _, asset in ipairs(input_set.assets) do
      if asset.kind == "hy_module" then
        local h = asset.metadata and asset.metadata.hydronium
        local id = h and h.module_id
        if id then
          if not modules[id] then
            modules[id] = { content = asset.content, minified = h.minified, entry_indices = {} }
            table.insert(module_order, id)
          end
          modules[id].entry_indices[idx] = true
        end
      elseif asset.kind == "hy_module_graph" then
        local h = asset.metadata and asset.metadata.hydronium
        if h and h.aliases then
          for base, real in pairs(h.aliases) do
            aliases[base] = real
          end
        end
      end
    end
  end

  if #module_order == 0 then
    ctx.fail("hydronium_ballad.plugins.client.bundle: no hy_module assets in the input -- did resolve() run first?")
  end
  table.sort(module_order)

  local function is_shared_root(id)
    for _, prefix in ipairs(shared_roots) do
      if id:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end

  local shared_modules = {}
  local per_entry_modules = {}
  for i = 1, #inputs do
    per_entry_modules[i] = {}
  end

  for _, id in ipairs(module_order) do
    local mod = modules[id]
    local distinct_count = 0
    local sole_idx = nil
    for idx in pairs(mod.entry_indices) do
      distinct_count = distinct_count + 1
      sole_idx = idx
    end
    if is_shared_root(id) or distinct_count >= 2 then
      table.insert(shared_modules, { module_id = id, content = mod.content })
    else
      table.insert(per_entry_modules[sole_idx], { module_id = id, content = mod.content })
    end
  end

  local out = graph.AssetSet.new()
  local shared_emitted = false

  local function emit_chunk(chunk_id, chunk_modules, chunk_aliases, entry_id, requires)
    table.sort(chunk_modules, function(a, b) return a.module_id < b.module_id end)
    local module_ids = {}
    for _, m in ipairs(chunk_modules) do
      table.insert(module_ids, m.module_id)
    end
    local body = build_chunk_source(chunk_modules, chunk_aliases or {})
    assert_chunk_loads(ctx, chunk_id, body)
    local hash = require_real_hash(ctx, process.b3sum_string(body))
    local vpath = chunk_prefix .. chunk_id .. "-" .. hash:sub(1, hash_length) .. ".lua"
    out:add(ctx.graph:add_asset({
      kind = "hy_chunk",
      generated = true,
      virtual_path = vpath,
      content = body,
      metadata = { hydronium = {
        chunk_id = chunk_id,
        module_ids = module_ids,
        entry = entry_id,
        requires = requires or {},
        minified = chunk_modules[1] and modules[chunk_modules[1].module_id].minified or false,
        format = "package_preload_v1",
      }},
    }))
  end

  if #shared_modules > 0 then
    emit_chunk(shared_chunk_id, shared_modules, aliases, nil, {})
    shared_emitted = true
  end

  local shared_requires = shared_emitted and { shared_chunk_id } or {}
  for i, name in ipairs(entry_names) do
    local mods = per_entry_modules[i]
    if #mods > 0 then
      -- Aliases whose real target lives in a per-entry chunk (not the
      -- shared one) are real but rare (only if that target itself
      -- somehow isn't a shared_root and is reachable from exactly this
      -- one entry) -- include the full alias table here too, harmless
      -- when unused (an alias loader is lazy, only calling `require` if
      -- something actually asks for that base name).
      emit_chunk("entry-" .. sanitize_chunk_id(name), mods, aliases, name, shared_requires)
    end
  end

  return out
end

--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts HydroniumBalladBundleOptions
--- @return AssetSet
function M.bundle(ctx, inputs, opts)
  opts = opts or {}
  if opts.split == "entry" then
    return bundle_split(ctx, inputs, opts)
  end
  return bundle_single(ctx, inputs, opts)
end

--- Merges a run of consecutive WHITESPACE/COMMENT tokens' raw text into
--- a single, minimal separator: the same number of real newlines the run
--- actually contained (so line numbers -- and therefore `map_json`
--- sourcemaps -- stay exactly valid), or one space if it contained none
--- at all (so two tokens that were never adjacent in the original source
--- never get silently glued together). NEVER touches a STRING or COMMENT
--- token's own value when that token isn't trivia (a real Lua comment
--- IS trivia and IS stripped down to its newlines -- separate from the
--- hard invariant below, which is about STRING tokens specifically).
--- @param count integer Number of "\n" characters found in the run.
--- @param preserve_lines boolean
--- @return string
local function trivia_separator(count, preserve_lines)
  if preserve_lines and count > 0 then
    return string.rep("\n", count)
  end
  if count > 0 then
    return "\n"
  end
  return " "
end

--- A real, lexer-based Lua minifier: strips comments and collapses
--- whitespace, nothing else. HARD INVARIANT, non-negotiable (see
--- docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md §4.1): never alters,
--- renames, re-quotes, or otherwise touches the CONTENTS of any STRING
--- token -- `luax.compile` mints CSS scope-class literals (e.g.
--- "hy-App-1a2b") as plain string constants, and this codebase's own
--- Lua-5.1-vs-5.4 compat shims (`local unpack = table.unpack or
--- unpack`) depend on file-scope locals shadowing same-named globals,
--- which a renaming pass could break -- so this function does not
--- rename ANY identifier either, local or otherwise. Sound on real Lua
--- source specifically because `hydronium_luax.lexer`'s `read_string`/
--- `read_comment` store the RAW source text (including string
--- delimiters) as each token's `.value` -- emitting `tok.value` verbatim
--- for every non-trivia token satisfies the invariant BY CONSTRUCTION,
--- not by configuration.
--- @param source string Real Lua source (a plain superset-compatible
---   subset of what the .luax lexer accepts -- verified against every
---   real .lua file in this workspace, see the bundler plan's §0 ledger).
--- @param preserve_lines boolean
--- @return string
local function minify_source(source, preserve_lines)
  local lexer = require("hydronium_luax.lexer")
  local tokens = lexer.tokenize(source, "@minify", { include_whitespace = true })

  local function is_trivia(tok)
    return tok.type == "WHITESPACE" or tok.type == "COMMENT"
  end

  local out = {}
  local i, n = 1, #tokens
  while i <= n do
    local tok = tokens[i]
    if tok.type == "EOF" then
      break
    end
    if is_trivia(tok) then
      local newline_count = 0
      local j = i
      while j <= n and is_trivia(tokens[j]) do
        local _, count = tokens[j].value:gsub("\n", "")
        newline_count = newline_count + count
        j = j + 1
      end
      table.insert(out, trivia_separator(newline_count, preserve_lines))
      i = j
    else
      table.insert(out, tok.value)
      i = i + 1
    end
  end
  return table.concat(out)
end

--- @class HydroniumBalladMinifyOptions
--- @field level? "none"|"safe" Default "none" (passthrough -- explicit opt-in required). "safe" strips comments/whitespace only; see minify_source's own doc comment for the full, permanent scope limit (no renaming, no folding, no tree shaking, ever).
--- @field preserve_lines? boolean Default true. Keeps every module's own line numbers (and therefore its `map_json` sourcemap) exactly valid, at a real but small (~1-3%) size cost vs. collapsing every trivia run to one newline.

--- Operates on `hy_module` assets (BEFORE bundle(), not after -- see this
--- file's own top doc comment for why bundling first would make the
--- mandatory per-module `load()` gate below unable to name which single
--- module actually broke). Passes non-`hy_module` assets (e.g.
--- `hy_module_graph`) through untouched.
--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts HydroniumBalladMinifyOptions
--- @return AssetSet
function M.minify(ctx, inputs, opts)
  opts = opts or {}
  local level = opts.level or "none"
  local preserve_lines = opts.preserve_lines
  if preserve_lines == nil then
    preserve_lines = true
  end
  if level ~= "none" and level ~= "safe" then
    ctx.fail("hydronium_ballad.plugins.client.minify: unknown level '" .. tostring(level)
      .. "' -- only \"none\" and \"safe\" are implemented (see docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md §4.3 "
      .. "for why more aggressive levels are deliberately out of scope)")
  end

  local out = graph.AssetSet.new()
  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      if asset.kind ~= "hy_module" or level == "none" then
        out:add(asset)
      else
        local h = asset.metadata and asset.metadata.hydronium or {}
        local minified = minify_source(asset.content, preserve_lines)

        -- Mandatory, unconditional gate: minified output that fails to
        -- even parse is a build failure, named precisely, not a runtime
        -- surprise in a browser with no Lua devtools. Cheap (microseconds).
        local loader, load_err = load(minified, "@" .. tostring(h.module_id or asset.virtual_path))
        if not loader then
          ctx.fail("hydronium_ballad.plugins.client.minify: minified output for module '"
            .. tostring(h.module_id) .. "' failed to parse: " .. tostring(load_err)
            .. " -- this is a real bug in minify_source, not the original module")
        end

        out:add(ctx.graph:add_asset({
          kind = "hy_module",
          generated = true,
          virtual_path = asset.virtual_path,
          content = minified,
          metadata = { hydronium = {
            module_id = h.module_id,
            origin = h.origin,
            target = h.target,
            sourcemap = h.sourcemap,
            minified = true,
          }},
        }))
      end
    end
  end
  return out
end

return {
  name = "hydronium_ballad.plugins.client",
  version = "0.1.0",
  methods = {
    -- cacheable=false: ballad's cache key hashes Asset content, never
    -- Asset.metadata -- and every join key resolve() depends on
    -- (module_id/target/origin) lives in metadata. A metadata-only change
    -- (e.g. flipping a module's target) would silently produce a stale
    -- cache hit if this were cacheable. See the bundler plan's §3.
    resolve = { inputs = { "asset_set" }, outputs = { "asset_set" }, cacheable = false, parallel_safe = true },
    -- cacheable=true is safe: minify_source is a pure function of
    -- content plus opts (level/preserve_lines, both plain data -- see
    -- ballad's own serialize() rejecting function-valued options).
    minify = { inputs = { "asset_set" }, outputs = { "asset_set" }, cacheable = true, parallel_safe = true },
    -- cacheable=true is safe here ONLY because resolve() emits the
    -- hy_module_graph asset above, whose content transitively captures
    -- everything that determines bundle()'s output.
    bundle = { inputs = { "asset_set" }, outputs = { "asset_set" }, cacheable = true, parallel_safe = true },
  },
  resolve = M.resolve,
  minify = M.minify,
  bundle = M.bundle,
}
