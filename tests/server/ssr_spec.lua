local runner = require("tests.runner")
local H = require("hydronium")
local server = require("hydronium_dom.server")
local dom = require("hydronium_dom")
local symbols = require("hydronium.core.symbols")

describe("Hydronium Server Renderer (SSR)", function()
  describe("render_to_string and streaming sink", function()
    it("renders a simple VNode tree synchronously to string", function()
      local vnode = H.h("div", { class = "container" },
        H.h("h1", nil, "Hello World"),
        H.h("p", nil, "Server-side rendering in pure Lua")
      )
      local html = server.render_to_string(vnode)
      assert.equal(html, '<div class="container"><h1>Hello World</h1><p>Server-side rendering in pure Lua</p></div>')
    end)

    it("streams HTML chunks to a sink object with write, flush, and close", function()
      local chunks = {}
      local flushed = false
      local closed = false

      local sink = {
        write = function(chunk)
          table.insert(chunks, chunk)
        end,
        flush = function()
          flushed = true
        end,
        close = function()
          closed = true
        end,
      }

      local vnode = H.h("main", { id = "content" }, H.h("span", nil, "Streamed chunk"))
      server.render(vnode, sink)

      assert.truthy(#chunks > 0)
      assert.truthy(flushed, "Sink flush must be invoked")
      assert.truthy(closed, "Sink close must be invoked")
      local full = table.concat(chunks)
      assert.equal(full, '<main id="content"><span>Streamed chunk</span></main>')
    end)

    it("supports optional doctype prepending in server.render", function()
      local html = server.render_to_string(H.h("html", nil, H.h("body", nil, "Hi")), { doctype = true })
      assert.truthy(html:find("^<!DOCTYPE html>\n"), "Should prepend standard DOCTYPE")
    end)
  end)

  describe("Strict HTML5 Void Elements", function()
    local void_tags = {
      "area", "base", "br", "col", "embed", "hr",
      "img", "input", "link", "meta", "param", "source", "track", "wbr"
    }

    for _, tag in ipairs(void_tags) do
      it("renders <" .. tag .. "> as void element without self-closing slash", function()
        local vnode = H.h(tag, { id = "test-" .. tag })
        local html = server.render_to_string(vnode)
        assert.equal(html, '<' .. tag .. ' id="test-' .. tag .. '">')
        assert.falsy(html:find("/>"), "Void elements must not have self-closing slash")
        assert.falsy(html:find("</" .. tag .. ">"), "Void elements must not have closing tag")
      end)

      it("throws an explicit error if children are passed to void element <" .. tag .. ">", function()
        local ok, err = pcall(function()
          server.render_to_string(H.h(tag, nil, "Illegal child"))
        end)
        assert.falsy(ok, "Void element <" .. tag .. "> with children must error")
        assert.truthy(tostring(err):find("Void element <" .. tag .. "> cannot have children"))
      end)
    end

    it("always renders non-void elements with full closing tag even when empty", function()
      local empty_div = server.render_to_string(H.h("div", nil))
      assert.equal(empty_div, "<div></div>")

      local empty_span = server.render_to_string(H.h("span", nil))
      assert.equal(empty_span, "<span></span>")

      local empty_button = server.render_to_string(H.h("button", nil))
      assert.equal(empty_button, "<button></button>")
    end)
  end)

  describe("Boolean vs ARIA and General Attributes", function()
    it("renders HTML boolean attributes as ' name' when truthy and omits when falsy", function()
      local vnode_true = H.h("input", { type = "checkbox", checked = true, disabled = true, required = true })
      local html_true = server.render_to_string(vnode_true)
      assert.truthy(html_true:find(" checked"))
      assert.truthy(html_true:find(" disabled"))
      assert.truthy(html_true:find(" required"))
      assert.falsy(html_true:find('checked="true"'))
      assert.falsy(html_true:find('disabled="true"'))

      local vnode_false = H.h("input", { type = "checkbox", checked = false, disabled = false, required = false })
      local html_false = server.render_to_string(vnode_false)
      assert.falsy(html_false:find("checked"))
      assert.falsy(html_false:find("disabled"))
      assert.falsy(html_false:find("required"))
    end)

    it("renders ARIA boolean attributes with explicit '\"false\"' when false", function()
      local vnode = H.h("button", {
        ["aria-hidden"] = false,
        ["aria-expanded"] = true,
        ["aria-disabled"] = false,
      })
      local html = server.render_to_string(vnode)
      assert.truthy(html:find('aria%-hidden="false"'), "aria-hidden='false'")
      assert.truthy(html:find('aria%-expanded="true"'), "aria-expanded='true'")
      assert.truthy(html:find('aria%-disabled="false"'), "aria-disabled='false'")
    end)

    it("renders non-boolean general attributes with explicit '\"false\"' when false", function()
      local vnode = H.h("div", {
        ["data-active"] = false,
        ["data-visible"] = true,
      })
      local html = server.render_to_string(vnode)
      assert.truthy(html:find('data%-active="false"'))
      assert.truthy(html:find('data%-visible="true"'))
    end)

    it("never serializes event handlers or other functions as HTML attributes", function()
      local vnode = H.h(dom.d.lua.island, nil, H.h("button", {
        onClick = function() end,
        onInput = function() end,
        on_change = function() end,
        id = "btn",
      }, "Click"))
      local html = server.render_to_string(vnode)
      assert.falsy(html:find("onClick"))
      assert.falsy(html:find("onInput"))
      assert.falsy(html:find("on_change"))
      assert.truthy(html:find('id="btn"'))
    end)

    it("raises a diagnostic for a Lua event callback with no enclosing Lua client boundary", function()
      local vnode = H.h("button", { onClick = function() end }, "Click")
      local ok, err = pcall(server.render_to_string, vnode)
      assert.falsy(ok)
      assert.truthy(tostring(err):find("requires a Lua client execution boundary", 1, true))
      assert.truthy(tostring(err):find("onClick", 1, true))
    end)

    it("does not raise for a non-camelCase function prop with no island (silently excluded, not a recognized event name)", function()
      local vnode = H.h("button", { on_change = function() end, id = "btn" }, "Click")
      local html = server.render_to_string(vnode)
      assert.falsy(html:find("on_change"))
      assert.truthy(html:find('id="btn"'))
    end)
  end)

  describe("CSS Style Serialization", function()
    it("converts camelCase properties to kebab-case and sorts alphabetically", function()
      local vnode = H.h("div", {
        style = {
          backgroundColor = "blue",
          marginTop = "10px",
          color = "white",
        }
      })
      local html = server.render_to_string(vnode)
      assert.equal(html, '<div style="background-color: blue; color: white; margin-top: 10px"></div>')
    end)

    it("appends 'px' to non-unitless numeric properties", function()
      local vnode = H.h("div", {
        style = {
          width = 120,
          height = 60,
          fontSize = 14,
        }
      })
      local html = server.render_to_string(vnode)
      assert.equal(html, '<div style="font-size: 14px; height: 60px; width: 120px"></div>')
    end)

    it("preserves unitless numeric properties without appending 'px'", function()
      local vnode = H.h("div", {
        style = {
          zIndex = 100,
          opacity = 0.8,
          flex = 1,
          flexGrow = 2,
          flexShrink = 0,
          order = 3,
          fontWeight = 700,
          lineHeight = 1.5,
          zoom = 1,
        }
      })
      local html = server.render_to_string(vnode)
      assert.truthy(html:find("z%-index: 100"))
      assert.truthy(html:find("opacity: 0.8"))
      assert.truthy(html:find("flex: 1"))
      assert.truthy(html:find("flex%-grow: 2"))
      assert.truthy(html:find("flex%-shrink: 0"))
      assert.truthy(html:find("order: 3"))
      assert.truthy(html:find("font%-weight: 700"))
      assert.truthy(html:find("line%-height: 1.5"))
      assert.truthy(html:find("zoom: 1"))
      assert.falsy(html:find("z%-index: 100px"))
      assert.falsy(html:find("opacity: 0.8px"))
    end)
  end)

  describe("HTML Escaping & Raw Text Handling", function()
    it("escapes '&' first, followed by '<', '>', '\"', and '\''", function()
      local vnode = H.h("p", { title = "A & B < C > D \"quotes\" 'single'" },
        "Tom & Jerry <friends> \"hello\" 'world'")
      local html = server.render_to_string(vnode)

      assert.truthy(html:find("&amp;"))
      assert.truthy(html:find("&lt;"))
      assert.truthy(html:find("&gt;"))
      assert.truthy(html:find("&quot;"))
      assert.truthy(html:find("&#39;"))
      -- Ensure no raw < or > or quotes remain in text or attrs
      assert.falsy(html:find("<friends>"))
      assert.falsy(html:find('"hello"'))
    end)

    it("handles raw text in <script> and prevents </script> breakouts", function()
      local script = H.h("script", nil, 'var s = "</script><script>malicious();";')
      local html = server.render_to_string(script)
      assert.truthy(html:find("<\\/script", 1, true))
      assert.falsy(html:find("</script><script>"))
    end)

    it("handles raw text in <style> and prevents </style> breakouts", function()
      local style = H.h("style", nil, 'body { content: "</style><script>alert(1);"; }')
      local html = server.render_to_string(style)
      assert.truthy(html:find("<\\/style", 1, true))
      assert.falsy(html:find("</style><script>"))
    end)

    it("injects raw HTML via unsafe_raw_html or dangerouslySetInnerHTML without escaping", function()
      local raw1 = H.h("div", { unsafe_raw_html = "<p>Raw Content</p>" })
      local html1 = server.render_to_string(raw1)
      assert.equal(html1, "<div><p>Raw Content</p></div>")

      local raw2 = H.h("div", { dangerouslySetInnerHTML = { __html = "<span>Dangerous</span>" } })
      local html2 = server.render_to_string(raw2)
      assert.equal(html2, "<div><span>Dangerous</span></div>")
    end)

    it("throws an error if both children and raw HTML are provided", function()
      local ok, err = pcall(function()
        server.render_to_string(H.h("div", { unsafe_raw_html = "<p>Raw</p>" }, "Child node"))
      end)
      assert.falsy(ok)
      assert.truthy(tostring(err):find("Cannot provide both children"))
    end)
  end)

  describe("Deterministic Sorting", function()
    it("sorts attributes alphabetically for identical HTML regardless of hash table order", function()
      local vnode1 = H.h("div", { z = "3", a = "1", m = "2" })
      local vnode2 = H.h("div", { a = "1", z = "3", m = "2" })

      local html1 = server.render_to_string(vnode1)
      local html2 = server.render_to_string(vnode2)

      assert.equal(html1, '<div a="1" m="2" z="3"></div>')
      assert.equal(html1, html2)
    end)
  end)

  describe("Effect Suppression & Reactivity during SSR", function()
    it("suppresses createEffect / effect execution entirely during SSR", function()
      local effect_executed = false
      local function StateComp(props)
        local count, setCount = H.createSignal(10)
        H.createEffect(function()
          effect_executed = true
        end)
        return H.h("span", nil, "Count: " .. count())
      end

      local html = server.render_to_string(H.h(StateComp))
      assert.equal(html, "<span>Count: 10</span>")
      assert.falsy(effect_executed, "Effects must be suppressed on the server")
    end)

    it("evaluates computed derivations synchronously without subscribing", function()
      local function ComputedComp()
        local base, setBase = H.createSignal(5)
        local doubled = H.createComputed(function()
          return base() * 2
        end)
        return H.h("span", nil, "Doubled: " .. doubled())
      end

      local html = server.render_to_string(H.h(ComputedComp))
      assert.equal(html, "<span>Doubled: 10</span>")
    end)
  end)

  describe("ErrorBoundary & Context Restoration during SSR", function()
    it("catches component errors in ErrorBoundary and renders fallback during SSR", function()
      local function ExplodingComp()
        error("SSR component failed!")
      end

      local function SafeApp()
        return H.h("div", { class = "app" },
          H.h(H.ErrorBoundary, {
            fallback = function(err, retry)
              return H.h("div", { class = "alert" }, "Recovered: " .. tostring(err):match("SSR component failed!"))
            end
          }, H.h(ExplodingComp))
        )
      end

      local html = server.render_to_string(H.h(SafeApp))
      assert.equal(html, '<div class="app"><div class="alert">Recovered: SSR component failed!</div></div>')
    end)

    it("propagates and restores context values across nested component trees", function()
      local ThemeContext = H.createContext("light")

      local function DisplayTheme()
        local theme = H.useContext(ThemeContext)
        return H.h("span", { class = "theme" }, theme)
      end

      local function ThemedApp()
        return H.h(ThemeContext.Provider, { value = "dark" },
          H.h("div", nil, H.h(DisplayTheme))
        )
      end

      local html = server.render_to_string(H.h(ThemedApp))
      assert.equal(html, '<div><span class="theme">dark</span></div>')

      -- Context must be restored outside the provider
      local outer_theme = H.useContext(ThemeContext)
      assert.equal(outer_theme, "light")
    end)

    it("guarantees scope and context stack restoration even if render throws uncaught error", function()
      local scopeModule = require("hydronium.core.scope")
      local contextModule = require("hydronium.core.context")
      local scheduler = require("hydronium.core.scheduler")

      local initial_scope_depth = scopeModule.getScopeStackDepth()
      local initial_ctx_depth = contextModule.getContextStackDepth()

      local function FatalComp()
        error("Uncaught server explosion")
      end

      local ok, err = pcall(function()
        server.render_to_string(H.h(FatalComp))
      end)

      assert.falsy(ok, "Uncaught render must throw")
      assert.falsy(scheduler.isSSR(), "SSR mode must be reset to false")
      assert.equal(scopeModule.getScopeStackDepth(), initial_scope_depth, "Scope stack must be restored")
      assert.equal(contextModule.getContextStackDepth(), initial_ctx_depth, "Context stack must be restored")
    end)
  end)
end)
