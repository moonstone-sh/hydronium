-- Compact wire encoding for hydronium_ink_lab frames, layered on top of the
-- unchanged `hydronium_ink_lab.snapshot` per-cell contract (version 1).
--
-- `snapshot.from_session` stays exactly as it was: a JSON-safe, one-record-
-- per-cell projection of Ink's canonical frame, and any existing direct
-- consumer of it keeps working unmodified. What was expensive was shipping
-- that shape over HTTP on every animation tick (one styled object per cell,
-- every field repeated even when almost nothing on screen changed). This
-- module turns a `snapshot.from_session` table into a much smaller "frame
-- protocol v2" message:
--
--   * a per-session style table -- each distinct combination of
--     fg/bg/bold/dim/italic/underline/strikethrough/inverse is interned once
--     and referenced by a small integer id thereafter; only styles the peer
--     hasn't already been sent are included on any given frame.
--   * row-run encoding -- consecutive cells sharing a style are grouped into
--     one `{styleId, {ch, ch, ...}}` run instead of one object per cell. The
--     characters stay a per-cell array (never concatenated into one string)
--     so a wide-glyph's empty continuation cell, or any other exact-cell
--     content, round-trips byte-for-byte.
--   * delta frames -- everything but the first frame of a session (and any
--     op that can change the canvas itself: open/resize/color/colorProfile/
--     snapshot) is encoded as only the cells that changed since the frame
--     before it, addressed as `{y, x, styleId, {ch, ...}}` runs.
--
-- One `Stream` is owned per Lab session (see runtime.lua) and lives exactly
-- as long as that session's active story: it holds the growing style table,
-- the running frame sequence counter, and the last snapshot/style-id grid it
-- encoded, so the next call can diff against it.
local M = {}

local FRAME_VERSION = 2

local function color_key(value)
  if not value then return "" end
  if value.kind == "rgb" then return "rgb:" .. value.r .. ":" .. value.g .. ":" .. value.b end
  return value.kind .. ":" .. value.index
end

local function bit(value) return value and "1" or "0" end

--- The style-identity key for a cell -- everything about it except which
--- character it holds. Two cells with the same key are visually identical
--- apart from their glyph and are always assigned the same style id.
local function style_key(cell)
  return color_key(cell.fg) .. "|" .. color_key(cell.bg) .. "|" .. bit(cell.bold) .. bit(cell.dim)
    .. bit(cell.italic) .. bit(cell.underline) .. bit(cell.strikethrough) .. bit(cell.inverse)
end

local function style_fields(cell)
  return {
    fg = cell.fg, bg = cell.bg, bold = cell.bold, dim = cell.dim, italic = cell.italic,
    underline = cell.underline, strikethrough = cell.strikethrough, inverse = cell.inverse,
  }
end

local StyleTable = {}
StyleTable.__index = StyleTable

local function new_style_table()
  return setmetatable({ ids = {}, objects = {}, next_id = 1, sent = {}, used = {} }, StyleTable)
end

--- Returns this cell's style id, interning it (a fresh, session-stable
--- integer) the first time this exact style is seen. Marks the id as "used
--- by the frame currently being built" so `styles_payload` knows to include
--- it when the peer hasn't seen it yet.
function StyleTable:intern(cell)
  local key = style_key(cell)
  local id = self.ids[key]
  if not id then
    id = self.next_id
    self.next_id = id + 1
    self.ids[key] = id
    self.objects[id] = style_fields(cell)
  end
  self.used[id] = true
  return id
end

function StyleTable:begin_frame()
  self.used = {}
end

--- Style entries to embed in the frame being built. `reset` (a full frame)
--- means the peer is about to rebuild its whole style cache from this
--- payload, so every style the frame references is included, not only the
--- ones it hasn't seen before -- a full frame is meant to stand alone.
--- Returns nil (never an empty table) when there is nothing new to send, so
--- callers can omit the field entirely rather than ship an empty JSON object
--- (or an ambiguous empty array/object) on every idle tick.
function StyleTable:styles_payload(reset)
  local payload, any = {}, false
  for id in pairs(self.used) do
    if reset or not self.sent[id] then
      payload[tostring(id)] = self.objects[id]
      any = true
    end
  end
  if reset then
    self.sent = {}
  end
  for id in pairs(self.used) do self.sent[id] = true end
  if any then return payload end
  return nil
end

--- One session's outgoing frame stream: the growing style table plus enough
--- of the previous frame (its per-cell style ids and characters) to diff the
--- next one against. `runtime.lua` owns exactly one of these per Lab
--- session and recreates it whenever `open` starts a new story.
function M.new_stream()
  return { styles = new_style_table(), seq = 0, last_ids = nil, last_chars = nil, width = nil, height = nil }
end

--- Encodes `raw` (a `snapshot.from_session` table) against `stream`,
--- producing a full frame when `force_full` is set, the stream has no prior
--- frame to diff against, or the canvas size changed since then -- and a
--- delta frame (only the cells that actually differ) otherwise. Advances
--- `stream` to remember this frame for the next call.
function M.encode(stream, raw, force_full)
  stream.seq = stream.seq + 1
  local styles = stream.styles
  styles:begin_frame()

  local full = force_full or not stream.last_ids or stream.width ~= raw.width or stream.height ~= raw.height
  local prev_ids, prev_chars = stream.last_ids, stream.last_chars
  local ids, chars = {}, {}
  local rows_out, changes_out
  if full then rows_out = {} else changes_out = {} end

  for y = 1, raw.height do
    local raw_row = raw.rows[y]
    local id_row, char_row = {}, {}
    ids[y], chars[y] = id_row, char_row
    local prev_id_row = prev_ids and prev_ids[y]
    local prev_char_row = prev_chars and prev_chars[y]
    local row_runs
    if full then
      row_runs = {}
      rows_out[y] = row_runs
    end
    local run_x, run_style, run_chars

    local function flush()
      if not run_style then return end
      if full then
        row_runs[#row_runs + 1] = { run_style, run_chars }
      else
        changes_out[#changes_out + 1] = { y, run_x, run_style, run_chars }
      end
      run_style = nil
    end

    for x = 1, raw.width do
      local cell = raw_row[x]
      local id = styles:intern(cell)
      id_row[x], char_row[x] = id, cell.ch
      local changed = full or prev_id_row[x] ~= id or prev_char_row[x] ~= cell.ch
      if changed then
        if run_style == id and run_x and run_x + #run_chars == x then
          run_chars[#run_chars + 1] = cell.ch
        else
          flush()
          run_x, run_style, run_chars = x, id, { cell.ch }
        end
      else
        flush()
      end
    end
    flush()
  end

  local encoded
  if full then
    encoded = {
      version = FRAME_VERSION, kind = "full", seq = stream.seq,
      width = raw.width, height = raw.height,
      color = raw.color, colorProfile = raw.colorProfile,
      cursor = raw.cursor, status = raw.status,
      styles = styles:styles_payload(true),
      rows = rows_out,
    }
  else
    encoded = {
      version = FRAME_VERSION, kind = "delta", seq = stream.seq, base = stream.seq - 1,
      cursor = raw.cursor, status = raw.status,
      styles = styles:styles_payload(false),
      changes = (#changes_out > 0) and changes_out or nil,
    }
  end
  stream.last_ids, stream.last_chars, stream.width, stream.height = ids, chars, raw.width, raw.height
  return encoded
end

M.FRAME_VERSION = FRAME_VERSION
-- Exposed for tests only (style interning correctness, key stability).
M._style_key = style_key
M._new_style_table = new_style_table

return M
