local lab = require("hydronium_lab")
local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local wizard_app = require("create.ui.wizard_app")
local logo = require("create.ui.logo")
local checklist_ui = require("create.ui.checklist")

-- The wizard is the product surface. The shared `render` below mounts the
-- real, stateful create.ui.wizard_app -- the exact same component
-- `hydronium-create`'s real TTY path mounts (see create/src/main.lua): one
-- component, two hosts, never two implementations. Every story below
-- either drives that one component into a particular, otherwise-reachable
-- state via wizard_app's `initial_*` Lab-story opts (see that file's own
-- header comment on why those opts exist and why nothing else ever passes
-- them), or renders one of its pure presentational pieces
-- (create.ui.logo/checklist) in isolation.
--
-- SIZES: the form is a "whole thing always rendered" inline scrollback
-- form (see wizard_app.lua's own header comment) -- there is no
-- alternate-screen viewport clipping it to one page. A real terminal's own
-- scrollback holds all of it; Ink Lab's headless grid needs a tall enough
-- `rows` to capture the same thing without truncating mid-form, which is
-- why every wide story below asks for generous height rather than the
-- old step-wizard's own 16-20 rows (correct for a UI that only ever showed
-- one field panel at a time -- this one never does).
return lab.collection({
  title = "Create/Wizard",
  render = function(args)
    return hydronium.h(wizard_app.create_wizard_app(args))
  end,
  sizes = {
    { name = "default", columns = 84, rows = 130 },
    { name = "narrow", columns = 40, rows = 130 },
  },
  stories = {
    -- The canonical, non-interactive snapshot: every default, name empty.
    wizard = { args = {} },

    -- The full wizard, live and keyboard-driven -- the same interactive
    -- form `hydronium-create` mounts for real, ending in a real (under
    -- dry_run, side-effect-free) checklist and result. Nothing is ever
    -- written to disk and no process is ever spawned from here --
    -- create.ui.wizard_app defaults `dry_run` to true whenever it isn't
    -- explicitly told otherwise. Try: type a project name, arrow through
    -- Stack/Styling/Tooling (↑/↓ move fields, ←/→ pick within one,
    -- digits 1-4 jump sections), then Ctrl+Enter (or Ctrl+S) to create.
    ["install-flow"] = {
      title = "Install flow (interactive, dry-run)",
      description = "The real wizard, live: walk every section with ↑↓/←→/space/digits, "
        .. "then Ctrl+Enter (or Ctrl+S) to run the real checklist under dry_run -- nothing "
        .. "is ever written to disk and no package manager or git is ever actually invoked "
        .. "from here.",
      args = { dry_run = true },
    },

    -- One story per section, each landed on that section's first field so
    -- its marker renders "◆" (active, bright) while the other three show
    -- "◇" (inactive, dimmed) -- see wizard_app.lua's own `active_group`
    -- rendering and ui/field.lua's `group_dim` threading.
    ["section-project-active"] = {
      title = "Section: Project (active)",
      description = "The Project group focused -- its own marker is \"\226\151\134\", the other three are dimmed \"\226\151\135\".",
      args = { initial_active_id = "name", name = "my-hydronium-app" },
    },
    ["section-stack-active"] = {
      title = "Section: Stack (active)",
      description = "The Stack group focused: framework and router radios, every alternative visible.",
      args = { initial_active_id = "framework", name = "my-hydronium-app" },
    },
    ["section-styling-active"] = {
      title = "Section: Styling (active)",
      description = "The Styling group focused: the Tailwind CSS v4 toggle.",
      args = { initial_active_id = "tailwind", name = "my-hydronium-app" },
    },
    ["section-tooling-active"] = {
      title = "Section: Tooling (active)",
      description = "The Tooling group focused: package manager, interpreter, and the install/git toggles.",
      args = { initial_active_id = "package_manager", name = "my-hydronium-app", initial_tailwind = true },
    },

    -- Landed on the final rail node with every other field already
    -- decided: this is what the form's OWN scrollback looks like once
    -- you've moved on from a field -- every alternative you did NOT pick
    -- renders struck through and dim (see ui/field.lua's own header
    -- comment for exactly when that kicks in), while your actual picks
    -- stay bright and legible. This is the story that makes "the final
    -- scrolled-back form shows the picked path clearly" checkable at a
    -- glance.
    ["strikethrough-final"] = {
      title = "Final state (struck-through alternatives)",
      description = "Landed on the \226\151\134 Create node with real choices made throughout -- every "
        .. "alternative NOT picked (SPA's siblings, Meteorite-only's sibling, npm's siblings, "
        .. "Lua 5.4's sibling) renders struck through and dim; the picks stay bright.",
      args = {
        name = "acid-app", initial_active_id = "submit",
        initial_framework_id = "spa", initial_router_id = "meteorite",
        initial_tailwind = true, initial_package_manager_id = "npm",
        initial_interpreter_id = "lua@5.4", initial_install_deps = true, initial_git_init = false,
      },
    },

    -- Narrow terminal degrade: below 48 columns the header falls back to
    -- wordmark-only (see ui/logo.lua's own three responsive tiers).
    narrow = {
      title = "Narrow terminal (wordmark-only header)",
      description = "Below 40 columns H3O+, the bubble field, and the update-status indicator all "
        .. "disappear entirely; only the plain \"hydronium \194\183 create vX.Y.Z\" wordmark remains, "
        .. "and the footer's key hints shrink to their compact form.",
      args = { name = "my-app" },
      sizes = { { name = "narrow", columns = 36, rows = 130 } },
    },

    -- The '?' cheat sheet: a landed, non-text-field-focused state with
    -- `initial_cheat = true` so the full keybinding panel renders below
    -- the sticky one-line footer without needing a live keypress.
    ["cheat-sheet"] = {
      title = "Cheat sheet ('?' expanded)",
      description = "The full keybinding panel '?' toggles, shown open below the sticky one-line footer.",
      args = { initial_active_id = "framework", initial_cheat = true, name = "my-app" },
    },

    -- Post-submit checklist, with a deliberately mixed mock task list
    -- (done / running / pending / error) so every glyph checklist.lua
    -- draws is visible in one frame -- this is NOT wizard_app (a live
    -- checklist only ever shows one "running" task at a time), it is
    -- ui/checklist.lua's own pure `render(tasks, frame)` fed a fixture,
    -- exactly the kind of isolated-piece story create.ui.select_list/
    -- toggle/name_input/summary used to be before this file's redesign
    -- (see git history) -- those modules are gone now that every field
    -- shape lives in ui/field.lua instead, but the "snapshot one
    -- presentational piece with fixed props" idea they modeled is exactly
    -- what this story (and header-sweep/header-static below) still does.
    ["checklist-mock"] = {
      title = "Post-submit checklist (mock tasks)",
      description = "ui/checklist.lua in isolation with a fixed, mixed task list -- done, running, "
        .. "pending, and a failed step with its error -- so every glyph is visible in one frame.",
      render = function()
        return checklist_ui.render({
          { id = "write", label = "Write project files", status = "done" },
          { id = "sync", label = "moon sync", status = "done" },
          { id = "js_install", label = "npm install", status = "running" },
          { id = "git", label = "git init", status = "pending" },
        }, 3)
      end,
      sizes = { { name = "default", columns = 60, rows = 12 } },
    },
    ["checklist-mock-error"] = {
      title = "Post-submit checklist (a failed step)",
      description = "The same checklist with a step that failed -- its error and a retry hint print beneath it.",
      render = function()
        return checklist_ui.render({
          { id = "write", label = "Write project files", status = "done" },
          { id = "sync", label = "moon sync", status = "error", error = "moon sync failed: exit code 1" },
        }, 0)
      end,
      sizes = { { name = "default", columns = 60, rows = 10 } },
    },

    -- The inline H3O+ header on its own, with and without the one-time
    -- startup gradient sweep -- ui/logo.lua is pure, so these need no
    -- session state at all, just two different `sweep` values.
    ["header-sweep"] = {
      title = "Header: mid-sweep",
      description = "The one-time pH-scale gradient sweep partway across the inline H3O+ (skippable by any key -- see wizard_app.lua).",
      render = function() return logo.render({ columns = 84, version = "0.5.0", sweep = 0.35, update_status = { available = false } }) end,
      sizes = { { name = "default", columns = 84, rows = 3 } },
    },
    ["header-static"] = {
      title = "Header: settled gradient, up to date",
      description = "The header after the startup sweep has finished (or was skipped) -- a static pH-scale gradient across H3O+, and the green \"Up to date\" status.",
      render = function() return logo.render({ columns = 84, version = "0.5.0", update_status = { available = false } }) end,
      sizes = { { name = "default", columns = 84, rows = 3 } },
    },
    ["header-update-available"] = {
      title = "Header: update available",
      description = "Yellow \"!\" badge. Resize through the breakpoints: full label at >=80 columns, version only at 64-79, badge only below.",
      render = function() return logo.render({ columns = 84, version = "0.5.0", update_status = { state = "available", latest = "0.6.0" } }) end,
      sizes = { { name = "wide", columns = 84, rows = 3 }, { name = "medium", columns = 70, rows = 3 }, { name = "compact", columns = 50, rows = 3 } },
    },
    ["header-status-breakpoints"] = {
      title = "Header: update status at every breakpoint",
      description = "checking (blue spinner) / available (! on yellow) / up to date (✓ on green), each at 84, 70 and 50 columns. Unknown renders nothing.",
      render = function()
        local rows = {}
        for _, state in ipairs({ { state = "checking" }, { state = "available", latest = "0.6.0" }, { state = "current", latest = "0.5.0" } }) do
          for _, columns in ipairs({ 84, 70, 50 }) do
            rows[#rows + 1] = hydronium.h(ink.Box, { key = state.state .. columns, width = columns },
              logo.render({ columns = columns, version = "0.5.0", frame = 3, update_status = state }))
          end
        end
        return hydronium.h(ink.Box, { flexDirection = "column" }, rows)
      end,
      sizes = { { name = "default", columns = 84, rows = 10 } },
    },
    ["header-bubbles"] = {
      title = "Header: sparkly bubble field",
      description = "ui/bubbles.lua in isolation at a frame where one bubble is mid-\"explode\" (bright pH-gradient) among the rest, dim gray.",
      render = function()
        local bubbles = require("create.ui.bubbles")
        return bubbles.render({ frame = 7, columns = 84 })
      end,
      sizes = { { name = "default", columns = 84, rows = 2 } },
    },
  },
})
