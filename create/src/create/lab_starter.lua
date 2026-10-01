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
constraint = "^0.3.4"
role = "dev"

[[dependencies]]
name = "hydronium/ink-lab"
constraint = "^0.3.3"
role = "dev"

[[dependencies]]
name = "hydronium/meteorite"
constraint = "^0.3.4"
role = "dev"

[[dependencies]]
name = "hydronium/lab-cli"
constraint = "^0.3.2"
role = "tool"
]==]

local METEORITE_TOOL = [==[

[[dependencies]]
name = "moonstone/meteorite"
constraint = "^0.3.1"
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

-- A small presentational component for templates without one of their own.
M.WELCOME = [[-- A starter component for the Lab: edit it, or require your own components
-- from stories/ the same way.
local H = require("hydronium")
local d = require("hydronium_dom").d

local function Welcome(props)
  return (
    <d.section class="welcome">
      <d.h2>{props.title or "Welcome"}</d.h2>
      <d.p>{props.message or ""}</d.p>
    </d.section>
  )
end

return Welcome
]]

local function welcome_story()
  return [[local lab = require("hydronium_lab")
local Welcome = require("components.Welcome")

-- Each story renders the component with its args; the controls edit them live.
return lab.collection({
  title = "Welcome",
  renderer = "dom",
  component = Welcome,
  args = { title = "Welcome", message = "Rendered by the Hydronium Lab." },
  controls = { title = { type = "text" }, message = { type = "text" } },
  stories = {
    default = {},
    empty = { args = { message = "" } },
  },
})
]]
end

local function counter_story()
  return [[local lab = require("hydronium_lab")
local Counter = require("views.Counter")

-- The app's own Counter (src/views/Counter.luax), rendered in isolation. Edit
-- `initial` in the controls; clicks keep their state across hot updates.
return lab.collection({
  title = "Counter",
  renderer = "dom",
  component = Counter,
  args = { initial = 0 },
  controls = { initial = { type = "number" } },
  stories = {
    default = {},
    ten = { args = { initial = 10 } },
  },
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
  if opts.template == "ssr" then
    files["stories/Counter.stories.luax"] = counter_story()
  else
    files["src/components/Welcome.luax"] = M.WELCOME
    files["stories/Welcome.stories.luax"] = welcome_story()
  end
  files["README.md"] = (files["README.md"] or "") .. README
  return files
end

return M
