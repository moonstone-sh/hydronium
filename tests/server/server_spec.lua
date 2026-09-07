local runner = require("tests.runner")
local H = require("hydronium")

describe("Hydronium Server-Side Rendering (SSR)", function()
  describe("render_to_string / renderToString basic output", function()
    it("renders basic HTML elements and nested tags", function()
      local vnode = H.h("div", { class = "container" },
        H.h("h1", nil, "Hello World"),
        H.h("p", nil, "This is SSR")
      )
      local html = H.server.render_to_string(vnode)
      assert.equal(html, '<div class="container"><h1>Hello World</h1><p>This is SSR</p></div>')
    end)

    it("supports renderToString alias", function()
      local vnode = H.h("span", { id = "test" }, "Alias Test")
      local html = H.server.renderToString(vnode)
      assert.equal(html, '<span id="test">Alias Test</span>')
    end)
  end)

  describe("Void elements vs Non-void elements", function()
    it("renders void elements as self-closing without closing tag", function()
      local vnode = H.h("div", nil,
        H.h("img", { src = "image.png", alt = "Test Image" }),
        H.h("input", { type = "text", name = "username", value = "ada" }),
        H.h("br"),
        H.h("hr"),
        H.h("meta", { charset = "utf-8" }),
        H.h("link", { rel = "stylesheet", href = "style.css" })
      )
      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find('<img alt="Test Image" src="image.png">', 1, true))
      assert.truthy(html:find('<input name="username" type="text" value="ada">', 1, true))
      assert.truthy(html:find("<br>", 1, true))
      assert.truthy(html:find("<hr>", 1, true))
      assert.truthy(html:find('<meta charset="utf-8">', 1, true))
      assert.truthy(html:find('<link href="style.css" rel="stylesheet">', 1, true))

      -- Ensure no closing tags for void elements
      assert.falsy(html:find("</img>", 1, true))
      assert.falsy(html:find("</input>", 1, true))
      assert.falsy(html:find("</br>", 1, true))
      assert.falsy(html:find("</hr>", 1, true))
      assert.falsy(html:find("</meta>", 1, true))
      assert.falsy(html:find("</link>", 1, true))
    end)

    it("renders non-void elements with full closing tags even when empty", function()
      local vnode = H.h("div", nil,
        H.h("div", { class = "empty-div" }),
        H.h("span", nil),
        H.h("button", { type = "button" }),
        H.h("p", nil)
      )
      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find('<div class="empty-div"></div>', 1, true))
      assert.truthy(html:find("<span></span>", 1, true))
      assert.truthy(html:find('<button type="button"></button>', 1, true))
      assert.truthy(html:find("<p></p>", 1, true))
    end)
  end)

  describe("Boolean attributes vs ARIA false attributes", function()
    it("renders boolean attributes when true and omits when false/nil", function()
      local vnode = H.h("form", nil,
        H.h("button", { disabled = true, autofocus = true }, "Submit"),
        H.h("button", { disabled = false }, "Cancel"),
        H.h("input", { type = "checkbox", checked = true, readonly = true, required = true }),
        H.h("input", { type = "checkbox", checked = false })
      )
      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find("<button autofocus disabled>Submit</button>", 1, true))
      assert.truthy(html:find("<button>Cancel</button>", 1, true))
      assert.truthy(html:find('<input checked readonly required type="checkbox">', 1, true))
      assert.truthy(html:find('<input type="checkbox">', 1, true))
    end)

    it("preserves ARIA false attributes as explicit 'false' strings", function()
      local vnode = H.h("div", {
        role = "button",
        ["aria-hidden"] = false,
        ["aria-expanded"] = false,
        ["aria-checked"] = false,
        ["aria-disabled"] = true,
      }, "ARIA Test")

      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find('aria-checked="false"', 1, true))
      assert.truthy(html:find('aria-disabled="true"', 1, true))
      assert.truthy(html:find('aria-expanded="false"', 1, true))
      assert.truthy(html:find('aria-hidden="false"', 1, true))
      assert.truthy(html:find('role="button"', 1, true))
    end)
  end)

  describe("Deterministic attribute ordering", function()
    it("sorts attributes alphabetically regardless of Lua table insertion order", function()
      local vnode1 = H.h("div", { z = "3", a = "1", m = "2", id = "box", class = "container" })
      local vnode2 = H.h("div", { class = "container", m = "2", z = "3", id = "box", a = "1" })

      local html1 = H.server.render_to_string(vnode1)
      local html2 = H.server.render_to_string(vnode2)

      assert.equal(html1, '<div a="1" class="container" id="box" m="2" z="3"></div>')
      assert.equal(html2, '<div a="1" class="container" id="box" m="2" z="3"></div>')
      assert.equal(html1, html2)
    end)

    it("serializes className prop as standard HTML class attribute", function()
      local vnode = H.h("p", { className = "lead text-muted" }, "Paragraph")
      local html = H.server.render_to_string(vnode)
      assert.equal(html, '<p class="lead text-muted">Paragraph</p>')
    end)
  end)

  describe("Style serialization and unitless CSS properties", function()
    it("serializes style table converting camelCase to kebab-case and sorting keys", function()
      local vnode = H.h("div", {
        style = {
          color = "red",
          backgroundColor = "blue",
          fontSize = 16,
          zIndex = 10,
          opacity = 0.8,
          lineHeight = 1.5,
          width = 200,
          marginTop = 8,
        }
      }, "Styled")

      local html = H.server.render_to_string(vnode)

      -- Unitless properties stay numbers: z-index: 10, opacity: 0.8, line-height: 1.5
      -- Dimension numbers get px: font-size: 16px, width: 200px, margin-top: 8px
      local expected_style = 'style="background-color: blue; color: red; font-size: 16px; line-height: 1.5; margin-top: 8px; opacity: 0.8; width: 200px; z-index: 10"'
      assert.truthy(html:find(expected_style, 1, true))
    end)

    it("supports string style attribute directly", function()
      local vnode = H.h("span", { style = "display: flex; align-items: center;" }, "Direct")
      local html = H.server.render_to_string(vnode)
      assert.equal(html, '<span style="display: flex; align-items: center;">Direct</span>')
    end)
  end)

  describe("HTML escaping and unsafe raw HTML", function()
    it("escapes special HTML characters in text and attributes", function()
      local vnode = H.h("div", { title = '<script>alert("xss")</script> & "test"' },
        "Tom & Jerry <friends> '2026' \"quoted\""
      )
      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find('title="&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt; &amp; &quot;test&quot;"', 1, true))
      assert.truthy(html:find("Tom &amp; Jerry &lt;friends&gt; &#39;2026&#39; &quot;quoted&quot;", 1, true))
    end)

    it("renders raw HTML via dangerouslySetInnerHTML without escaping", function()
      local vnode = H.h("div", {
        class = "content",
        dangerouslySetInnerHTML = {
          __html = "<p><strong>Trusted Raw HTML</strong> with <a href=\"/link\">links</a></p>"
        }
      })
      local html = H.server.render_to_string(vnode)
      assert.equal(html, '<div class="content"><p><strong>Trusted Raw HTML</strong> with <a href="/link">links</a></p></div>')
    end)

    it("does not escape text children inside <script> and <style> tags", function()
      local script_content = "if (a < b && c > d) { console.log('hello \"world\"'); }"
      local style_content = "div > p.active { color: #f00 & blue; }"

      local vnode = H.h("div", nil,
        H.h("script", { type = "text/javascript" }, script_content),
        H.h("style", nil, style_content)
      )

      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find('<script type="text/javascript">' .. script_content .. "</script>", 1, true))
      assert.truthy(html:find("<style>" .. style_content .. "</style>", 1, true))
    end)
  end)

  describe("Context propagation across component trees", function()
    it("propagates context values from Provider down through nested components", function()
      local UserContext = H.createContext({ name = "Default User", role = "guest" })

      local function ProfileHeader()
        local user = H.useContext(UserContext)
        return H.h("div", { class = "profile-header" },
          H.h("span", { class = "user-name" }, user.name),
          H.h("span", { class = "user-role" }, user.role)
        )
      end

      local function App()
        return H.h("div", { class = "app" },
          H.h(UserContext.Provider, { value = { name = "Ada Lovelace", role = "admin" } },
            H.h("main", nil, H.h(ProfileHeader))
          )
        )
      end

      local html = H.server.render_to_string(H.h(App))
      assert.truthy(html:find('<span class="user-name">Ada Lovelace</span>', 1, true))
      assert.truthy(html:find('<span class="user-role">admin</span>', 1, true))
    end)

    it("allows nested Providers to override ancestor context for subtrees", function()
      local ThemeContext = H.createContext("light")

      local function ThemedBox(props)
        local theme = H.useContext(ThemeContext)
        return H.h("div", { class = "box " .. theme }, props.title)
      end

      local vnode = H.h(ThemeContext.Provider, { value = "dark" },
        H.h(ThemedBox, { title = "Outer Dark" }),
        H.h(ThemeContext.Provider, { value = "solarized" },
          H.h(ThemedBox, { title = "Inner Solarized" })
        ),
        H.h(ThemedBox, { title = "After Outer Dark" })
      )

      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find('<div class="box dark">Outer Dark</div>', 1, true))
      assert.truthy(html:find('<div class="box solarized">Inner Solarized</div>', 1, true))
      assert.truthy(html:find('<div class="box dark">After Outer Dark</div>', 1, true))
    end)
  end)

  describe("Signals and Computeds evaluation", function()
    it("evaluates signals and computeds synchronously during SSR", function()
      local count, setCount = H.createSignal(10)
      local double = H.createComputed(function() return count() * 2 end)

      local function CounterView()
        return H.h("div", { class = "counter" },
          H.h("span", { class = "count" }, count()),
          H.h("span", { class = "double" }, double())
        )
      end

      local html = H.server.render_to_string(H.h(CounterView))
      assert.equal(html, '<div class="counter"><span class="count">10</span><span class="double">20</span></div>')
    end)
  end)

  describe("Effect suppression during SSR", function()
    it("suppresses effects registered via createEffect so they never execute on server", function()
      local effectRan = false
      local cleanupRan = false

      local function EffectfulComponent()
        H.createEffect(function()
          effectRan = true
          return function()
            cleanupRan = true
          end
        end)
        return H.h("p", nil, "Safe Render")
      end

      local html = H.server.render_to_string(H.h(EffectfulComponent))
      assert.equal(html, "<p>Safe Render</p>")
      assert.falsy(effectRan, "Effects must NOT run during server-side rendering")
      assert.falsy(cleanupRan, "Effect cleanups must NOT run if effect never ran")
    end)
  end)

  describe("ErrorBoundary handling during SSR", function()
    it("catches component errors during SSR and renders fallback without crashing", function()
      local errorLog = {}

      local function FailingComponent()
        error("Database connection failed during SSR render")
      end

      local function SafeApp()
        return H.h("div", { class = "page" },
          H.h(H.ErrorBoundary, {
            fallback = function(err)
              return H.h("div", { class = "error-fallback" },
                H.h("h2", nil, "Something went wrong"),
                H.h("p", nil, tostring(err.message or err))
              )
            end,
            onError = function(err)
              table.insert(errorLog, tostring(err))
            end,
          }, H.h(FailingComponent))
        )
      end

      local html = H.server.render_to_string(H.h(SafeApp))
      assert.truthy(html:find('<div class="error-fallback">', 1, true))
      assert.truthy(html:find("<h2>Something went wrong</h2>", 1, true))
      assert.truthy(html:find("Database connection failed during SSR render", 1, true))
      assert.equal(#errorLog, 1)
    end)

    it("supports static VNode as fallback prop", function()
      local function Crashing()
        error("Crash!")
      end

      local vnode = H.h(H.ErrorBoundary, {
        fallback = H.h("div", { class = "static-fallback" }, "Static Offline")
      }, H.h(Crashing))

      local html = H.server.render_to_string(vnode)
      assert.equal(html, '<div class="static-fallback">Static Offline</div>')
    end)
  end)

  describe("Streaming render (render / render_to_stream)", function()
    it("streams HTML chunks progressively into a callable sink", function()
      local chunks = {}
      local sink = function(chunk)
        table.insert(chunks, chunk)
      end

      local vnode = H.h("ul", { class = "item-list" },
        H.h("li", nil, "Item 1"),
        H.h("li", nil, "Item 2"),
        H.h("li", nil, "Item 3")
      )

      local ok = H.server.render(vnode, sink)
      assert.truthy(ok)
      assert.truthy(#chunks > 1, "Expected multiple streaming chunks")

      local full_html = table.concat(chunks)
      assert.equal(full_html, '<ul class="item-list"><li>Item 1</li><li>Item 2</li><li>Item 3</li></ul>')
    end)

    it("supports object sinks with :write(chunk) method", function()
      local output = {}
      local sink = {
        write = function(self, chunk)
          table.insert(output, chunk)
        end
      }

      local vnode = H.h("main", { id = "content" }, H.h("h2", nil, "Streamed Header"))
      H.server.render(vnode, sink)

      assert.equal(table.concat(output), '<main id="content"><h2>Streamed Header</h2></main>')
    end)

    it("supports options table with onChunk and onComplete callbacks", function()
      local chunks = {}
      local completed = false

      local vnode = H.h("section", nil, H.h("p", nil, "Chunked Section"))
      H.server.render_to_stream(vnode, {
        onChunk = function(c) table.insert(chunks, c) end,
        onComplete = function() completed = true end,
      })

      assert.truthy(completed)
      assert.equal(table.concat(chunks), "<section><p>Chunked Section</p></section>")
    end)
  end)

  describe("Component calling convention parity with the client renderer", function()
    it("passes (props, scope) to the setup function, matching ComponentInstance:render", function()
      local seen_props, seen_scope
      local function Probe(props, scope)
        seen_props, seen_scope = props, scope
        return H.h("span", nil, "ok")
      end

      H.server.render_to_string(H.h(Probe, { label = "x" }))

      assert.equal(seen_props.label, "x")
      assert.truthy(seen_scope, "Expected the setup function to receive a non-nil scope, matching the client component contract")
    end)

    it("passes (props, scope) to the render closure returned by a double-function component", function()
      -- This is the documented idiomatic pattern (h.component-style setup
      -- function returning a render function) -- previously, the render
      -- closure fell through to render_node's generic zero-argument
      -- function-child case during SSR, silently giving it nil for both
      -- arguments even though the client's ComponentInstance:render passes
      -- (self.props, self.scope) on every call.
      local seen_props, seen_scope
      local function Counter(setup_props)
        return function(render_props, render_scope)
          seen_props, seen_scope = render_props, render_scope
          return H.h("span", nil, tostring(setup_props.initial))
        end
      end

      local html = H.server.render_to_string(H.h(Counter, { initial = 5 }))

      assert.equal(html, "<span>5</span>")
      assert.equal(seen_props.initial, 5, "Expected the render closure's own props argument to be populated, not nil")
      assert.truthy(seen_scope, "Expected the render closure's own scope argument to be populated, not nil")
    end)
  end)

  describe("Refs during SSR", function()
    it("leaves refs unset -- server rendering never instantiates a host reconciler to bind them", function()
      local nodeRef = H.createRef()
      local vnode = H.h("input", { type = "text", ref = nodeRef })

      local html = H.server.render_to_string(vnode)

      assert.equal(html, '<input type="text">')
      assert.is_nil(nodeRef.current, "A ref passed to an SSR-rendered element must remain unset (no real host instance exists on the server)")
    end)
  end)

  describe("SSR ownership and hardened state serialization", function()
    it("keeps descendant scopes owned by their rendering component until descendants finish", function()
      local cleanup_order = {}
      local parent_scope, child_scope

      local function Child(_, scope)
        child_scope = scope
        H.onCleanup(function() cleanup_order[#cleanup_order + 1] = "child" end)
        return H.h("span", nil, "child")
      end
      local function Parent(_, scope)
        parent_scope = scope
        H.onCleanup(function() cleanup_order[#cleanup_order + 1] = "parent" end)
        return H.h("div", nil, H.h(Child))
      end

      assert.equal(H.server.render_to_string(H.h(Parent)), "<div><span>child</span></div>")
      assert.equal(child_scope.parent, parent_scope)
      assert.same(cleanup_order, { "child", "parent" })
    end)

    it("emits deterministic state JSON that cannot terminate its script element", function()
      local state = {
        z = "</script><script>alert(1)</script>",
        a = "\0\n\1<&>\226\128\168",
        nested = { enabled = true, items = { "one", "two" } },
      }
      local output = H.server.render_to_string(H.h("main"), { state = state })

      assert.truthy(output:find('"a":"\\u0000\\n\\u0001\\u003c\\u0026\\u003e\\u2028"', 1, true))
      assert.truthy(output:find('"z":"\\u003c/script\\u003e\\u003cscript\\u003ealert(1)\\u003c/script\\u003e"', 1, true))
      assert.falsy(output:find("</script><script>", 1, true))
      assert.truthy(output:find('"nested":{"enabled":true,"items":["one","two"]}', 1, true))
    end)

    it("rejects ambiguous or unsafe state values rather than coercing them", function()
      local cyclic = {}
      cyclic.self = cyclic
      assert.has_error(function() H.server.encode_state(cyclic) end, "cyclic table")
      assert.has_error(function() H.server.encode_state({ [1] = "mixed", kind = "object" }) end, "object keys must be strings")
      assert.has_error(function() H.server.encode_state(0 / 0) end, "non-finite number")
    end)

    it("rejects malformed tag and attribute names before emitting HTML", function()
      assert.has_error(function()
        H.server.render_to_string(H.h('div><script>alert(1)</script', nil))
      end, "Invalid SSR tag name")
      assert.has_error(function()
        H.server.render_to_string(H.h("div", { ['title" onclick="x'] = "unsafe" }))
      end, "Invalid SSR attribute name")
    end)

    it("closes a normalized sink after a write failure and restores SSR state", function()
      local scheduler = require("hydronium.core.scheduler")
      local closed = 0
      local sink = {
        write = function() error("socket write failed") end,
        close = function() closed = closed + 1 end,
      }
      local ok, err = H.server.render(H.h("div", nil, "x"), sink, {
        on_error = function() end,
      })
      assert.falsy(ok)
      assert.truthy(tostring(err):find("socket write failed", 1, true))
      assert.equal(closed, 1)
      assert.falsy(scheduler.isSSR())
    end)
  end)

  describe("SVG rendering (case-sensitive XML, unlike HTML5)", function()
    it("renders a basic SVG fixture with correct namespace-sensitive tag/attribute casing", function()
      local vnode = H.h("svg", { viewBox = "0 0 10 10" },
        H.h("path", { d = "M0 0 L10 10" })
      )
      local html = H.server.render_to_string(vnode)
      assert.equal(html, '<svg viewBox="0 0 10 10"><path d="M0 0 L10 10"></path></svg>')
    end)

    it("preserves camelCase SVG element names instead of lowercasing them like HTML tags", function()
      -- SVG is case-sensitive XML: <lineargradient>/<clippath> are not the
      -- same element as <linearGradient>/<clipPath> and browsers won't
      -- recognize the lowercased forms.
      local vnode = H.h("svg", nil,
        H.h("linearGradient", { id = "g1" },
          H.h("stop", { offset = "0%", stopColor = "red" })
        ),
        H.h("clipPath", { id = "c1" })
      )
      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find("<linearGradient id=\"g1\">", 1, true))
      assert.truthy(html:find("</linearGradient>", 1, true))
      assert.truthy(html:find("<clipPath id=\"c1\">", 1, true))
      assert.truthy(html:find("</clipPath>", 1, true))
      assert.falsy(html:find("lineargradient", 1, true), "Must not lowercase linearGradient")
      assert.falsy(html:find("clippath", 1, true), "Must not lowercase clipPath")
    end)

    it("aliases camelCase SVG presentation attributes to their real kebab-case XML names", function()
      -- strokeWidth/stopColor etc. match the JSX/DOM-property authoring
      -- convention (same as `strokeWidth` elsewhere in JSX-alikes), but
      -- real SVG/XML requires kebab-case attribute names.
      local vnode = H.h("svg", nil,
        H.h("path", { d = "M0 0", strokeWidth = 2, strokeDasharray = "4 2" }),
        H.h("stop", { stopColor = "red", stopOpacity = 0.5 })
      )
      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find('stroke-width="2"', 1, true))
      assert.truthy(html:find('stroke-dasharray="4 2"', 1, true))
      assert.truthy(html:find('stop-color="red"', 1, true))
      assert.truthy(html:find('stop-opacity="0.5"', 1, true))
      assert.falsy(html:find("strokeWidth", 1, true))
      assert.falsy(html:find("stopColor", 1, true))
    end)

    it("does not apply SVG attribute aliasing to ordinary HTML elements", function()
      -- A hypothetical HTML element with a same-named custom/data attribute
      -- must not be mistaken for an SVG presentation attribute.
      local vnode = H.h("div", { ["data-strokewidth"] = "2" }, "not svg")
      local html = H.server.render_to_string(vnode)
      assert.truthy(html:find('data-strokewidth="2"', 1, true))
    end)
  end)
end)
