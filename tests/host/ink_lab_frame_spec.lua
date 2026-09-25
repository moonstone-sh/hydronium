local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local lab = require("hydronium_lab")
local inkLab = require("hydronium_ink_lab")
local frame = require("hydronium_ink_lab.frame")
local snapshot = require("hydronium_ink_lab.snapshot")

-- Reference decoder mirroring the client's `applyFrame`: reconstructs a full
-- per-cell grid ({ [y] = { [x] = { style = id, ch = "..." } } }) from a
-- sequence of encoded frames, so Lua-side tests can assert delta application
-- reproduces the same grid a full frame would have described directly.
local function new_model()
  return { width = 0, height = 0, cells = {}, styles = {} }
end

local function apply(model, encoded)
  if encoded.styles then
    for id, style in pairs(encoded.styles) do model.styles[tonumber(id)] = style end
  end
  if encoded.kind == "full" then
    model.width, model.height, model.cells = encoded.width, encoded.height, {}
    for y = 1, encoded.height do
      local row, x = {}, 1
      model.cells[y] = row
      for _, run in ipairs(encoded.rows[y]) do
        local styleId, chars = run[1], run[2]
        for _, ch in ipairs(chars) do
          row[x] = { style = styleId, ch = ch }
          x = x + 1
        end
      end
    end
  elseif encoded.kind == "delta" then
    for _, change in ipairs(encoded.changes or {}) do
      -- Wire coordinates are 0-based; this Lua model is 1-based.
      local y, x0, styleId, chars = change[1] + 1, change[2] + 1, change[3], change[4]
      local row = model.cells[y]
      for offset, ch in ipairs(chars) do
        row[x0 + offset - 1] = { style = styleId, ch = ch }
      end
    end
  else
    error("unknown frame kind " .. tostring(encoded.kind))
  end
  return model
end

--- Flattens a `snapshot.from_session` table (or the reference decoder's
--- model) into `{ [y] = { [x] = { fg, bg, bold, ..., ch } } }` with style
--- fields fully resolved, so a full-vs-delta round trip can be compared
--- field-by-field regardless of which integer id either path assigned.
local function resolve(source, styles)
  local out = {}
  for y = 1, source.height do
    out[y] = {}
    for x = 1, source.width do
      local cell = source.rows and source.rows[y][x] or source.cells[y][x]
      if styles then
        local style = styles[cell.style]
        out[y][x] = { ch = cell.ch, fg = style.fg, bg = style.bg, bold = style.bold, dim = style.dim,
          italic = style.italic, underline = style.underline, strikethrough = style.strikethrough, inverse = style.inverse }
      else
        out[y][x] = { ch = cell.ch, fg = cell.fg, bg = cell.bg, bold = cell.bold, dim = cell.dim,
          italic = cell.italic, underline = cell.underline, strikethrough = cell.strikethrough, inverse = cell.inverse }
      end
    end
  end
  return out
end

describe("hydronium_ink_lab.frame", function()
  it("encodes a full frame as style-interned row runs that decode back to the exact snapshot", function()
    local setColor
    local function Demo()
      local color
      color, setColor = hydronium.signal("#ff0000")
      return function()
        return hydronium.h(ink.Box, nil,
          hydronium.h(ink.Text, { color = color(), bold = true }, "AA"),
          hydronium.h(ink.Text, nil, "  "))
      end
    end
    local registry = lab.registry({ lab.story({
      id = "frame/demo", render = function() return hydronium.h(Demo) end,
      sizes = { { name = "s", columns = 6, rows = 2 } },
    }) })
    local runtime = inkLab.new(registry)
    local full = runtime:request({ op = "open", story = "frame/demo" })
    assert.equal(full.version, 2)
    assert.equal(full.kind, "full")
    assert.equal(full.seq, 1)
    assert.truthy(full.styles)
    assert.truthy(full.rows)

    local raw = snapshot.from_session(runtime.active)
    local model = apply(new_model(), full)
    assert.same(resolve(model, model.styles), resolve(raw))

    -- The two "AA" cells share one bold-red style and must collapse into a
    -- single run rather than two separate per-cell records.
    local first_row_runs = full.rows[1]
    assert.equal(#first_row_runs[1][2], 2)
    assert.equal(first_row_runs[1][2][1], "A")
    assert.equal(first_row_runs[1][2][2], "A")
  end)

  it("reuses style ids across frames and only ships styles the peer hasn't seen", function()
    local styles = frame._new_style_table()
    local red = { ch = "x", fg = { kind = "rgb", r = 255, g = 0, b = 0 }, bg = nil, bold = false, dim = false, italic = false, underline = false, strikethrough = false, inverse = false }
    local also_red = { ch = "y", fg = { kind = "rgb", r = 255, g = 0, b = 0 }, bg = nil, bold = false, dim = false, italic = false, underline = false, strikethrough = false, inverse = false }
    local blue = { ch = "z", fg = { kind = "rgb", r = 0, g = 0, b = 255 }, bg = nil, bold = false, dim = false, italic = false, underline = false, strikethrough = false, inverse = false }

    styles:begin_frame()
    local id_red = styles:intern(red)
    local id_also_red = styles:intern(also_red)
    assert.equal(id_red, id_also_red)
    local id_blue = styles:intern(blue)
    assert.truthy(id_blue ~= id_red)
    local first_payload = styles:styles_payload(false)
    assert.truthy(first_payload[tostring(id_red)])
    assert.truthy(first_payload[tostring(id_blue)])

    -- A later frame that reuses the same two styles (plus nothing new) must
    -- omit the styles table entirely rather than resend known entries.
    styles:begin_frame()
    styles:intern(red)
    styles:intern(blue)
    assert.equal(styles:styles_payload(false), nil)
  end)

  it("encodes changed cells only as a delta -- including a style change -- and a resize as a fresh full frame", function()
    local setValue, setColor
    local function Demo()
      local value, color
      value, setValue = hydronium.signal("idle......")
      color, setColor = hydronium.signal("#00ff00")
      hooks.useInput(function(input)
        if input == "r" then setColor("#0000ff") else setValue(input .. value():sub(1, 9)) end
      end)
      return function() return hydronium.h(ink.Text, { color = color() }, value()) end
    end
    local registry = lab.registry({ lab.story({
      id = "frame/delta", render = function() return hydronium.h(Demo) end,
      sizes = { { name = "s", columns = 10, rows = 1 } },
    }) })
    local runtime = inkLab.new(registry)
    local full = runtime:request({ op = "open", story = "frame/delta" })
    local model = apply(new_model(), full)
    assert.same(resolve(model, model.styles), resolve(snapshot.from_session(runtime.active)))

    -- A plain text change: still a delta, and it must decode back to the
    -- session's real current frame.
    local delta = runtime:request({ op = "input", input = "x", key = {} })
    assert.equal(delta.kind, "delta")
    assert.equal(delta.base, full.seq)
    assert.equal(delta.seq, full.seq + 1)
    assert.truthy(delta.changes and #delta.changes >= 1)
    apply(model, delta)
    assert.same(resolve(model, model.styles), resolve(snapshot.from_session(runtime.active)))

    -- A style-only change (recolor, same characters) is still a delta and
    -- must carry a freshly interned style id plus the cells it now covers.
    local recolor = runtime:request({ op = "input", input = "r", key = {} })
    assert.equal(recolor.kind, "delta")
    assert.truthy(recolor.styles, "a genuinely new style must be shipped, not silently reused")
    apply(model, recolor)
    assert.same(resolve(model, model.styles), resolve(snapshot.from_session(runtime.active)))

    -- Resizing changes the canvas: it must be a full, self-contained frame
    -- (never a delta) regardless of how little else changed, and decoding it
    -- from scratch must reproduce the resized session's real frame exactly.
    local resized = runtime:request({ op = "resize", columns = 4, rows = 2 })
    assert.equal(resized.kind, "full")
    assert.equal(resized.width, 4)
    assert.equal(resized.height, 2)
    model = apply(new_model(), resized)
    assert.same(resolve(model, model.styles), resolve(snapshot.from_session(runtime.active)))

    -- And the stream keeps diffing correctly after that resize.
    local after_resize_delta = runtime:request({ op = "input", input = "z", key = {} })
    assert.equal(after_resize_delta.kind, "delta")
    assert.equal(after_resize_delta.base, resized.seq)
    apply(model, after_resize_delta)
    assert.same(resolve(model, model.styles), resolve(snapshot.from_session(runtime.active)))
  end)

  it("addresses delta changes with 0-based wire coordinates, as the browser indexes them", function()
    -- The client computes `y * width + x`; 1-based coordinates painted every
    -- change one row down and one column right, so cells an overlay had
    -- covered were never restored.
    local function raw(top_left, bottom_right)
      local function cell(ch) return { ch = ch } end
      return { width = 2, height = 2, rows = {
        { cell(top_left), cell(".") },
        { cell("."), cell(bottom_right) },
      } }
    end
    local stream = frame.new_stream()
    frame.encode(stream, raw("a", "b"), true)
    local delta = frame.encode(stream, raw("x", "b"), false)
    assert.equal(#delta.changes, 1)
    assert.equal(delta.changes[1][1], 0, "top row is y = 0")
    assert.equal(delta.changes[1][2], 0, "left column is x = 0")
    delta = frame.encode(stream, raw("x", "y"), false)
    assert.equal(delta.changes[1][1], 1)
    assert.equal(delta.changes[1][2], 1)
  end)

  it("never emits an ambiguous empty changes/styles table on an idle tick", function()
    local registry = lab.registry({ lab.story({
      id = "frame/idle", render = function() return hydronium.h(ink.Text, nil, "static") end,
      sizes = { { name = "s", columns = 10, rows = 1 } },
    }) })
    local runtime = inkLab.new(registry)
    runtime:request({ op = "open", story = "frame/idle" })
    local idle = runtime:request({ op = "step", nowMs = 1 })
    assert.equal(idle.kind, "delta")
    assert.equal(idle.changes, nil)
    assert.equal(idle.styles, nil)
  end)
end)
