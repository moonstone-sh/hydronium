--[[
  create.lab_starter -- the component Lab for the DOM templates (ssr,
  islands, spa), matching what `hydronium-lab init --renderer dom` installs:

    hydronium.lab.lua      renderer = "dom"; stories live in stories/,
                           components are required from src/
    stories/*.stories.luax a first story
    moonstone.toml         `lab` script, dev-role Lab packages, tool-role
                           launcher (+ Meteorite, if the template lacks it)
    README.md              how to run it

  Stories sit in their own root, not beside components: a story under an
  app source root would become a declared app module, and the dev-only
  hydronium_lab must never reach a production client bundle. The Ink
  template wires its own Lab (terminal renderer) and is not touched here.
]]
local M = {}

M.templates = { ssr = true, islands = true, spa = true }

M.LAB_SCRIPT = 'lab = "moon exec --dev -- hydronium-lab dev"'

-- Kept equal to each package's own version by create's release-floor gate.
local DEPENDENCIES = [==[

# Development-only component workbench (`moon run lab`): a separate loopback
# server. The application never imports these, so they stay out of its
# release closure.
[[dependencies]]
name = "hydronium/lab"
constraint = "^0.3.8"
role = "dev"

[[dependencies]]
name = "hydronium/ink-lab"
constraint = "^0.3.4"
role = "dev"

[[dependencies]]
name = "hydronium/meteorite"
constraint = "^0.3.8"
role = "dev"

[[dependencies]]
name = "hydronium/lab-cli"
constraint = "^0.3.3"
role = "tool"
]==]

local METEORITE_TOOL = [==[

[[dependencies]]
name = "moonstone/meteorite"
constraint = "^0.3.5"
role = "tool"
]==]

M.CONFIG = [[-- Component Lab (`moon run lab`). Stories are found under `roots`; the
-- components they require resolve from `module_roots` (and from
-- hydronium.sources.lua, when the project declares one).
return {
  renderer = "dom",
  roots = { "stories" },
  module_roots = { "src" },
}
]]

-- One story per page: the About page, which needs no server or router. Plain
-- Lua, so the project keeps its four .luax files.
local function about_story()
  return [[local lab = require("hydronium_lab")
local About = require("views.About")

return lab.collection({
  title = "About",
  renderer = "dom",
  component = About,
  stories = { default = {} },
})
]]
end

local README = [[

## Component Lab

A browser workbench for components, separate from the app: it starts its own
loopback server and is never part of the app's build.

```bash
moon run lab
```

Open the printed URL. Stories live in `stories/` (`*.stories.luax`,
`*.stories.lua`, `*.stories.md`, `*.stories.mdx`) and `require` components from
`src/` as the app does. Args are editable live, and saving a component
hot-updates the preview. `hydronium.lab.lua` configures the roots.
]]

--- Adds the Lab to a DOM template's files (no-op for other templates).
--- @param files table<string,string>
--- @param opts { template: string }
function M.apply(files, opts)
  if not M.templates[opts.template] then return files end
  local manifest = assert(files["moonstone.toml"], "create.lab_starter: template has no moonstone.toml")

  if manifest:find("\n%[scripts%]\n") then
    manifest = manifest:gsub("\n%[scripts%]\n", "\n[scripts]\n" .. M.LAB_SCRIPT .. "\n", 1)
  else
    manifest = manifest:gsub("\n*$", "") .. "\n\n[scripts]\n" .. M.LAB_SCRIPT .. "\n"
  end
  manifest = manifest:gsub("\n*$", "\n") .. DEPENDENCIES
  if not manifest:find('name = "moonstone/meteorite"', 1, true) then
    manifest = manifest .. METEORITE_TOOL
  end
  files["moonstone.toml"] = manifest

  files["hydronium.lab.lua"] = M.CONFIG
  files["stories/About.stories.lua"] = about_story()
  files["README.md"] = (files["README.md"] or "") .. README
  return files
end

return M
