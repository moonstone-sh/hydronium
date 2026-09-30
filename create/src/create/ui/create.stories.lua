local lab = require("hydronium_lab")
local H = require("hydronium")
local hooks = require("hydronium_ink.hooks")
local ink = require("hydronium_ink")
local wizard = require("create.ui.wizard_app")
local fizzing = require("create.ui.fizzing")
local bubbles = require("create.ui.bubbles")

local sizes = {
  {name = "wide", columns = 100, rows = 30},
  {name = "standard", columns = 80, rows = 24},
  {name = "compact", columns = 48, rows = 20},
  {name = "short", columns = 40, rows = 12},
}
-- Host capabilities are deterministic fixtures, never functions in catalog args.
local function render_wizard(args, preview)
  local opts = {dry_run = true, initial_package_manager_id = "bun"}
  for k, v in pairs(args or {}) do opts[k] = v end
  opts.dry_run = true
  opts.pm_mod = {detect = function() return opts.no_managers and {} or {"bun", "npm", "pnpm"} end}
  if preview then
    opts.preview_phase = preview == "installing" and "tasks" or "done"
    opts.preview_result = {target_dir = "./acid-app", package_manager = "bun", vite = true, next_script = "dev", dry_run = true}
    opts.preview_tasks = {
      {id = "write", label = "Write project files", status = "done"},
      {id = "sync", label = "moon sync", status = "done"},
      {id = "js_install", label = "bun install", status = preview == "installing" and "running" or preview == "failed" and "error" or "done",
        error = preview == "failed" and "Could not reach the package registry. Retry bun install in ./acid-app." or nil},
      {id = "git", label = "Initialize Git", status = preview == "installing" and "pending" or "done"},
    }
  end
  return H.h(wizard.create_wizard_app(opts))
end
-- The wizard's header band on its own: the reaction centered on the title
-- row exactly as wizard_app lays it out, bubbles fizzing from the moment
-- H₃O⁺ lights up. `at` pins a phase of the reaction's own timeline instead
-- of animating: reveal, lit (H₃O⁺ lighting up), burst, settled.
local function phase_time(index, ascii, at)
  local timeline = fizzing.timeline(index, ascii)
  if at == "reveal" then return math.floor(#fizzing.cells(index, ascii) / 2) * fizzing.CHAR_MS end
  if at == "lit" then return timeline.lit_at + fizzing.FLASH_MS end
  if at == "burst" then return timeline.lit_at + 1500 end
  if at == "settled" then return fizzing.final_time(index, ascii) + 4000 end
  return nil
end
local function Fizzing(props)
  local animation = hooks.useAnimation({interval = 33, isActive = not props.reduced_motion})
  return function()
    local index = tonumber(props.reaction) or 7
    local time = phase_time(index, props.ascii, props.at)
    if time == nil then time = props.reduced_motion and fizzing.final_time(index, props.ascii) or animation.time() end
    local columns = hooks.useWindowSize().columns
    local compact = columns < fizzing.width(props.ascii)
    local row = H.h(ink.Box, {flexDirection = "row", width = columns, justifyContent = "center"},
      fizzing.render({index = index, time = time, ascii = props.ascii, compact = compact}))
    return bubbles.render_diorama({columns = columns, time = time, still = props.reduced_motion,
      start = fizzing.timeline(index, props.ascii).lit_at, burst_ms = fizzing.BURST_MS}, row)
  end
end
local fizz_sizes = {{name = "wide", columns = 100, rows = 4}, {name = "standard", columns = 80, rows = 4}, {name = "compact", columns = 48, rows = 4}}
local reaction_options = {}
for i, r in ipairs(fizzing.REACTIONS) do reaction_options[i] = {label = r.u_acid or r.acid, value = i} end
local function fizz_story(title, args)
  args = args or {}
  if args.reaction == nil then args.reaction = 7 end
  return {title = title, args = args, sizes = fizz_sizes,
    controls = {ascii = {type = "boolean", label = "ASCII chemistry"},
      reaction = {type = "select", label = "Reaction", options = reaction_options}},
    render = function(values) return H.h(Fizzing, values) end}
end
local stories = {
  wizard = {title = "01 · Project", args = {name = ""}},
  ["install-flow"] = {title = "Full setup · interactive dry run", args = {},
    description = "Arrows focus, Space selects, Continue advances, Esc goes back. Review then Create project. All installation steps are simulated."},
  ["section-project-active"] = {title = "01 · Project with directory", args = {name = "acid-app", directory = "./apps/acid-app"}},
  ["section-stack-active"] = {title = "02 · App", args = {name = "acid-app", initial_active_id = "framework"}},
  ["app-router"] = {title = "03 · Flavour (SPA routing)", args = {name = "acid-app", initial_framework_id = "spa", initial_active_id = "router"}},
  ["app-terminal"] = {title = "02 · Ink skips browser features", args = {name = "acid-app", initial_framework_id = "ink", initial_active_id = "framework"}},
  ["section-styling-active"] = {title = "Features · Tailwind", args = {name = "acid-app", initial_tailwind = true, initial_active_id = "tailwind"}},
  ["section-tooling-active"] = {title = "Tooling · Bun and Lua", args = {name = "acid-app", initial_active_id = "package_manager"}},
  ["section-tooling-no-package-manager"] = {title = "Tooling · Missing package managers", args = {name = "acid-app", no_managers = true, initial_active_id = "package_manager"}},
  ["review"] = {title = "Review and accept", args = {name = "acid-app", initial_tailwind = true, initial_active_id = "submit"}},
  ["installing"] = {title = "Installation · progress", args = {name = "acid-app", initial_tailwind = true}, render = function(args) return render_wizard(args, "installing") end},
  ["receipt"] = {title = "Installation · receipt", args = {name = "acid-app", initial_tailwind = true}, render = function(args) return render_wizard(args, "receipt") end},
  ["receipt-failed"] = {title = "Installation · failure and retry", args = {name = "acid-app"}, render = function(args) return render_wizard(args, "failed") end},
  narrow = {title = "Breakpoint · compact", args = {name = "acid-app", initial_active_id = "framework"}, sizes = {{name = "compact", columns = 48, rows = 20}}},
  short = {title = "Breakpoint · short", args = {name = "acid-app", initial_active_id = "package_manager"}, sizes = {{name = "short", columns = 40, rows = 12}}},
  ["update-checking"] = {title = "Header · checking for updates", args = {name = "acid-app", update_status = {state = "checking"}}},
  ["update-current"] = {title = "Header · up to date", args = {name = "acid-app", update_status = {state = "current"}}},
  ["update-available"] = {title = "Header · update available", args = {name = "acid-app", update_status = {state = "available", latest = "0.6.0"}}},
  ["reduced-motion"] = {title = "Accessibility · reduced motion", args = {name = "acid-app", reduced_motion = true}},
  ["header-bubbles"] = fizz_story("Fizzing · live reveal and fizz"),
  ["fizzing-reveal"] = fizz_story("Fizzing · character reveal", {at = "reveal"}),
  ["fizzing-lit"] = fizz_story("Fizzing · H₃O⁺ lights up", {at = "lit"}),
  ["fizzing-burst"] = fizz_story("Fizzing · burst", {at = "burst"}),
  ["fizzing-settled"] = fizz_story("Fizzing · settled (idle fizz)", {at = "settled"}),
  ["fizzing-hcl"] = fizz_story("Fizzing · shortest (HCl)", {reaction = 2, at = "settled"}),
  ["fizzing-peptide"] = fizz_story("Fizzing · widest (peptide carboxyl group)", {reaction = 8, at = "settled"}),
  ["fizzing-ascii"] = fizz_story("Fizzing · ASCII", {ascii = true}),
  ["fizzing-reduced-motion"] = fizz_story("Fizzing · reduced motion", {reduced_motion = true}),
}
return lab.collection({title = "Create/Wizard", renderer = "ink", sizes = sizes,
  render = function(args) return render_wizard(args) end, stories = stories})
