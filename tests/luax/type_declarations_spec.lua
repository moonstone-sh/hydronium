local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

describe("Hydronium LUAX LuaCATS Types & ElementType", function()
  local function read_file(path)
    local f, err = io.open(path, "r")
    assert.truthy(f, "Failed to open file: " .. tostring(path) .. ": " .. tostring(err))
    local content = f:read("*a")
    f:close()
    return content
  end

  describe("Core LUAX types (luax/types/luax.d.lua)", function()
    local luax_d = read_file("luax/types/luax.d.lua")

    it("declares hydronium.Intrinsic<P, H>", function()
      assert.truthy(luax_d:find("---@class hydronium%.Intrinsic<P,%s*H>"), "Expected hydronium.Intrinsic<P, H>")
      assert.truthy(luax_d:find("---@field %[%\"%$$typeof\"%] any"), "Expected [\"$$typeof\"] field")
      assert.truthy(luax_d:find("---@field tag string"), "Expected tag field")
      assert.truthy(luax_d:find("---@field host string"), "Expected host field")
      assert.truthy(luax_d:find("---@overload fun%(props%?: P,"), "Expected callable overload")
    end)

    it("declares hydronium.ElementType<P, H>", function()
      assert.truthy(luax_d:find("---@alias hydronium%.ElementType<P,%s*H>"), "Expected hydronium.ElementType<P, H>")
      assert.truthy(luax_d:find("hydronium%.Intrinsic<P,%s*H>"), "Expected reference to hydronium.Intrinsic")
    end)

    it("declares __luax_element helper", function()
      assert.truthy(luax_d:find("function __luax_element%(tag, props, %.%.%.%)"), "Expected __luax_element function declaration")
      assert.truthy(luax_d:find("---@generic P,%s*H"), "Expected generic parameters on __luax_element")
    end)
  end)

  describe("DOM Descriptors (dom/types/dom/init.d.lua)", function()
    local dom_init_d = read_file("dom/types/dom/init.d.lua")

    it("types d with hydronium.Intrinsic descriptors for HTML and SVG elements", function()
      assert.truthy(dom_init_d:find("---@class HydroniumDOMDescriptors"), "Expected HydroniumDOMDescriptors class")
      assert.truthy(dom_init_d:find("button hydronium%.Intrinsic<HTMLButtonProps,%s*HTMLButtonElement>"), "Expected d.button typing")
      assert.truthy(dom_init_d:find("input hydronium%.Intrinsic<HTMLInputProps,%s*HTMLInputElement>"), "Expected d.input typing")
      assert.truthy(dom_init_d:find("h1 hydronium%.Intrinsic<HTMLHeadingProps,%s*HTMLHeadingElement>"), "Expected d.h1 typing")
      assert.truthy(dom_init_d:find("h6 hydronium%.Intrinsic<HTMLHeadingProps,%s*HTMLHeadingElement>"), "Expected d.h6 typing")
      assert.truthy(dom_init_d:find("div hydronium%.Intrinsic<HTMLDivProps,%s*HTMLDivElement>"), "Expected d.div typing")
      assert.truthy(dom_init_d:find("span hydronium%.Intrinsic<HTMLSpanProps,%s*HTMLSpanElement>"), "Expected d.span typing")
      assert.truthy(dom_init_d:find("main hydronium%.Intrinsic<HTMLMainProps,%s*HTMLElement>"), "Expected d.main typing")
      assert.truthy(dom_init_d:find("section hydronium%.Intrinsic<HTMLSectionProps,%s*HTMLElement>"), "Expected d.section typing")
      assert.truthy(dom_init_d:find("a hydronium%.Intrinsic<HTMLAnchorProps,%s*HTMLAnchorElement>"), "Expected d.a typing")
      assert.truthy(dom_init_d:find("p hydronium%.Intrinsic<HTMLParagraphProps,%s*HTMLParagraphElement>"), "Expected d.p typing")
      assert.truthy(dom_init_d:find("form hydronium%.Intrinsic<HTMLFormProps,%s*HTMLFormElement>"), "Expected d.form typing")
      assert.truthy(dom_init_d:find("svg hydronium%.Intrinsic<SVGSVGProps,%s*SVGElement>"), "Expected d.svg typing")
      assert.truthy(dom_init_d:find("path hydronium%.Intrinsic<SVGPathProps,%s*SVGElement>"), "Expected d.path typing")
    end)
  end)

  describe("Mixed Table Support (dom/types/dom/html.d.lua)", function()
    local html_d = read_file("dom/types/dom/html.d.lua")

    it("defines mixed table indexing on HTMLButtonProps and HTMLAttributes", function()
      assert.truthy(html_d:find("---@class HTMLAttributes : LuaxProps, { %[integer%]: any }"), "Expected HTMLAttributes mixed table")
      assert.truthy(html_d:find("---@class HTMLButtonProps : HTMLAttributes, { %[integer%]: any }"), "Expected HTMLButtonProps mixed table")
      assert.truthy(html_d:find("---@field %[integer%] any"), "Expected [integer] field on HTMLButtonProps")
    end)
  end)

  describe("Global Namespace Cleanliness (dom/types/dom/intrinsics.d.lua)", function()
    local intrinsics_d = read_file("dom/types/dom/intrinsics.d.lua")

    it("removes global __luax_intrinsic table pollution", function()
      assert.falsy(intrinsics_d:find("__luax_intrinsic%s*=%s*{}"), "Global __luax_intrinsic = {} must NOT exist in intrinsics.d.lua")
    end)
  end)
end)
