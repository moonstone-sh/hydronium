--[[
  hydronium_cli.ui.search_field -- caret, selection and word motion.
  Pure state in, pure state out: no pty involved.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local field = require("ui.search_field")

local function press(state, key, input)
  local s = field.handle_key(state, { input = input or "", key = key or {} })
  return s
end

local function typed(text)
  local s = field.new_state("")
  for i = 1, #text do
    s = press(s, {}, text:sub(i, i))
  end
  return s
end

describe("hydronium_cli.ui.search_field -- typing and caret", function()
  it("inserts at the caret and tracks position", function()
    local s = typed("method:GET")
    assert.equal(s.text, "method:GET")
    assert.equal(s.cursor, 10)
  end)

  it("inserts in the middle rather than appending", function()
    local s = typed("methodGET")
    s = press(s, {}, "")
    s.cursor = 6
    s = press(s, {}, ":")
    assert.equal(s.text, "method:GET")
    assert.equal(s.cursor, 7)
  end)

  it("moves by character and clamps at both ends", function()
    local s = typed("ab")
    s = press(s, { leftArrow = true })
    assert.equal(s.cursor, 1)
    s = press(s, { leftArrow = true })
    s = press(s, { leftArrow = true })
    assert.equal(s.cursor, 0, "must not go below zero")
    for _ = 1, 5 do s = press(s, { rightArrow = true }) end
    assert.equal(s.cursor, 2, "must not go past the end")
  end)

  it("backspaces and deletes around the caret", function()
    local s = typed("abc")
    s = press(s, { backspace = true })
    assert.equal(s.text, "ab")
    s = press(s, { home = true })
    s = press(s, { delete = true })
    assert.equal(s.text, "b")
  end)
end)

describe("hydronium_cli.ui.search_field -- selection (needs Kitty modifiers)", function()
  it("extends a selection with Shift+arrow", function()
    local s = typed("method:GET")
    s = press(s, { leftArrow = true, shift = true })
    s = press(s, { leftArrow = true, shift = true })
    s = press(s, { leftArrow = true, shift = true })
    local from, to = field.selection(s)
    assert.equal(from, 7)
    assert.equal(to, 10)
    assert.equal(s.text:sub(from + 1, to), "GET")
  end)

  it("replaces the selection when you type over it", function()
    local s = typed("method:GET")
    for _ = 1, 3 do s = press(s, { leftArrow = true, shift = true }) end
    s = press(s, {}, "P")
    assert.equal(s.text, "method:P")
    assert.equal(field.selection(s), nil, "typing must clear the selection")
  end)

  it("deletes the selection on backspace", function()
    local s = typed("method:GET")
    for _ = 1, 3 do s = press(s, { leftArrow = true, shift = true }) end
    s = press(s, { backspace = true })
    assert.equal(s.text, "method:")
  end)

  it("collapses to the selection edge on a plain arrow", function()
    local s = typed("abcdef")
    for _ = 1, 3 do s = press(s, { leftArrow = true, shift = true }) end
    s = press(s, { leftArrow = true })
    assert.equal(s.cursor, 3, "plain Left collapses to the selection start")
    assert.equal(field.selection(s), nil)
  end)

  it("copies the selection through an intent, since the clipboard is OSC 52", function()
    local s = typed("method:GET")
    for _ = 1, 3 do s = press(s, { leftArrow = true, shift = true }) end
    local _, intent = field.handle_key(s, { input = "c", key = { ctrl = true } })
    assert.equal(intent.type, "copy")
    assert.equal(intent.text, "GET")
  end)

  it("reports no copy intent with nothing selected", function()
    local s = typed("abc")
    local _, intent = field.handle_key(s, { input = "c", key = { ctrl = true } })
    assert.equal(intent, nil)
  end)
end)

describe("hydronium_cli.ui.search_field -- word and line motion", function()
  it("moves by word with Alt+arrow", function()
    local s = typed("method:GET status:200")
    s = press(s, { leftArrow = true, alt = true })
    assert.equal(s.cursor, 11, "Alt+Left lands at the start of the last word")
    s = press(s, { rightArrow = true, alt = true })
    assert.equal(s.cursor, 21)
  end)

  it("jumps to the edges with Super+arrow and with Ctrl+A/E", function()
    local s = typed("method:GET")
    s = press(s, { leftArrow = true, super = true })
    assert.equal(s.cursor, 0)
    s = press(s, { rightArrow = true, super = true })
    assert.equal(s.cursor, 10)
    s = press(s, { ctrl = true }, "a")
    assert.equal(s.cursor, 0)
    s = press(s, { ctrl = true }, "e")
    assert.equal(s.cursor, 10)
  end)

  it("kills words and lines with the readline bindings", function()
    local s = typed("method:GET status:200")
    s = press(s, { ctrl = true }, "w")
    assert.equal(s.text, "method:GET ")
    s = press(s, { ctrl = true }, "u")
    assert.equal(s.text, "")

    local t = typed("method:GET status:200")
    t = press(t, { leftArrow = true, alt = true })
    t = press(t, { ctrl = true }, "k")
    assert.equal(t.text, "method:GET ")
  end)

  it("selects all with Super+A", function()
    local s = typed("method:GET")
    s = press(s, { super = true }, "a")
    local from, to = field.selection(s)
    assert.equal(from, 0)
    assert.equal(to, 10)
  end)
end)

describe("hydronium_cli.ui.search_field -- paste and control bytes", function()
  it("inserts bracketed-paste text, flattening newlines", function()
    local s = field.new_state("a")
    s = field.handle_key(s, { type = "paste", text = "b\nc" })
    assert.equal(s.text, "ab c", "a newline would make the one-line field unrenderable")
  end)

  it("never inserts a raw control character", function()
    local s = field.new_state("")
    s = press(s, {}, "\1")
    assert.equal(s.text, "", "an unhandled control byte must not land in the text")
  end)

  it("paste replaces a selection", function()
    local s = typed("abc")
    for _ = 1, 3 do s = press(s, { leftArrow = true, shift = true }) end
    s = field.handle_key(s, { type = "paste", text = "xy" })
    assert.equal(s.text, "xy")
  end)
end)
