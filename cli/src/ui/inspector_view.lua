--[[
  hydronium-cli ui.inspector_view -- the FULLSCREEN REQUEST-DEBUG view
  (`hydronium dev --fullscreen`, or `f` at runtime).

  A plain Hydronium component over hydronium_ink's Box/Text, same as
  ui/app.lua's status view and for the same reasons (no bespoke renderer,
  no hand-rolled ANSI, plain Lua rather than `.luax` so the CLI needs no
  compile step).

  WHAT IT PAINTS:

    Requests 1-24 of 127    / filter | f/esc exit | j/k scroll | q quit
      METHOD PATH                                   STATUS    TIME
    > GET    /home                                     200    47ms
      GET    /__hydronium/watch                        200     2ms
      ...
    ----------------------------------------------------------------
    GET /home | 200 | 47ms | 127.0.0.1
    headers: not captured -- meteorite's dev-event stream carries no headers yet
    body: not captured -- meteorite's dev-event stream carries no bodies yet

  EVERY STRING HERE IS ASCII, deliberately -- see src/inspector.lua's own
  note on why (the host paints one grid cell per BYTE, so a multi-byte
  character desynchronizes the incremental diff's absolute cursor columns
  and garbles partial repaints).

  Every row comes from the durable `.hydronium/dev.log` history (see
  src/inspector.lua and src/dev_log.lua's `read_events`), NOT from the
  collapsed 3-row display buffer the status view uses -- a request folded
  into `x7` or evicted off that ring is exactly the one you opened this
  view to look at.

  ALL LAYOUT ARITHMETIC LIVES IN src/inspector.lua (pure, tested): this
  file only turns the rows and detail lines that module returns into
  elements. The two things it owns itself are reading the reactive window
  size (so a terminal resize re-windows the list) and the `key` props that
  keep the reconciler's row identity stable.
--]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local inspector = require("inspector")
local query = require("query")
local search_bar = require("ui.search_bar")

local unpack = unpack or table.unpack

local M = {}

--- Minimum request rows to paint even on a very short terminal -- below
--- this the view is useless, so it overflows rather than showing nothing.
M.MIN_ROWS = 3

--- The separator between the list and the detail pane.
---
--- ASCII `-`, NOT a box-drawing rule, and this is load-bearing: ink
--- measures text width in BYTES (there is no wide-character width
--- accounting anywhere in its terminal stack -- see host/terminal.lua's own
--- note), so a 98-character U+2500 rule measures as 294 columns wide. That
--- made the whole frame 294 columns wide on a 110-column terminal, every
--- painted row wrapped, and the view appeared with most of its rows
--- missing -- observed for real in a live tmux session, not hypothesized.
--- One byte per column keeps measured width and real width the same.
--- @param columns integer
--- @return any
local function rule(columns)
  return hydronium.h(ink.Text, { dimColor = true }, string.rep("-", math.max(8, columns - 2)))
end

--- How many request rows fit. Kept here rather than in inspector.lua's
--- pure arithmetic because it is about this specific view's chrome (its
--- title, header, rule and detail pane), not about scrolling in general.
--- @param rows integer Terminal height.
--- @return integer
function M.visible_rows(rows)
  rows = math.floor(tonumber(rows) or 0)
  if rows <= 0 then
    rows = inspector.FALLBACK_ROWS
  end
  return math.max(M.MIN_ROWS, rows - inspector.CHROME_ROWS)
end

--- The history actually on screen right now: `state.history` itself, or a
--- `filtered_view` over it when the filter bar holds a non-empty query.
---
--- SHARED, deliberately, with ui/app.lua's key handler (`move`, `g`/`G`).
--- That handler used to clamp against `state.history:count()` -- the RAW,
--- unfiltered count -- while this view was already clamping against the
--- FILTERED count for painting. The two agreeing by coincidence (no filter
--- active) hid the bug; the moment a filter shrank the visible list below
--- the stored selection, up/down kept clamping the selection against the
--- big unfiltered count, so it wandered around way outside what was on
--- screen and the painted cursor -- which this view always re-clamps
--- locally -- looked stuck. One function, called from both places, means
--- the count used to clamp a keypress and the count used to paint a frame
--- can never disagree again.
--- @param state table From ui.app's new_state (it owns `history` and `search`).
--- @return table history, integer count
function M.visible_history(state)
  local parsed = query.parse(state.search and state.search().text or "")
  local history = state.history
  if not parsed.empty then
    history = inspector.filtered_view(state.history, function(event)
      return query.matches(event, parsed)
    end)
  end
  return history, history:count()
end

--- @param state table From ui.app's new_state (it owns `history`,
---   `selection` and `requests_revision`).
--- @return fun(): fun(): any A Hydronium component.
function M.create_view(state)
  return function()
    -- Created ONCE in setup, not per render: `search_bar.create` returns a new
    -- component type each call, and a fresh type every render would remount
    -- the bar -- losing focus, caret and text on every keystroke.
    local SearchBar = search_bar.create(state)

    return function()
      -- Reactive: a resize re-runs this closure, so the window and the
      -- path column both follow the real terminal.
      local size = hooks.useWindowSize()
      local columns = (size and size.columns and size.columns > 0) and size.columns
        or inspector.FALLBACK_COLUMNS
      local rows = (size and size.rows and size.rows > 0) and size.rows or inspector.FALLBACK_ROWS

      -- Read the revision signal so new requests repaint the list. The
      -- history itself is an ordinary table (2000 events is not something
      -- to copy into a signal on every event); the revision counter is
      -- what makes reading it reactive.
      state.requests_revision()
      -- Subscribe to the filter too, so a keystroke in the bar re-windows the
      -- list immediately rather than waiting for the next request.
      state.search_revision()

      local history, count = M.visible_history(state)
      local selection = inspector.clamp_selection(state.selection(), count)
      local height = M.visible_rows(rows)
      -- Plain-field write (NOT a signal -- see ui/app.lua's own note on
      -- `viewport_rows`): the key handler needs the row count this view
      -- actually painted with to size a PageUp/PageDown jump. Nothing
      -- re-renders because of it.
      state.viewport_rows = height
      local first, last = inspector.window(count, selection, height)

      local children = {}

      local title
      if count == 0 then
        -- Distinguish "nothing has happened yet" from "a filter hid
        -- everything" -- `history.total` only exists on a filtered_view
        -- (see inspector.filtered_view), so its presence alone says which
        -- case this is. Saying "none captured yet" while N requests sit
        -- behind the filter would read as the dev server having gone
        -- quiet, which is the opposite of what happened.
        if history.total then
          title = string.format("Requests - none match filter (0 of %d)", history.total)
        else
          title = "Requests - none captured yet"
        end
      else
        title = string.format("Requests %d-%d of %d", first, last, count)
        if history.total then
          title = title .. string.format(" (filtered from %d)", history.total)
        end
      end
      if history.dropped > 0 then
        title = title .. string.format(" (%d older dropped)", history.dropped)
      end

      children[#children + 1] = hydronium.h(SearchBar)

      children[#children + 1] = hydronium.h(ink.Box, { flexDirection = "row" },
        hydronium.h(ink.Text, { bold = true }, " " .. title),
        hydronium.h(ink.Spacer),
        -- ASCII ONLY, like every other string this view paints -- see
        -- src/inspector.lua's note on why (the host's incremental diff
        -- positions runs by frame column, and it paints one cell per BYTE).
        hydronium.h(ink.Text, { dimColor = true },
          "/ filter | f/esc exit | j/k scroll | g/G ends | q quit ")
      )

      children[#children + 1] = hydronium.h(ink.Text, { dimColor = true, bold = true },
        inspector.header_row(columns, { show_ips = state.show_ips }))

      if count == 0 then
        local empty_message = history.total
          and "  no requests match the current filter"
          or "  waiting for the first request -- the dev server has not served one yet"
        children[#children + 1] = hydronium.h(ink.Text, { dimColor = true }, empty_message)
      else
        for _, row in ipairs(history:slice(first, last)) do
          local selected = row.index == selection
          children[#children + 1] = hydronium.h(ink.Text, {
            key = "row-" .. row.index,
            dimColor = not selected,
            bold = selected,
          }, inspector.format_row(row.event, {
            columns = columns,
            show_ips = state.show_ips,
            selected = selected,
          }))
        end
      end

      children[#children + 1] = hydronium.h(ink.Newline)
      children[#children + 1] = rule(columns)

      local detail = inspector.detail_lines(count > 0 and history:get(selection) or nil, { columns = columns })
      for index, line in ipairs(detail) do
        children[#children + 1] = hydronium.h(ink.Text, {
          key = "detail-" .. index,
          dimColor = line.dim or false,
          color = line.color,
        }, " " .. string.rep(" ", line.indent or 0) .. line.text)
      end

      -- EXPLICIT WIDTH, for two reasons. (1) It pins the frame to the real
      -- terminal width, so a line that measures wider than the terminal can
      -- only be clipped at the frame edge rather than widening the frame
      -- into a wrapping mess. (2) It gives the title row's Spacer
      -- something to push against: without a bounded width the row sizes
      -- to its content and the key hints would sit next to the title
      -- instead of at the right edge.
      return hydronium.h(ink.Box, { flexDirection = "column", width = columns },
        unpack(children))
    end
  end
end

return M
