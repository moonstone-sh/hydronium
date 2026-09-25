--[[
  hydronium_ink.terminal_background -- OSC 11 query/parse/timeout, tested
  without a real terminal: every I/O primitive `detect()` uses is
  injectable (see that module's own doc comment), so the no-TTY and
  timeout paths run with no real sleep and no real TTY at all.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local terminal_background = require("hydronium_ink.terminal_background")

describe("hydronium_ink.terminal_background -- parse_response", function()
  it("parses a BEL-terminated reply", function()
    local color = terminal_background.parse_response("\27]11;rgb:ffff/0000/8080\7")
    assert.same(color, { space = "srgb", r = 255, g = 0, b = 128 })
  end)

  it("parses an ST-terminated reply", function()
    local color = terminal_background.parse_response("\27]11;rgb:ffff/0000/8080\27\\")
    assert.same(color, { space = "srgb", r = 255, g = 0, b = 128 })
  end)

  it("normalizes 2-hex-digit channels (not just 4)", function()
    local color = terminal_background.parse_response("\27]11;rgb:ff/00/80\7")
    assert.same(color, { space = "srgb", r = 255, g = 0, b = 128 })
  end)

  it("normalizes 1-hex-digit channels", function()
    local color = terminal_background.parse_response("\27]11;rgb:f/0/8\7")
    -- channel(hex) = round(value / (16^#hex - 1) * 255); for a single hex
    -- digit that is value/15*255.
    assert.same(color, {
      space = "srgb",
      r = math.floor(15 / 15 * 255 + 0.5),
      g = 0,
      b = math.floor(8 / 15 * 255 + 0.5),
    })
  end)

  it("returns nil for bytes with no OSC 11 reply at all", function()
    local color = terminal_background.parse_response("just some typed text\r\n")
    assert.equal(color, nil)
  end)

  it("returns nil for a differently-shaped OSC 11 body", function()
    local color = terminal_background.parse_response("\27]11;not-rgb-shaped\7")
    assert.equal(color, nil)
  end)

  it("returns nil for an unterminated (still-arriving) reply", function()
    local color = terminal_background.parse_response("\27]11;rgb:ffff/0000/8")
    assert.equal(color, nil)
  end)

  it("locates the reply inside surrounding bytes via matchStart/matchEnd", function()
    local bytes = "abc\27]11;rgb:ffff/ffff/ffff\7xyz"
    local color, s, e = terminal_background.parse_response(bytes)
    assert.truthy(color ~= nil)
    assert.equal(bytes:sub(1, s - 1) .. bytes:sub(e + 1), "abcxyz")
  end)
end)

describe("hydronium_ink.terminal_background -- detect, no TTY", function()
  it("never writes or reads when stdin/stdout are not TTYs", function()
    local wrote, polled = false, false
    local color, leftover = terminal_background.detect({
      isatty = function() return false end,
      writeFn = function() wrote = true end,
      pollReadable = function() polled = true return false end,
      readAvailable = function() return nil end,
    })
    assert.falsy(wrote, "must not write the OSC 11 query without a real TTY")
    assert.falsy(polled, "must not poll stdin without a real TTY")
    assert.equal(leftover, nil)
    -- color depends on this test process's own COLORFGBG env, which the
    -- module is entitled to fall back to even off a real TTY -- just prove
    -- it took that path rather than the query path (already shown above).
    assert.truthy(color == nil or color.space == "srgb")
  end)

  it("falls back to COLORFGBG when set and no TTY is available", function()
    local original = os.getenv
    -- selectively fake env: only COLORFGBG is inconsistent with the real
    -- environment, so this replaces os.getenv globally for the call only.
    os.getenv = function(name)
      if name == "COLORFGBG" then return "15;0" end
      return original(name)
    end
    local ok, color = pcall(terminal_background.detect, {
      isatty = function() return false end,
    })
    os.getenv = original
    assert.truthy(ok)
    -- index 0 is ANSI16 black -> (0, 0, 0).
    assert.same(color, { space = "srgb", r = 0, g = 0, b = 0 })
  end)

  it("returns nil when COLORFGBG is absent and no TTY is available", function()
    local original = os.getenv
    os.getenv = function(name)
      if name == "COLORFGBG" then return nil end
      return original(name)
    end
    local color = terminal_background.detect({ isatty = function() return false end })
    os.getenv = original
    assert.equal(color, nil)
  end)
end)

describe("hydronium_ink.terminal_background -- detect, TTY present", function()
  it("times out gracefully when the terminal never replies, with no real sleep", function()
    local pollCalls, readCalls = 0, 0
    local queryWritten = nil
    local color, leftover = terminal_background.detect({
      isatty = function() return true end,
      writeFn = function(bytes) queryWritten = bytes end,
      pollReadable = function() pollCalls = pollCalls + 1 return false end,
      readAvailable = function() readCalls = readCalls + 1 return nil end,
      timeoutMs = 100,
    })
    assert.equal(queryWritten, "\27]11;?\27\\")
    assert.truthy(pollCalls >= 4, "expected several poll attempts within the timeout budget, got " .. pollCalls)
    assert.equal(readCalls, 0, "must not read when poll never reports readable")
    assert.equal(leftover, nil)
    assert.truthy(color == nil or color.space == "srgb")
  end)

  it("returns the parsed color and no leftover for a clean single-chunk reply", function()
    local reply = "\27]11;rgb:1e1e/1e1e/1e1e\7"
    local color, leftover = terminal_background.detect({
      isatty = function() return true end,
      writeFn = function() end,
      pollReadable = function() return true end,
      readAvailable = function() return reply end,
      timeoutMs = 100,
    })
    assert.same(color, { space = "srgb", r = 30, g = 30, b = 30 })
    assert.equal(leftover, nil)
  end)

  it("assembles a reply that arrives split across multiple reads", function()
    local chunks = { "\27]11;rgb:ffff/", "ffff/ffff\7" }
    local i = 0
    local color = terminal_background.detect({
      isatty = function() return true end,
      writeFn = function() end,
      pollReadable = function() return true end,
      readAvailable = function()
        i = i + 1
        return chunks[i]
      end,
      timeoutMs = 100,
    })
    assert.same(color, { space = "srgb", r = 255, g = 255, b = 255 })
  end)

  it("hands back genuine keystroke bytes surrounding the reply as leftover", function()
    local reply = "X\27]11;rgb:0000/0000/0000\7Y"
    local color, leftover = terminal_background.detect({
      isatty = function() return true end,
      writeFn = function() end,
      pollReadable = function() return true end,
      readAvailable = function() return reply end,
      timeoutMs = 100,
    })
    assert.same(color, { space = "srgb", r = 0, g = 0, b = 0 })
    assert.equal(leftover, "XY")
  end)
end)
