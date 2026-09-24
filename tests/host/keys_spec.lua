--[[
  hydronium_ink.keys -- real parsing behavior, not reasoned about.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local keys = require("hydronium_ink.keys")

describe("hydronium_ink.keys -- ANSI key-sequence parsing", function()
  it("parses a plain ASCII character with no key flags", function()
    local p = keys.newParser()
    local events = p:feed("a")
    assert.equal(#events, 1)
    assert.equal(events[1].input, "a")
    assert.equal(next(events[1].key), nil, "no key flags should be set for a plain character")
  end)

  it("parses a real multi-byte UTF-8 character as one event", function()
    local p = keys.newParser()
    -- U+00E9 'é', a real 2-byte UTF-8 sequence.
    local events = p:feed("\195\169")
    assert.equal(#events, 1)
    assert.equal(events[1].input, "\195\169")
  end)

  it("parses all four xterm CSI arrow-key sequences", function()
    local cases = {
      { bytes = "\27[A", field = "upArrow" },
      { bytes = "\27[B", field = "downArrow" },
      { bytes = "\27[C", field = "rightArrow" },
      { bytes = "\27[D", field = "leftArrow" },
    }
    for _, c in ipairs(cases) do
      local p = keys.newParser()
      local events = p:feed(c.bytes)
      assert.equal(#events, 1, "expected exactly one event for " .. c.field)
      assert.equal(events[1].input, "")
      assert.truthy(events[1].key[c.field], "expected key." .. c.field .. " to be true")
    end
  end)

  it("parses xterm CSI tilde sequences (Home/End/PageUp/PageDown/Delete)", function()
    local cases = {
      { bytes = "\27[1~", field = "home" },
      { bytes = "\27[3~", field = "delete" },
      { bytes = "\27[4~", field = "end" },
      { bytes = "\27[5~", field = "pageUp" },
      { bytes = "\27[6~", field = "pageDown" },
    }
    for _, c in ipairs(cases) do
      local p = keys.newParser()
      local events = p:feed(c.bytes)
      assert.equal(#events, 1, "expected exactly one event for " .. c.field)
      assert.truthy(events[1].key[c.field], "expected key." .. c.field .. " to be true")
    end
  end)

  it("parses named single-byte keys: Return, Tab, Backspace", function()
    local p = keys.newParser()
    local events = p:feed("\r\t\127")
    assert.equal(#events, 3)
    assert.truthy(events[1].key["return"])
    assert.truthy(events[2].key.tab)
    assert.truthy(events[3].key.backspace)
  end)

  it("parses Ctrl+<letter> distinctly from Tab/Return/Backspace even though they share the low byte range", function()
    local p = keys.newParser()
    -- Ctrl+A (0x01) is unambiguous; Tab (0x09/Ctrl+I) and Return
    -- (0x0D/Ctrl+M) must win as their own named keys, not generic ctrl+i/ctrl+m.
    local events = p:feed("\1")
    assert.equal(#events, 1)
    assert.equal(events[1].input, "a")
    assert.truthy(events[1].key.ctrl)
  end)

  it("handles a real multi-byte sequence arriving split across two separate feed() calls", function()
    local p = keys.newParser()
    local events1 = p:feed("\27")
    assert.equal(#events1, 0, "a lone ESC byte must not be finalized as a key event immediately")
    local events2 = p:feed("[A")
    assert.equal(#events2, 1)
    assert.truthy(events2[1].key.upArrow)
  end)

  it("finalizes a real standalone Escape keypress only after the timeout, not immediately", function()
    -- feed() stamps escPendingSinceMs with a real wall-clock reading
    -- (hydronium_ink.clock.nowMs(), a real epoch-ms value -- see that
    -- module's own doc comment for why NOT os.clock()) -- so the
    -- explicit nowMs values this test passes to flushTimedOut() must be
    -- offsets from that same real clock, not arbitrary small numbers.
    local baseMs = require("hydronium_ink.clock").nowMs()
    local p = keys.newParser()
    p:feed("\27")
    assert.equal(p:flushTimedOut(baseMs), nil, "must not fire before any time has passed")
    local event = p:flushTimedOut(baseMs + 1000)
    assert.truthy(event, "must fire once enough time has passed with nothing more arriving")
    assert.truthy(event.key.escape)
  end)

  it("does not fire the Escape timeout once real subsequent bytes complete the sequence", function()
    local p = keys.newParser()
    p:feed("\27")
    p:feed("[A") -- completes as an up-arrow before any timeout check runs
    assert.equal(p:flushTimedOut(999999), nil, "a completed sequence must never retroactively fire the ESC timeout")
  end)

  it("parses ESC[Z as Shift+Tab, distinct from plain Tab", function()
    local p = keys.newParser()
    local events = p:feed("\27[Z")
    assert.equal(#events, 1)
    assert.equal(events[1].input, "")
    assert.truthy(events[1].key.tab, "expected key.tab to be true")
    assert.truthy(events[1].key.shift, "expected key.shift to be true")
  end)

  it("does not set shift on plain Tab", function()
    local p = keys.newParser()
    local events = p:feed("\t")
    assert.equal(#events, 1)
    assert.truthy(events[1].key.tab)
    assert.equal(events[1].key.shift, nil, "plain Tab must not carry shift")
  end)

  it("parses a bracketed paste as one PasteEvent, not as individual key events", function()
    local p = keys.newParser()
    local events = p:feed("\27[200~hello\nworld\27[201~")
    assert.equal(#events, 1)
    assert.equal(events[1].type, "paste")
    assert.equal(events[1].text, "hello\nworld")
  end)

  it("handles pasted text containing escape-looking bytes without misparsing them as keys", function()
    local p = keys.newParser()
    -- The pasted text itself contains a real CSI arrow-key byte sequence
    -- -- it must come through as literal paste text, not an upArrow event.
    local events = p:feed("\27[200~a\27[Ab\27[201~")
    assert.equal(#events, 1)
    assert.equal(events[1].type, "paste")
    assert.equal(events[1].text, "a\27[Ab")
  end)

  it("handles a bracketed paste whose start marker and body arrive split across separate feed() calls", function()
    local p = keys.newParser()
    local events1 = p:feed("\27[20")
    assert.equal(#events1, 0)
    local events2 = p:feed("0~pasted")
    assert.equal(#events2, 0, "must not surface partial paste content before the terminator arrives")
    local events3 = p:feed(" text\27[201~")
    assert.equal(#events3, 1)
    assert.equal(events3[1].type, "paste")
    assert.equal(events3[1].text, "pasted text")
  end)

  it("resumes ordinary key parsing immediately after a paste ends", function()
    local p = keys.newParser()
    local events = p:feed("\27[200~x~\27[201~q")
    assert.equal(#events, 2)
    assert.equal(events[1].type, "paste")
    assert.equal(events[1].text, "x~")
    assert.equal(events[2].input, "q")
  end)

  it("parses a real sequence of mixed plain text and special keys from one feed() call", function()
    local p = keys.newParser()
    local events = p:feed("hi\27[A\r")
    assert.equal(#events, 4)
    assert.equal(events[1].input, "h")
    assert.equal(events[2].input, "i")
    assert.truthy(events[3].key.upArrow)
    assert.truthy(events[4].key["return"])
  end)
end)

-- Modifier-carrying sequences. Before this, the only modifier this parser
-- could see was Shift+Tab (ESC [ Z), because plain xterm sequences carry no
-- modifier parameter and the digits branch only ever accepted `ESC [ n ~`.
-- render.lua now pushes the Kitty keyboard protocol (ESC[>1u) so ambiguous
-- keys arrive as CSI-u with real modifier bits.
describe("hydronium_ink.keys -- modifiers via parameterised CSI and Kitty CSI-u", function()
  local function one(bytes)
    local p = keys.newParser()
    local events = p:feed(bytes)
    assert.equal(#events, 1, "expected exactly one event from " .. string.format("%q", bytes))
    return events[1]
  end

  it("reads modifiers off xterm's modified arrow form (ESC [ 1 ; mod letter)", function()
    -- Modifier wire value is 1 + bitmask: 1 shift, 2 alt, 4 ctrl, 8 super.
    local shiftRight = one("\27[1;2C")
    assert.truthy(shiftRight.key.rightArrow)
    assert.truthy(shiftRight.key.shift)

    local ctrlLeft = one("\27[1;5D")
    assert.truthy(ctrlLeft.key.leftArrow)
    assert.truthy(ctrlLeft.key.ctrl)

    local altLeft = one("\27[1;3D")
    assert.truthy(altLeft.key.leftArrow)
    assert.truthy(altLeft.key.alt)

    -- Super is Command on macOS -- the modifier that cannot reach a terminal
    -- app at all without this protocol.
    local superRight = one("\27[1;9C")
    assert.truthy(superRight.key.rightArrow)
    assert.truthy(superRight.key.super)
  end)

  it("combines multiple modifier bits", function()
    -- 1 + (1 shift | 4 ctrl) = 6
    local event = one("\27[1;6C")
    assert.truthy(event.key.rightArrow)
    assert.truthy(event.key.shift)
    assert.truthy(event.key.ctrl)
    assert.equal(event.key.alt, nil, "an unheld modifier must be ABSENT, never false")
  end)

  it("reads modifiers off the tilde form too", function()
    local event = one("\27[3;5~")
    assert.truthy(event.key.delete)
    assert.truthy(event.key.ctrl)
  end)

  it("parses Kitty CSI-u for a character key", function()
    -- ESC [ 97 ; 5 u -- codepoint 97 ('a') with ctrl.
    local event = one("\27[97;5u")
    assert.equal(event.input, "a")
    assert.truthy(event.key.ctrl)
  end)

  it("parses Kitty CSI-u for named keys", function()
    assert.truthy(one("\27[13;2u").key["return"])
    assert.truthy(one("\27[13;2u").key.shift)
    assert.truthy(one("\27[9u").key.tab)
    assert.truthy(one("\27[27u").key.escape)
    assert.truthy(one("\27[127u").key.backspace)
  end)

  it("ignores Kitty ':'-separated sub-parameters rather than mis-parsing them", function()
    -- Kitty may report an event type on the modifier (`5:1` = ctrl, press)
    -- and a shifted codepoint on the key. Only the primary values are used;
    -- a naive tonumber("5:1") would be nil and lose the modifier entirely.
    local event = one("\27[97;5:1u")
    assert.equal(event.input, "a")
    assert.truthy(event.key.ctrl)
  end)

  it("decodes a non-ASCII codepoint back to real UTF-8", function()
    -- U+00E9 'é' = codepoint 233, which must come back as 2 UTF-8 bytes.
    local event = one("\27[233u")
    assert.equal(event.input, "\195\169")
  end)

  it("still parses the unmodified forms exactly as before", function()
    assert.truthy(one("\27[C").key.rightArrow)
    assert.equal(one("\27[C").key.shift, nil)
    assert.truthy(one("\27[3~").key.delete)
    assert.truthy(one("\27[Z").key.tab)
    assert.truthy(one("\27[Z").key.shift)
  end)

  it("treats a modifier parameter of 1 as no modifiers at all", function()
    -- xterm sends `1` for "no modifiers"; decoding it as a bitmask of 0
    -- must not set every flag to false, which would claim knowledge the
    -- parser does not have elsewhere.
    local event = one("\27[1;1C")
    assert.truthy(event.key.rightArrow)
    assert.equal(event.key.shift, nil)
    assert.equal(event.key.ctrl, nil)
  end)
end)
