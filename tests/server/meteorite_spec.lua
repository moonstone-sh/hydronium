local describe = _G.describe
local it = _G.it
local assert = _G.assert

local hydronium = require("hydronium")
local h = hydronium.createElement
local useContext = hydronium.useContext
local meteorite = require("hydronium_dom.server.meteorite")

describe("Meteorite Integration Adapter", function()
  it("renders a simple vnode to standard response table", function()
    local c = {
      params = { id = "42" },
      query = { tab = "info" },
      request_id = "req-12345",
    }

    local vnode = h("div", { class = "page" }, "Hello Meteorite")
    local res = meteorite.render(c, vnode)

    assert.truthy(type(res) == "table")
    assert.equal(res.status, 200)
    assert.equal(res.content_type, "text/html; charset=utf-8")
    assert.truthy(res.body:find("<div class=\"page\">Hello Meteorite</div>"))
  end)

  it("delegates to c:html when context provides html helper", function()
    local called_status, called_body, called_opts
    local c = {
      html = function(self, status, body, opts)
        called_status = status
        called_body = body
        called_opts = opts
        return {
          status = status,
          content_type = "text/html; charset=utf-8",
          body = body,
          headers = opts and opts.headers,
        }
      end,
      params = { slug = "hydronium-ssr" },
      query = {},
      request_id = function(self) return "req-mock-id" end,
    }

    local vnode = h("h1", nil, "Title")
    local res = meteorite.render(c, vnode, {
      status = 201,
      headers = { ["X-Custom-Header"] = "Meteorite" }
    })

    assert.equal(called_status, 201)
    assert.truthy(called_body:find("<h1>Title</h1>"))
    assert.truthy(called_opts)
    assert.equal(called_opts.headers["X-Custom-Header"], "Meteorite")
    assert.equal(res.status, 201)
    assert.equal(res.headers["X-Custom-Header"], "Meteorite")
  end)

  it("bridges request context to components via useContext(meteorite.RequestContext)", function()
    local captured_req = nil

    local function UserProfile(props)
      local req = useContext(meteorite.RequestContext)
      captured_req = req
      return h("div", { class = "user-profile" }, {
        h("span", { id = "user-id" }, req.params.user_id or ""),
        h("span", { id = "tab" }, req.query.tab or ""),
        h("span", { id = "req-id" }, req.request_id or ""),
      })
    end

    local c = {
      params = { user_id = "user-999" },
      query = { tab = "activity" },
      request_id = "req-abc-999",
      state = { user_role = "admin" },
      scope = { org = "meteorite-foundation" },
    }

    local res = meteorite.render(c, UserProfile)

    assert.truthy(captured_req ~= nil)
    assert.equal(captured_req.params.user_id, "user-999")
    assert.equal(captured_req.query.tab, "activity")
    assert.equal(captured_req.request_id, "req-abc-999")
    assert.equal(captured_req.state.user_role, "admin")
    assert.equal(captured_req.scope.org, "meteorite-foundation")

    assert.truthy(res.body:find("<span id=\"user%-id\">user%-999</span>"))
    assert.truthy(res.body:find("<span id=\"tab\">activity</span>"))
    assert.truthy(res.body:find("<span id=\"req%-id\">req%-abc%-999</span>"))
  end)

  it("creates a reusable route handler function with meteorite.handler", function()
    local function Page(props)
      return h("main", nil, "Package: " .. tostring(props.params.pkg))
    end

    local handler = meteorite.handler(Page, {
      headers = { ["X-Powered-By"] = "Hydronium+Meteorite" }
    })

    local c = {
      params = { pkg = "hydronium" },
      query = {},
    }

    local res = handler(c)
    assert.equal(res.status, 200)
    assert.truthy(res.body:find("<main>Package: hydronium</main>"))
    assert.equal(res.headers["X-Powered-By"], "Hydronium+Meteorite")
  end)

  it("handles ErrorBoundary inside SSR component tree gracefully", function()
    local function BrokenComponent()
      error("Simulated crash in subcomponent")
    end

    local function SafePage()
      return h(hydronium.ErrorBoundary, {
        fallback = function(err)
          return h("div", { class = "ssr-error-fallback" }, "Recovered: " .. tostring(err.message or err))
        end
      }, {
        h(BrokenComponent, nil)
      })
    end

    local c = { params = {}, query = {} }
    local res = meteorite.render(c, SafePage, { status = 500 })

    assert.equal(res.status, 500)
    assert.truthy(res.body:find("class=\"ssr%-error%-fallback\""))
    assert.truthy(res.body:find("Simulated crash in subcomponent"))
  end)

  it("supports streaming rendering via meteorite.render_stream", function()
    local chunks = {}
    local sink = {
      write = function(self, chunk)
        table.insert(chunks, chunk)
      end,
      flush = function(self) end,
      close = function(self) end,
    }

    local c = { params = { name = "StreamingPage" }, query = {} }
    local function StreamApp(props)
      return h("article", nil, {
        h("h1", nil, "Streamed Header"),
        h("p", nil, "Target: " .. props.params.name)
      })
    end

    meteorite.render_stream(c, StreamApp, sink)

    local full_html = table.concat(chunks, "")
    assert.truthy(full_html:find("<article><h1>Streamed Header</h1><p>Target: StreamingPage</p></article>"))
  end)
end)
