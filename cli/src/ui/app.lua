--[[
  hydronium-cli ui.app -- the `hydronium dev` status view, built as an
  ordinary Hydronium component tree over hydronium_ink's Box/Text
  intrinsics. No bespoke renderer, no hand-rolled ANSI: this is the
  framework rendering its own CLI.

  Plain Lua rather than `.luax` on purpose -- the CLI is a `bin` package
  whose only job is to run; making it depend on the LUAX compiler (and
  compile a view at startup, the way examples/ink_todo/run.lua does)
  would add a build step to a tool that exists to remove one. The tree is
  small enough that `hydronium.h` reads fine.

  SHAPE (matches the plan's target mock):

     ➜  Hydronium app up and running on http://127.0.0.1:8080/
        12 routes · 340ms

        GET /home · 51ms x3
        hmr watch · 2ms x12
        rebuild · views/App.luax → zig

  Before the first `startup` event lands, the two header lines are
  replaced by a single spinner line driven by hydronium_ink's own
  `useAnimation` ticker (render.lua checks registered tickers once per
  ~33ms loop iteration) -- not a hand-rolled timer.

  COLOR. The mock's "light blue" does not exist here: host/terminal.lua
  speaks the 8 named ANSI colors (see its COLOR_CODES), and adding
  256-color support is explicitly out of scope for this phase. `cyan` is
  the nearest, and is what the repo's own quickstart dev.sh banner
  already uses for the same URL.

  REACTIVITY NOTE. `frame()` is read only while the status is "starting".
  Once the header replaces the spinner, the render closure no longer
  touches that signal, so Hydronium's fine-grained tracking stops
  re-running it on every tick -- the view goes quiet until a real event
  arrives, instead of repainting 8 times a second forever.
--]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local inspector = require("inspector")
local inspector_view = require("ui.inspector_view")
local search_field = require("ui.search_field")
local search_bar = require("ui.search_bar")
local query = require("query")

-- LuaJIT/5.1 spell it `unpack`; 5.2+ moved it to `table.unpack`. This
-- package is LuaJIT-only (hydronium_ink is), but the two-line guard costs
-- nothing and keeps the module loadable under a plain 5.4 for inspection.
local unpack = unpack or table.unpack

local M = {}

--- Braille dot spinner, one cell wide.
M.SPINNER_FRAMES = {
  "\226\160\139", "\226\160\153", "\226\160\185", "\226\160\184",
  "\226\160\188", "\226\160\180", "\226\160\166", "\226\160\167",
  "\226\160\135", "\226\160\143",
}

--- The dev server's URL.
---
--- STATED GAP: the `startup` event's field list (routes, mode, backend,
--- ready_ms) carries no URL, so there is nothing to source this from yet.
--- This CLI parses no `--url`/`--port` flag either (the flag grammar is
--- exactly `dev [--verbose] [--show-ips]`), so the header shows this
--- default, and picks up `startup.url` automatically if a later meteorite
--- starts emitting one. It matches examples/quickstart/dev.sh's own port.
M.DEFAULT_URL = "http://127.0.0.1:8080/"

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------

local State = {}
State.__index = State
M.State = State

--- @class hydronium_cli.UiStateOptions
--- @field url? string
--- @field history? table An inspector.History (src/inspector.lua). One is created if omitted.
--- @field fullscreen? boolean Start in the fullscreen request-debug view.
--- @field show_ips? boolean Show remote addresses (mirrors --show-ips).

--- All the reactive state the view reads. Created outside any component
--- so the tick loop (which runs between renders, see render.lua's
--- `opts.onTick`) can write to it directly.
---
--- THE REQUEST HISTORY IS NOT A SIGNAL, deliberately. It is a capped
--- 2000-entry list (see src/inspector.lua) that grows by one on every
--- request; putting it in a signal would mean copying it on every event to
--- get a new value the signal could compare. Instead the list is an
--- ordinary table on this state and `requests_revision` is the signal --
--- bumped once per accepted request, read by the fullscreen view, which is
--- what makes reading the plain table reactive.
--- @param opts? hydronium_cli.UiStateOptions
--- @return table
function M.new_state(opts)
  opts = opts or {}
  local get_status, set_status = hydronium.signal("starting") -- "starting" | "ready" | "down"
  local get_routes, set_routes = hydronium.signal(nil)
  local get_ready_ms, set_ready_ms = hydronium.signal(nil)
  local get_url, set_url = hydronium.signal(opts.url or M.DEFAULT_URL)
  local get_entries, set_entries = hydronium.signal({})
  local get_note, set_note = hydronium.signal(nil)
  -- Count of hydronium dev-endpoint requests filtered out of the views.
  -- Displayed, not swallowed: a filter you cannot see is indistinguishable
  -- from a dev server that has stopped receiving traffic.
  local get_hidden_hmr, set_hidden_hmr = hydronium.signal(0)
  -- Filter bar: the editing state itself, a revision counter to make an
  -- in-place mutation observable, and focus.
  local get_search, set_search = hydronium.signal(search_field.new_state(""))
  local get_search_revision, set_search_revision = hydronium.signal(0)
  local get_search_focused, set_search_focused = hydronium.signal(false)
  local get_fullscreen, set_fullscreen = hydronium.signal(opts.fullscreen and true or false)
  local get_revision, set_revision = hydronium.signal(0)
  local get_selection, set_selection = hydronium.signal(0)

  local state = setmetatable({
    status = get_status, set_status = set_status,
    routes = get_routes, set_routes = set_routes,
    ready_ms = get_ready_ms, set_ready_ms = set_ready_ms,
    url = get_url, set_url = set_url,
    entries = get_entries, set_entries = set_entries,
    hidden_hmr = get_hidden_hmr, set_hidden_hmr = set_hidden_hmr,
    search = get_search, set_search = set_search,
    search_revision = get_search_revision, set_search_revision = set_search_revision,
    search_focused = get_search_focused, set_search_focused = set_search_focused,
    note = get_note, set_note = set_note,
    fullscreen = get_fullscreen, set_fullscreen = set_fullscreen,
    requests_revision = get_revision, set_requests_revision = set_revision,
    selection = get_selection, set_selection = set_selection,
    history = opts.history or inspector.new_history(),
    show_ips = opts.show_ips and true or false,
    -- Last terminal height the fullscreen view actually painted with.
    -- A PLAIN FIELD, not a signal: the view writes it during its own
    -- render (a signal write there is rejected, see core/signals), and the
    -- only reader is the key handler working out how far PageUp/PageDown
    -- should jump. Nothing re-renders because of it.
    viewport_rows = nil,
  }, State)

  return state
end

--- Records one request into the history and keeps the selection pinned to
--- the newest row while it already was the newest row (see
--- inspector.follow_tail). Called from the drain loop, never from a
--- render.
--- @param event table
--- @return boolean accepted
function State:record_request(event)
  local history = self.history
  local previous_count = history:count()
  local previous_dropped = history.dropped
  if not history:push(event) then
    return false
  end
  local dropped = history.dropped - previous_dropped
  self.set_selection(inspector.follow_tail(self.selection(), previous_count, history:count(), dropped))
  self.set_requests_revision(self.requests_revision() + 1)
  return true
end

--- Folds one event into the header state. The events *pane* is fed
--- separately (from the collapse buffer's snapshot) -- this only handles
--- the parts of the view that are about the server's overall condition.
--- @param event table
function State:apply(event)
  local kind = event.kind
  if kind == "startup" then
    self.set_status("ready")
    self.set_routes(tonumber(event.routes))
    self.set_ready_ms(tonumber(event.ready_ms))
    if type(event.url) == "string" and event.url ~= "" then
      self.set_url(event.url)
    end
    self.set_note(nil)
  elseif kind == "server_exit" then
    self.set_status("down")
    self.set_note("server exited" .. (event.reason and (": " .. tostring(event.reason)) or ""))
  elseif kind == "build_error" then
    self.set_note("build failed at " .. tostring(event.stage or "?"))
  elseif kind == "reload" and event.ok then
    self.set_note(nil)
  end
end

-- ---------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------

local function header_lines(state)
  local children = {
    hydronium.h(ink.Box, { flexDirection = "row" },
      hydronium.h(ink.Text, { color = "green", bold = true }, " \226\158\156  "),
      hydronium.h(ink.Text, {}, "Hydronium app up and running on "),
      -- "light blue" is not in the 8-color set this host speaks; cyan is
      -- the nearest, same choice examples/quickstart/dev.sh already made.
      --
      -- `href` makes this a real OSC 8 hyperlink, so the URL is clickable
      -- instead of being text that merely looks like a link. Underlined
      -- explicitly rather than relying on the terminal to decorate links:
      -- the decoration is what tells you it IS clickable, and a terminal with
      -- hyperlink support switched off renders the same underlined text with
      -- no escape bytes at all, so nothing looks broken either way.
      hydronium.h(ink.Text, { color = "cyan", underline = true, href = state.url() }, state.url())
    ),
  }

  local routes, ready_ms = state.routes(), state.ready_ms()
  local meta = {}
  if routes then
    meta[#meta + 1] = string.format("%d route%s", routes, routes == 1 and "" or "s")
  end
  if ready_ms then
    meta[#meta + 1] = string.format("%dms", math.floor(ready_ms + 0.5))
  end
  if #meta > 0 then
    children[#children + 1] =
      hydronium.h(ink.Text, { dimColor = true }, "    " .. table.concat(meta, " \194\183 "))
  end

  return children
end

local function spinner_line(frameText, label)
  return hydronium.h(ink.Box, { flexDirection = "row" },
    hydronium.h(ink.Text, { color = "cyan" }, " " .. frameText .. "  "),
    hydronium.h(ink.Text, { dimColor = true }, label)
  )
end

--- Builds the root component. Closes over `state` rather than taking
--- props: props are frozen on the way into a component (see
--- core/element.lua's freezeProps), and there is exactly one of these
--- trees per process, so a closure is both simpler and honest about the
--- lifetime.
--- @param state table From M.new_state.
--- @param opts? { onQuit?: fun() }
--- @return fun(): fun(): any A Hydronium component (setup once, render many).
function M.create_app(state, opts)
  opts = opts or {}

  local InspectorView = inspector_view.create_view(state)

  return function()
    -- Registered once at setup, as hooks.lua requires. The ticker runs in
    -- render.lua's own loop; nothing here owns a timer.
    local spinner = hooks.useAnimation({ interval = 110 })
    local exit = hooks.useApp().exit
    local alt = hooks.useAltScreen()
    -- OSC 52 write, for the filter bar's copy binding. Set up here at the
    -- component's one-time setup call, like every other hook in this file.
    local clipboard = hooks.useClipboard()

    -- The REACTIVE window-size getter, not a snapshot of its value the way
    -- `hooks.useWindowSize()` would hand back. The key handler below runs
    -- between renders and needs the CURRENT terminal height to size a
    -- PageUp/PageDown jump; reading the getter there is an untracked read
    -- (no render is on the stack), which is exactly what is wanted.
    local ink_context = hydronium.useContext(hooks.InkAppContext)

    local function quit()
      if opts.onQuit then
        opts.onQuit()
      end
      exit()
    end

    --- Entering also switches the real terminal into its alternate screen
    --- buffer, so leaving restores the scrollback the dev session was
    --- started from instead of stranding a full-height frame in it.
    local function set_fullscreen(enabled)
      if enabled == state.fullscreen() then
        return
      end
      state.set_fullscreen(enabled)
      if enabled then
        alt.enter()
      else
        alt.leave()
      end
    end

    local function page_rows()
      local size = ink_context and ink_context.windowSize()
      local rows = state.viewport_rows
        or inspector_view.visible_rows(size and size.rows or inspector.FALLBACK_ROWS)
      return inspector.page_size(rows)
    end

    local function move(delta)
      state.set_selection(inspector.move_selection(state.selection(), delta, state.history:count()))
    end

    hooks.useInput(function(input, key)
      key = key or {}

      -- The filter bar swallows input FIRST while focused, before any of the
      -- single-letter shortcuts below. Otherwise typing `q` into a filter
      -- would quit the process and typing `f` would drop out of the view --
      -- a text field that loses your work to a hotkey is worse than no text
      -- field at all.
      if state.search_focused() then
        if key.escape then
          state.set_search_focused(false)
          return
        end
        if key["return"] then
          -- Enter commits by blurring; the filter itself is already live,
          -- since it reapplies on every keystroke.
          state.set_search_focused(false)
          return
        end
        local next_state, intent = search_field.handle_key(state.search(), { input = input, key = key })
        state.set_search(next_state)
        state.set_search_revision(state.search_revision() + 1)
        if intent and intent.type == "copy" and clipboard then
          clipboard.write(intent.text)
        end
        return
      end

      -- `/` focuses the filter, the convention every pager and log viewer
      -- shares. Only meaningful in the fullscreen view, which is where the
      -- request list lives.
      if input == "/" and state.fullscreen() then
        state.set_search_focused(true)
        return
      end

      -- `q` always quits, on either screen. Escape is screen-sensitive:
      -- in the inspector it means "back to the status view", which is what
      -- every fullscreen pager does, and only quits from the status view
      -- itself.
      if input == "q" then
        return quit()
      end
      if input == "f" then
        return set_fullscreen(not state.fullscreen())
      end
      if key.escape then
        if state.fullscreen() then
          return set_fullscreen(false)
        end
        return quit()
      end

      if not state.fullscreen() then
        return
      end

      local count = state.history:count()
      if input == "j" or key.downArrow then
        move(1)
      elseif input == "k" or key.upArrow then
        move(-1)
      elseif key.pageDown or input == " " then
        move(page_rows())
      elseif key.pageUp then
        move(-page_rows())
      elseif input == "g" or key.home then
        state.set_selection(inspector.clamp_selection(1, count))
      elseif input == "G" or key["end"] then
        state.set_selection(inspector.clamp_selection(count, count))
      end
    end)

    return function()
      if state.fullscreen() then
        return hydronium.h(InspectorView)
      end
      return M.render_status(state, spinner)
    end
  end
end

--- The compact, persistent status view -- the whole view before the
--- fullscreen inspector existed, split out verbatim so create_app's own
--- render closure is just the screen switch.
--- @param state table
--- @param spinner table From hooks.useAnimation.
--- @return any
function M.render_status(state, spinner)
  local status = state.status()
  local children = {}

  if status == "starting" then
    local frames = M.SPINNER_FRAMES
    local frameText = frames[(spinner.frame() % #frames) + 1]
    children[#children + 1] = spinner_line(frameText, "starting meteorite dev\226\128\166")
  elseif status == "down" then
    children[#children + 1] = hydronium.h(ink.Box, { flexDirection = "row" },
      hydronium.h(ink.Text, { color = "red", bold = true }, " \195\151  "),
      hydronium.h(ink.Text, {}, "Dev server stopped")
    )
  else
    for _, line in ipairs(header_lines(state)) do
      children[#children + 1] = line
    end
  end

  local note = state.note()
  if note and status ~= "starting" then
    children[#children + 1] =
      hydronium.h(ink.Text, { color = "yellow" }, "    " .. note)
  end

  local entries = state.entries()
  if #entries > 0 then
    children[#children + 1] = hydronium.h(ink.Newline)
    for index, entry in ipairs(entries) do
      local text = entry.label
      if entry.count and entry.count > 1 then
        text = text .. " x" .. tostring(entry.count)
      end
      children[#children + 1] =
        hydronium.h(ink.Text, { key = index, dimColor = true }, "    " .. text)
    end
  end

  -- Hidden dev-endpoint traffic. Shown as a single dim line rather than
  -- omitted entirely, because a quiet events pane should not be ambiguous
  -- between "nothing is hitting the server" and "everything hitting it is
  -- being filtered". The durable log has all of it regardless.
  local hidden = state.hidden_hmr and state.hidden_hmr() or 0
  if hidden > 0 then
    children[#children + 1] = hydronium.h(ink.Text, { dimColor = true },
      string.format("    %d hmr/dev request%s hidden \226\128\148 --show-hmr to include",
        hidden, hidden == 1 and "" or "s"))
  end

  -- The one discoverability line for the fullscreen view.
  if status ~= "starting" then
    -- Read purely to subscribe: the count itself comes off a plain table
    -- (see new_state's note), so this signal is what re-runs this render
    -- when a request arrives.
    state.requests_revision()
    local count = state.history:count()
    children[#children + 1] = hydronium.h(ink.Newline)
    children[#children + 1] = hydronium.h(ink.Text, { dimColor = true },
      string.format("    f  inspect %d request%s \194\183 q  quit", count, count == 1 and "" or "s"))
  end

  return hydronium.h(ink.Box, { flexDirection = "column" }, unpack(children))
end

return M
