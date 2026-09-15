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

--- All the reactive state the view reads. Created outside any component
--- so the tick loop (which runs between renders, see render.lua's
--- `opts.onTick`) can write to it directly.
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

  return setmetatable({
    status = get_status, set_status = set_status,
    routes = get_routes, set_routes = set_routes,
    ready_ms = get_ready_ms, set_ready_ms = set_ready_ms,
    url = get_url, set_url = set_url,
    entries = get_entries, set_entries = set_entries,
    note = get_note, set_note = set_note,
  }, State)
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
      hydronium.h(ink.Text, { color = "cyan" }, state.url())
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

  return function()
    -- Registered once at setup, as hooks.lua requires. The ticker runs in
    -- render.lua's own loop; nothing here owns a timer.
    local spinner = hooks.useAnimation({ interval = 110 })
    local exit = hooks.useApp().exit

    hooks.useInput(function(input, key)
      if input == "q" or (key and key.escape) then
        if opts.onQuit then
          opts.onQuit()
        end
        exit()
      end
    end)

    return function()
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

      return hydronium.h(ink.Box, { flexDirection = "column" }, unpack(children))
    end
  end
end

return M
