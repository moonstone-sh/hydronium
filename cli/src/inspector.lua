--[[
  hydronium-cli inspector -- the pure half of the FULLSCREEN REQUEST-DEBUG
  MODE (`hydronium dev --fullscreen`, or `f` at runtime): a capped history
  of every `request` event, the selection/scroll-window arithmetic a
  scrollable list needs, and the row/detail formatting the view paints.

  PURE BY CONTRACT, exactly like event_model.lua: no files, no processes,
  no clock, no terminal. Every input is an already-parsed event and every
  output is a plain table or string, which is what makes the whole scroll
  and follow-the-tail behaviour testable with a canned array of events and
  no terminal anywhere (see cli/tests/inspector_spec.lua).

  WHY THIS IS NOT THE DISPLAY BUFFER IN event_model.lua. That buffer is a
  3-to-12 row ring that COLLAPSES consecutive repeats into `x7` and evicts
  everything older -- correct for a 4-line persistent status view, useless
  for debugging, since the thing you need is usually the one request that
  got folded away. This history does the opposite: no collapsing, one row
  per request, oldest dropped only when MAX_HISTORY is reached. The two
  live side by side, fed from the same drain loop (see src/main.lua).

  SCROLLING WITHOUT AN INK SCROLL PRIMITIVE. hydronium_ink has no
  scroll-offset capability -- `Box`'s `overflow = "hidden"` clips, it does
  not scroll (see ink/src/hydronium_ink/init.lua's own prop list, which
  says "scroll" is treated identically to "hidden"). Adding a real
  scrollable viewport to ink would mean a windowed layout pass inside the
  host, which is a much larger change than this mode needs, so scrolling
  lives HERE instead: `M.window()` picks the slice of rows that fits the
  terminal, and the view paints exactly that slice. Nothing in ink had to
  learn about scrolling for this (the one thing ink did have to learn is
  the alternate screen buffer, which genuinely cannot be done from a
  package -- it needs render()'s own teardown to guarantee leaving it).

  DERIVED SCROLL, NOT STORED SCROLL. There is no scroll-offset state: the
  window is computed from (count, selection, height) every render. A
  stored offset plus a stored selection is two pieces of state that can
  disagree (selection scrolled off screen, offset past the end after
  eviction); one derived from the other cannot.
--]]

local event_model = require("event_model")

local M = {}

--- Hard cap on retained requests. Each retained event is a small parsed
--- table, so this is on the order of a couple of hundred KB at worst --
--- but it must be bounded: a dev server left running for a day behind a
--- polling browser will emit far more than this.
M.MAX_HISTORY = 2000

--- Rows reserved by the fullscreen chrome (title line, column header,
--- separator, and the detail pane) when computing how many request rows
--- fit. Used by the view; kept here so the arithmetic and its consumer
--- cannot drift apart.
M.CHROME_ROWS = 12

--- Fallback viewport when the terminal reports no size at all (a non-TTY
--- run, e.g. this CLI driven from a spec or piped into a file).
M.FALLBACK_ROWS = 24
M.FALLBACK_COLUMNS = 100

-- ---------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------

local History = {}
History.__index = History
M.History = History

--- @param opts? { capacity?: integer }
--- @return table
function M.new_history(opts)
  opts = opts or {}
  local capacity = opts.capacity or M.MAX_HISTORY
  if type(capacity) ~= "number" or capacity < 1 then
    error("inspector.new_history: capacity must be a positive number, got " .. tostring(opts.capacity), 2)
  end
  return setmetatable({
    capacity = math.floor(capacity),
    events = {},
    dropped = 0,
  }, History)
end

--- Appends one event IF it is a request; anything else is ignored, so
--- callers can hand this every event they see without filtering first.
--- @param event table
--- @return boolean accepted
function History:push(event)
  if not event_model.is_request(event) then
    return false
  end
  self.events[#self.events + 1] = event
  while #self.events > self.capacity do
    table.remove(self.events, 1)
    self.dropped = self.dropped + 1
  end
  return true
end

--- @param events table[]
--- @return integer accepted
function History:push_all(events)
  local count = 0
  for _, event in ipairs(events or {}) do
    if self:push(event) then
      count = count + 1
    end
  end
  return count
end

--- @return integer
function History:count()
  return #self.events
end

--- @param index integer 1-based, oldest first.
--- @return table|nil
function History:get(index)
  return self.events[index]
end

--- @param first integer
--- @param last integer
--- @return table[] rows `{ index, event }` entries, clamped to what exists.
function History:slice(first, last)
  local out = {}
  for index = math.max(1, first), math.min(#self.events, last) do
    out[#out + 1] = { index = index, event = self.events[index] }
  end
  return out
end

function History:clear()
  self.events = {}
end

-- ---------------------------------------------------------------------
-- Selection + scroll window
-- ---------------------------------------------------------------------

--- @param selection integer
--- @param count integer
--- @return integer selection 0 when there is nothing to select.
function M.clamp_selection(selection, count)
  if count <= 0 then
    return 0
  end
  selection = math.floor(tonumber(selection) or 0)
  if selection < 1 then
    return 1
  end
  if selection > count then
    return count
  end
  return selection
end

--- Moves the selection by `delta` rows, clamped at both ends (no wrapping
--- -- a debug list is not a carousel; hitting the top and staying there is
--- what every pager does).
---
--- `selection` is clamped into `[1, count]` BEFORE `delta` is applied, not
--- after. A caller can hand this a `selection` that is stale relative to
--- `count` -- typically because the list just shrank under a filter and
--- nothing has re-clamped the stored selection yet -- and clamping only
--- the SUM would strand that staleness: e.g. `move_selection(50, 1, 3)`
--- computes 51, clamps to 3, same as before the delta, so the very next
--- press looks identical and the list appears frozen. Pressing the same
--- key enough times eventually walks the stale value back into range by
--- accident, which read as "arrow keys stop working" for exactly as many
--- presses as the selection had drifted. Clamping first means the first
--- press after a shrink both snaps into range AND moves, in one step.
--- @param selection integer
--- @param delta integer
--- @param count integer
--- @return integer
function M.move_selection(selection, delta, count)
  if count <= 0 then
    return 0
  end
  local current = M.clamp_selection(selection, count)
  return M.clamp_selection(current + (delta or 0), count)
end

--- FOLLOW-THE-TAIL RULE: the selection stays pinned to the newest row
--- while it already IS the newest row, and holds its place otherwise, so
--- live traffic does not yank the row you are reading out from under you.
--- Eviction (count shrinking at the oldest end) shifts the selection by
--- however many rows were dropped, for the same reason.
--- @param selection integer
--- @param previous_count integer
--- @param new_count integer
--- @param dropped? integer Rows evicted off the oldest end since the last call.
--- @return integer
function M.follow_tail(selection, previous_count, new_count, dropped)
  dropped = dropped or 0
  if previous_count <= 0 or (selection or 0) <= 0 then
    -- Nothing was selected: default to the newest row, which is what a
    -- live log view should show first.
    return M.clamp_selection(new_count, new_count)
  end
  if selection >= previous_count then
    return M.clamp_selection(new_count, new_count)
  end
  return M.clamp_selection(selection - dropped, new_count)
end

--- The visible slice: `height` rows that always contain `selection`,
--- preferring to keep the selection roughly where it already was rather
--- than re-centering on every keypress (which makes a list feel like it
--- is sliding under a fixed cursor).
--- @param count integer
--- @param selection integer
--- @param height integer
--- @return integer first, integer last
function M.window(count, selection, height)
  height = math.max(1, math.floor(tonumber(height) or 1))
  if count <= 0 then
    return 1, 0
  end
  if count <= height then
    return 1, count
  end

  selection = M.clamp_selection(selection, count)
  -- Keep the selection vertically centered-ish, then clamp so the window
  -- never runs off either end (which would show blank rows below the
  -- newest request).
  local first = selection - math.floor(height / 2)
  if first < 1 then
    first = 1
  end
  if first + height - 1 > count then
    first = count - height + 1
  end
  return first, first + height - 1
end

--- Rows a page-up/page-down should move: a full screen minus one row of
--- overlap, so the row you were looking at stays visible as an anchor.
--- @param height integer
--- @return integer
function M.page_size(height)
  return math.max(1, math.floor(tonumber(height) or 1) - 1)
end

-- ---------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------

local function pad(text, width)
  text = tostring(text)
  if #text >= width then
    return text
  end
  return text .. string.rep(" ", width - #text)
end

local function pad_left(text, width)
  text = tostring(text)
  if #text >= width then
    return text
  end
  return string.rep(" ", width - #text) .. text
end

--- ASCII ONLY IN THIS VIEW, and it is not an aesthetic choice. The
--- terminal host paints ONE GRID CELL PER BYTE, so a 2-byte `\194\183` or a
--- 3-byte `\226\150\184` makes the frame's column numbering drift from the real
--- terminal's. That is harmless while a whole row is repainted in one run
--- (the bytes simply flow out in order), but the host's incremental diff
--- positions each changed run with an absolute `ESC[row;colH` computed from
--- FRAME columns -- so a run starting after a multi-byte character lands in
--- the wrong terminal column. Observed for real: replacing a longer detail
--- line with a shorter one rendered `8.0.0858 8` instead of `8.8.8.8`.
--- Fixing ink's cell model to count characters (and wide characters) is a
--- much larger change than this view needs; staying ASCII here sidesteps it
--- entirely. The compact status view keeps its `\194\183` separators, which it
--- has always had.

--- Byte-truncation with an ASCII marker, matching the "..." convention
--- event_model.lua's own `one_line` already uses. No wide-character width
--- accounting anywhere in this repo's terminal stack (see
--- host/terminal.lua's own note), so this counts bytes, like everything
--- else here does.
--- @param text string
--- @param width integer
--- @return string
function M.truncate(text, width)
  text = tostring(text)
  if width < 1 then
    return ""
  end
  if #text <= width then
    return text
  end
  if width <= 3 then
    return text:sub(1, width)
  end
  return text:sub(1, width - 3) .. "..."
end

M.METHOD_WIDTH = 7
M.STATUS_WIDTH = 6
M.DURATION_WIDTH = 8
M.REMOTE_WIDTH = 17

--- @param columns? integer Terminal width.
--- @param opts? { show_ips?: boolean }
--- @return integer
function M.path_width(columns, opts)
  opts = opts or {}
  columns = math.floor(tonumber(columns) or M.FALLBACK_COLUMNS)
  -- 2 leading cursor columns + method + status + duration (+ remote), then
  -- 3 columns of slack: the selection marker is a 3-BYTE character in one
  -- column and ink measures width in bytes (see host/terminal.lua), so a
  -- row that exactly filled the terminal by display width would measure
  -- two columns too wide.
  local fixed = 2 + M.METHOD_WIDTH + M.STATUS_WIDTH + M.DURATION_WIDTH
    + (opts.show_ips and M.REMOTE_WIDTH or 0)
  return math.max(10, columns - fixed - 3)
end

--- The column header, built from the same widths the rows are, so the two
--- cannot drift.
--- @param columns? integer
--- @param opts? { show_ips?: boolean }
--- @return string
function M.header_row(columns, opts)
  opts = opts or {}
  local parts = {
    "  ",
    pad("METHOD", M.METHOD_WIDTH),
    pad(M.truncate("PATH", M.path_width(columns, opts)), M.path_width(columns, opts)),
    pad_left("STATUS", M.STATUS_WIDTH),
    pad_left("TIME", M.DURATION_WIDTH),
  }
  if opts.show_ips then
    parts[#parts + 1] = "  " .. pad("REMOTE", M.REMOTE_WIDTH)
  end
  return table.concat(parts)
end

--- One fixed-width request row.
---
--- `remote_addr` is shown here only under `--show-ips`, the same opt-in
--- the collapsed status view honours -- the address is in the durable log
--- either way, and the detail pane below the list always shows it, so
--- nothing is hidden, it just is not painted into every row by default.
--- @param event table A `request` event.
--- @param opts? { columns?: integer, show_ips?: boolean, selected?: boolean }
--- @return string
function M.format_row(event, opts)
  opts = opts or {}
  local detail = event_model.request_detail(event)
  local width = M.path_width(opts.columns, opts)
  local parts = {
    opts.selected and "> " or "  ",
    pad(M.truncate(detail.method, M.METHOD_WIDTH - 1), M.METHOD_WIDTH),
    pad(M.truncate(detail.path, width), width),
    pad_left(detail.status and tostring(detail.status) or "-", M.STATUS_WIDTH),
    pad_left(detail.duration_ms and (string.format("%dms", math.floor(detail.duration_ms + 0.5))) or "-",
      M.DURATION_WIDTH),
  }
  if opts.show_ips then
    parts[#parts + 1] = "  " .. pad(M.truncate(detail.remote_addr or "-", M.REMOTE_WIDTH), M.REMOTE_WIDTH)
  end
  return table.concat(parts)
end

--- A status's colour band, for the view's own `color` prop. Deliberately
--- the same rule event_model's label uses to decide a status is worth
--- showing at all: 2xx/3xx are unremarkable, 4xx is yours, 5xx is the
--- server's.
--- @param status integer|nil
--- @return string|nil
function M.status_color(status)
  if not status then
    return nil
  end
  if status >= 500 then
    return "red"
  end
  if status >= 400 then
    return "yellow"
  end
  if status >= 300 then
    return "cyan"
  end
  return "green"
end

--- The detail pane for one request: the full record, including the
--- headers/body PLACEHOLDER that is the honest state of this today.
---
--- The placeholder text names the reason explicitly rather than saying
--- "none": meteorite's dev-event emitter does not capture headers or
--- bodies at all yet (zig/server/dev_events.zig emits method/path/status/
--- duration/remote_addr), so "no headers" would read as "this request had
--- no headers", which is a different and false statement. When a newer
--- meteorite does emit them, the same lines render the real content with
--- no other change (see event_model.request_detail).
--- @param event table|nil
--- @param opts? { columns?: integer, body_lines?: integer }
--- @return table[] lines `{ text, dim?, color?, indent? }` entries.
function M.detail_lines(event, opts)
  opts = opts or {}
  local columns = math.floor(tonumber(opts.columns) or M.FALLBACK_COLUMNS)
  local body_lines = opts.body_lines or 4

  if not event then
    return { { text = "no requests captured yet", dim = true } }
  end

  local detail = event_model.request_detail(event)
  local out = {}

  local summary = { detail.method .. " " .. detail.path }
  if detail.status then
    summary[#summary + 1] = tostring(detail.status)
  end
  if detail.duration_ms then
    summary[#summary + 1] = string.format("%dms", math.floor(detail.duration_ms + 0.5))
  end
  summary[#summary + 1] = detail.remote_addr or "remote_addr not reported"
  out[#out + 1] = {
    text = M.truncate(table.concat(summary, " | "), columns - 2),
    color = M.status_color(detail.status),
  }

  if detail.has_headers then
    if #detail.headers == 0 then
      out[#out + 1] = { text = "headers: captured, none present", dim = true }
    else
      out[#out + 1] = { text = "headers:" }
      for _, header in ipairs(detail.headers) do
        out[#out + 1] = {
          text = M.truncate(header.name .. ": " .. header.value, columns - 6),
          indent = 2,
          dim = true,
        }
      end
    end
  else
    out[#out + 1] = {
      text = "headers: not captured -- meteorite's dev-event stream carries no headers yet",
      dim = true,
    }
  end

  if detail.has_body then
    local size = detail.body_bytes and (" (" .. detail.body_bytes .. " bytes)") or ""
    out[#out + 1] = { text = "body" .. size .. ":" }
    if detail.body then
      local shown = 0
      for line in (detail.body .. "\n"):gmatch("([^\n]*)\n") do
        if shown >= body_lines then
          out[#out + 1] = { text = "...", indent = 2, dim = true }
          break
        end
        out[#out + 1] = { text = M.truncate(line, columns - 6), indent = 2, dim = true }
        shown = shown + 1
      end
    else
      out[#out + 1] = { text = "size reported, content not included", indent = 2, dim = true }
    end
  else
    out[#out + 1] = {
      text = "body: not captured -- meteorite's dev-event stream carries no bodies yet",
      dim = true,
    }
  end

  return out
end

--- A read-only History-shaped view over the subset of `history` matching
--- `predicate`.
---
--- Returned rather than filtering in the view itself so that every piece of
--- windowing arithmetic above (clamp_selection, window, page_size,
--- follow_tail) keeps operating on a single coherent count/get/slice
--- contract. A filter that only hid rows at paint time would leave the
--- selection indexing into the unfiltered list, which is how a "filtered"
--- list ends up opening the wrong detail pane.
---
--- Materialised eagerly: the caller re-renders on every keystroke, and 2000
--- capped entries is a cheap walk next to the reflow it triggers anyway.
--- @param history table
--- @param predicate fun(event: table): boolean
--- @return table view
function M.filtered_view(history, predicate)
  local matched = {}
  for i = 1, history:count() do
    local event = history:get(i)
    if event and predicate(event) then
      matched[#matched + 1] = event
    end
  end
  return {
    dropped = history.dropped,
    -- True count of the underlying list, so a view can say "3 of 412".
    total = history:count(),
    count = function() return #matched end,
    get = function(_, index) return matched[index] end,
    -- Same shape History:slice returns -- {index, event} pairs, NOT raw
    -- events. The view keys rows and compares the selection by `index`, so a
    -- view returning bare events renders nothing but a concatenation error.
    -- Indices are positions within the FILTERED list, which is what keeps the
    -- selection and the visible rows agreeing with each other.
    slice = function(_, first, last)
      local out = {}
      for i = math.max(1, first or 1), math.min(#matched, last or #matched) do
        out[#out + 1] = { index = i, event = matched[i] }
      end
      return out
    end,
  }
end

return M
