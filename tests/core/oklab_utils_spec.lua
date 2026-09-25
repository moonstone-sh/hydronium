local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local color = require("hydronium_oklab_utils")

describe("OKLab utilities", function()
  it("round-trips opaque sRGB through OKLab within one byte", function()
    local source = color.srgb(34, 120, 210)
    local result = color.to_srgb(color.to_oklab(source))
    assert.truthy(math.abs(result.r - source.r) <= 1)
    assert.truthy(math.abs(result.g - source.g) <= 1)
    assert.truthy(math.abs(result.b - source.b) <= 1)
  end)

  it("parses hex and maps out-of-gamut OKLCH to opaque sRGB", function()
    local hex = color.hex("#d67cff")
    assert.same(hex, { space = "srgb", r = 214, g = 124, b = 255 })
    local mapped = color.to_srgb(color.oklch(0.72, 0.8, 310))
    assert.truthy(mapped.r >= 0 and mapped.r <= 255)
    assert.truthy(mapped.g >= 0 and mapped.g <= 255)
    assert.truthy(mapped.b >= 0 and mapped.b <= 255)
  end)

  it("mixes in perceptual space and reports WCAG contrast", function()
    local mixed = color.to_srgb(color.mix(color.hex("#000000"), color.hex("#ffffff"), 0.5))
    assert.truthy(mixed.r > 80 and mixed.r < 220)
    assert.equal(color.contrast(color.hex("#000000"), color.hex("#ffffff")), 21)
  end)
end)

describe("OKLab utilities -- APCA contrast (lc)", function()
  -- Reference numbers from the published APCA-W3 (0.0.98G-4g) reference
  -- implementation, not invented: #888-on-#fff = Lc ~63.1, #fff-on-#888 =
  -- Lc ~-68.5 (light text on a dark background is negative), #000-on-#aaa
  -- = Lc ~58.1.
  it("matches the published APCA reference values within 0.1 Lc", function()
    local function near(actual, expected)
      assert.truthy(math.abs(actual - expected) < 0.1,
        string.format("expected ~%.1f, got %.4f", expected, actual))
    end
    near(color.lc(color.hex("#888888"), color.hex("#ffffff")), 63.1)
    near(color.lc(color.hex("#ffffff"), color.hex("#888888")), -68.5)
    near(color.lc(color.hex("#000000"), color.hex("#aaaaaa")), 58.1)
  end)

  it("is signed: dark-on-light is positive, light-on-dark is negative", function()
    assert.truthy(color.lc(color.hex("#000000"), color.hex("#ffffff")) > 0)
    assert.truthy(color.lc(color.hex("#ffffff"), color.hex("#000000")) < 0)
  end)

  it("reports ~0 for a color against itself", function()
    local c = color.hex("#336699")
    assert.truthy(math.abs(color.lc(c, c)) < 0.01)
  end)

  it("scores an out-of-gamut OKLCH background on the same final sRGB it paints as", function()
    -- A vivid, deliberately out-of-gamut OKLCH point: to_srgb reduces its
    -- chroma (preserving L/h) to land back in sRGB. lc() must score exactly
    -- that gamut-mapped, rounded color -- not the unreachable OKLCH point --
    -- since that gamut-mapped color is what a truecolor terminal or browser
    -- actually paints.
    for _, hue in ipairs({ 145, 265 }) do
      local vivid_bg = color.oklch(0.6, 0.5, hue)
      local mapped_bg = color.to_srgb(vivid_bg)
      local text = color.hex("#000000")
      assert.equal(color.lc(text, vivid_bg), color.lc(text, mapped_bg))
    end
  end)
end)

describe("OKLab utilities -- readable_on", function()
  it("picks near-black text on a light background and near-white on a dark one", function()
    local onLight = color.readable_on(color.hex("#f0f0f0"))
    local onDark = color.readable_on(color.hex("#101010"))
    assert.truthy(color.to_oklch(onLight).l < 0.5, "expected dark text on a light bg")
    assert.truthy(color.to_oklch(onDark).l > 0.5, "expected light text on a dark bg")
  end)

  it("honors an explicit candidate list", function()
    local red, blue = color.hex("#ff0000"), color.hex("#0000ff")
    local chosen, lc = color.readable_on(color.hex("#ffffff"), { candidates = { red, blue } })
    assert.truthy(chosen == red or chosen == blue)
    assert.equal(math.abs(lc), math.max(math.abs(color.lc(red, color.hex("#ffffff"))), math.abs(color.lc(blue, color.hex("#ffffff")))))
  end)
end)

describe("OKLab utilities -- ensure_contrast", function()
  it("leaves an already-sufficient color's OKLCH coordinates untouched", function()
    local fg, bg = color.hex("#000000"), color.hex("#ffffff")
    local result, achieved = color.ensure_contrast(fg, bg, 60)
    assert.same(color.to_oklch(result), color.to_oklch(fg))
    assert.equal(achieved, color.lc(fg, bg))
  end)

  it("preserves hue while raising lightness contrast to the target", function()
    local bg = color.oklch(0.55, 0.1, 250)
    local fg = color.oklch(0.5, 0.15, 250) -- similar lightness to bg: low contrast
    local result, achieved = color.ensure_contrast(fg, bg, 60)
    assert.truthy(achieved >= 59.9, "expected to reach the target, got " .. achieved)
    local rlch = color.to_oklch(result)
    assert.truthy(math.abs(rlch.h - 250) < 0.5 or rlch.c < 0.001, "hue should survive unless fully desaturated")
  end)

  it("supports the wcag metric against contrast()'s ratio", function()
    local bg = color.oklch(0.5, 0.1, 250)
    local result, achieved = color.ensure_contrast(color.oklch(0.5, 0.1, 250), bg, 4.5, { metric = "wcag" })
    assert.truthy(achieved >= 4.5)
    assert.truthy(math.abs(color.contrast(result, bg) - achieved) < 0.01)
  end)

  it("returns the best achievable color, not a failure, when the target is impossible", function()
    local bg = color.hex("#808080")
    local result, achieved = color.ensure_contrast(color.hex("#808080"), bg, 90)
    assert.truthy(achieved < 90)
    assert.truthy(achieved > 0)
    assert.equal(achieved, math.abs(color.lc(result, bg)))
  end)

  it("rejects an unknown metric", function()
    local ok = pcall(color.ensure_contrast, color.hex("#000000"), color.hex("#ffffff"), 60, { metric = "nonsense" })
    assert.falsy(ok)
  end)

  it("property: the reported achieved score always matches recomputing lc on the result", function()
    math.randomseed(12345)
    for _ = 1, 100 do
      local fg = color.oklch(math.random(), math.random() * 0.3, math.random() * 360)
      local bg = color.oklch(math.random(), math.random() * 0.3, math.random() * 360)
      local target = 30 + math.random() * 40
      local result, achieved = color.ensure_contrast(fg, bg, target)
      local recomputed = math.abs(color.lc(result, bg))
      assert.truthy(math.abs(recomputed - achieved) < 0.05,
        string.format("achieved %.4f != recomputed %.4f", achieved, recomputed))
    end
  end)

  it("property: never reports success below target unless black AND white both also fail", function()
    math.randomseed(777)
    for _ = 1, 100 do
      local fg = color.oklch(math.random(), math.random() * 0.3, math.random() * 360)
      local bg = color.oklch(math.random(), math.random() * 0.3, math.random() * 360)
      local target = 30 + math.random() * 40
      local _, achieved = color.ensure_contrast(fg, bg, target)
      if achieved < target - 0.5 then
        local blackLc = math.abs(color.lc(color.oklch(0, 0, 0), bg))
        local whiteLc = math.abs(color.lc(color.oklch(1, 0, 0), bg))
        assert.truthy(math.max(blackLc, whiteLc) < target + 0.5,
          "target was achievable via black/white but ensure_contrast fell short")
      end
    end
  end)
end)
