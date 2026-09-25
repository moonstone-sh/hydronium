local lab = require("hydronium_lab")
local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local app = require("ui.app")
local field = require("ui.search_field")
local query = require("query")
local search_bar = require("ui.search_bar")

local function request(method, path, status, duration_ms, body)
  return {
    v = 1,
    source = "meteorite",
    kind = "request",
    ts = 1,
    method = method,
    path = path,
    status = status,
    duration_ms = duration_ms,
    body = body,
  }
end

-- A real fullscreen Hydronium CLI, populated with a small but varied request
-- history. It is intentionally one interactive scenario, rather than a
-- collection of screenshots for selection and cursor positions:
--   j/k or arrows navigate; / focuses the live filter; Escape leaves it.
local function SyntheticDevSession()
  local state = app.new_state({ fullscreen = true })
  state:apply({
    v = 1,
    source = "meteorite",
    kind = "startup",
    ts = 1,
    routes = 12,
    ready_ms = 84,
    url = "http://127.0.0.1:6100/",
  })

  for _, event in ipairs({
    request("GET", "/api/projects", 200, 18, "project list"),
    request("POST", "/api/session", 201, 43, "signed in"),
    request("GET", "/assets/app.js", 200, 6, "bundle"),
    request("POST", "/api/contact", 422, 31, "email is required"),
    request("GET", "/health", 200, 2, "ok"),
    request("GET", "/api/projects/42", 500, 107, "database timeout"),
  }) do
    state:record_request(event)
  end

  return hydronium.h(app.create_app(state, { onQuit = function() end }))
end

-- A focused editing surface for validating real text input, caret movement,
-- deletion, and the transition between raw text and completed chips.
--
-- `profile` is the STATIC preview the story's own `profile` control drives
-- (see `lab.collection`'s `controls` below) -- it is passed straight to
-- `search_bar.render`'s `opts.profile`, the same explicit argument
-- `cli/tests/search_bar_spec.lua` uses, since a plain `render(args)` story
-- has no mounted component/hook context to read a LIVE
-- `hooks.useColorProfile()` from (see search_bar.lua's own top doc comment
-- on why `M.render` takes `opts.profile` explicitly rather than reaching
-- for the hook itself).
--
-- @param profile "truecolor"|"ansi256"|"ansi16"|"none"
local function InteractiveFilter(profile)
  local state, set_state = hydronium.signal(field.new_state(""))

  hooks.useInput(function(input, key, event)
    set_state(field.handle_key(state(), { input = input, key = key or {} }))
    if event then event.stop() end
  end)

  return function()
    local current = state()
    return hydronium.h(ink.Box, { flexDirection = "column" },
      hydronium.h(ink.Text, { dimColor = true },
        "Type a filter. Left/Right, Backspace, Ctrl+A, and Ctrl+W are live. Color profile: " .. profile),
      search_bar.render(current, query.tokenize(current.text), { focused = true, profile = profile }))
  end
end

-- A deliberately dense completed query. Its value is visual: at the cramped
-- size every chip must wrap as one flex item rather than split mid-label.
-- @param profile "truecolor"|"ansi256"|"ansi16"|"none"
local function CrowdedWrapping(profile)
  local state = field.new_state(
    "method:GET status:200 path:/api/projects mime:json origin:local ip:127.0.0.1 duration:>100")
  return hydronium.h(ink.Box, { flexDirection = "column" },
    hydronium.h(ink.Text, { dimColor = true },
      "Use the cramped size: completed chips wrap whole, never mid-token. Color profile: " .. profile),
    search_bar.render(state, query.tokenize(state.text), { focused = false, profile = profile }))
end

-- Every chip role (known field, negated, unknown field, selection, caret)
-- painted under all four color profiles stacked in one view, so a
-- truecolor-vs-ansi256-vs-ansi16-vs-none comparison needs no control
-- flipping at all -- see search_bar.lua's own STRUCTURAL_STYLE doc comment
-- for why ansi16/"none" look structurally different (inverse/bold, no
-- absolute color) rather than a degraded version of the same hues.
local function ProfileComparison()
  local state = field.new_state("method:GET -status:5xx nope:1 plain-text")
  local tokens = query.tokenize(state.text)
  local rows = {}
  for _, profile in ipairs({ "truecolor", "ansi256", "ansi16", "none" }) do
    rows[#rows + 1] = hydronium.h(ink.Box, { key = profile, flexDirection = "column", marginBottom = 1 },
      hydronium.h(ink.Text, { dimColor = true }, profile .. ":"),
      -- selFrom/selTo aren't exposed by search_field's plain new_state, so
      -- the selection role is shown via `filter-input`'s own `selection`
      -- story control instead -- this view is about the four CHIP roles
      -- (field/unknown_field/value + caret) side by side per profile.
      search_bar.render(state, tokens, { focused = false, profile = profile }))
  end
  return hydronium.h(ink.Box, { flexDirection = "column" }, rows)
end

return lab.collection({
  title = "CLI/Dev session",
  render = function(args)
    local profile = args.profile or "truecolor"
    if args.mode == "session" then return SyntheticDevSession() end
    if args.mode == "input" then return hydronium.h(function() return InteractiveFilter(profile) end) end
    if args.mode == "profiles" then return ProfileComparison() end
    return CrowdedWrapping(profile)
  end,
  -- Applies to every story below (hydronium_lab.discovery merges
  -- collection-level and story-level controls) -- so any of them can be
  -- viewed under truecolor/ansi256/ansi16/none from the Lab's own controls
  -- panel, in addition to `synthetic-events`/`profiles` below which show
  -- profile handling more directly (a live session override and a
  -- side-by-side comparison, respectively).
  controls = {
    profile = { type = "select", options = { "truecolor", "ansi256", "ansi16", "none" } },
  },
  stories = {
    ["synthetic-events"] = {
      args = { mode = "session" },
      sizes = {
        { name = "default", columns = 100, rows = 28 },
        { name = "compact", columns = 76, rows = 20 },
      },
      -- The real fullscreen app (search_bar.create's own component, with
      -- hooks.useColorProfile() live) -- so this one is previewed by
      -- switching the SESSION's color profile (Ink Lab's own profile
      -- control / an `op = "colorProfile"` request, see
      -- hydronium_ink_lab.runtime), not this story's `profile` arg control
      -- above, which only reaches the two plain-render stories below.
    },
    ["filter-input"] = {
      args = { mode = "input", profile = "truecolor" },
      sizes = {
        { name = "wide", columns = 100, rows = 6 },
        { name = "narrow", columns = 56, rows = 8 },
      },
    },
    ["crowded-wrapping"] = {
      args = { mode = "wrapping", profile = "truecolor" },
      sizes = {
        { name = "wide", columns = 100, rows = 6 },
        { name = "narrow", columns = 56, rows = 8 },
        { name = "cramped", columns = 34, rows = 12 },
      },
    },
    ["color-profiles"] = {
      args = { mode = "profiles" },
      description = "Every chip role under truecolor/ansi256/ansi16/none, stacked for direct comparison.",
      sizes = {
        { name = "default", columns = 70, rows = 24 },
      },
    },
  },
})
