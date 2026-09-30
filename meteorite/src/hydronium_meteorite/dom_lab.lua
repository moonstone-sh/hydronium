-- Browser source closure. HTTP inputs never select filesystem paths.
local discovery = require("hydronium_lab.discovery")
local M = {}
local function read(path)
  local file, err = io.open(path, "rb")
  if not file then error(err, 0) end
  local source = file:read("*a"); file:close(); return source
end
-- The same literal-require scan Ballad bundles with and the dev framework
-- manifest uses (hydronium.core.require_scan): it may over-include, never miss.
local function requires(source)
  return require("hydronium.core.require_scan").literal_requires(source)
end
local function compile(path, id)
  local source = read(path)
  if path:match("%.luax$") then
    source = require("hydronium_luax").compile(source, { filename = path, development = true }).code
  elseif path:match("%.mdx?$") then
    source = require("hydronium_luax").compile_markdown(source, { filename = path, development = true }).code
  end
  local chunk, err = (loadstring or load)(source, "@" .. id)
  if not chunk then error(err, 0) end
  return source
end
function M.sources(config, registry)
  local sources, seen, project = {}, {}, {}
  local records = discovery.plan(config.paths, { roots = config.roots })
  local entries = {}
  for index, record in ipairs(records) do
    local include = false
    for _, story in ipairs(registry.stories) do if story.renderer == "dom" and story.source.path == record.path then include = true end end
    if include then
    local id = "hydronium_lab.story_" .. index
    -- Normalize collections inside the module so a component re-export cannot
    -- steal the original component module's HMR family identity.
    sources[id] = string.format("return require('hydronium_lab.discovery').bind({path=%q,id_prefix=%q,stem=%q},(function()\n%s\nend)())", record.path, record.id_prefix, record.stem, compile(record.path, id))
    project[id] = true
    entries[#entries + 1] = string.format("(require(%q))", id)
  end
    end
  sources["hydronium_lab.dom_stories"] = "return require('hydronium_lab').registry({" .. table.concat(entries, ",") .. "})"
  sources["hydronium_lab.dom_entry"] = "__luax = require('hydronium_luax.runtime'); return require('hydronium_lab.dom_preview').App"
  project["hydronium_lab.dom_stories"] = true
  -- The project's declared source topology (hydronium.sources.lua or Ballad's
  -- inventory) resolves namespaced ids like `ui.Button` -> src/components/Button.luax
  -- exactly as the app's dev host does; module_roots stays the fallback for
  -- projects without one.
  local topology = require("hydronium_dom.dev.source_registry").try_load_project()
  local function resolve(id)
    local record = topology and topology:module(id)
    if record then project[id] = true; return record.path end
    local mapped = id:gsub("%.", "/")
    for _, root in ipairs(config.module_roots or config.roots or { "src" }) do
      for _, suffix in ipairs({ ".lua", ".luax", ".md", ".mdx", "/init.lua", "/init.luax", "/init.md", "/init.mdx" }) do
        local path = root .. "/" .. mapped .. suffix
        local f = io.open(path, "rb")
        if f then f:close(); project[id] = true; return path end
      end
    end
    return package.searchpath(id, package.path)
  end
  local function visit(id)
    if seen[id] then return end
    seen[id] = true
    if not sources[id] then
      local path = resolve(id)
      -- Optional runtime probes (e.g. bit) may use browser built-ins instead.
      if not path then return end
      sources[id] = compile(path, id)
    end
    for _, dependency in ipairs(requires(sources[id])) do visit(dependency) end
  end
  visit("hydronium_lab.dom_entry")
  visit("hydronium_dom.host.dom")
  visit("hydronium_dom")
  visit("hydronium.core.hmr")
  visit("hydronium.runtime.hosts")
  visit("hydronium_lab.dom_stories")
  return sources, project
end
function M.bundle(sources)
  local ids, lines = {}, {}
  for id in pairs(sources) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    lines[#lines + 1] = string.format("package.preload[%q]=(loadstring or load)(%q,%q)", id, sources[id], "@" .. id)
  end
  return table.concat(lines, "\n")
end
M.requires = requires
return M
