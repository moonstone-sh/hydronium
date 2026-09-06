--[[
  Meteorite + Hydronium SSR Model A Integration Test Suite
  Validates in-process hybrid integration between Meteorite HTTP runtime
  and Hydronium Server-Side Rendering engine.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local meteorite = require("hydronium.server.meteorite")
local RequestContext = meteorite.RequestContext

describe("Meteorite + Hydronium Model A SSR Integration", function()

  -- Helper to construct mock Meteorite HTTP Context (Context `c`)
  local function create_mock_context(overrides)
    overrides = overrides or {}
    local c = {
      params = overrides.params or {},
      query = overrides.query or {},
      state = overrides.state or {},
      scope = overrides.scope or {},
      headers = overrides.headers or {},
      _request_id = overrides.request_id or "req-mock-12345",
      _html_calls = {},
    }

    function c:request_id()
      return self._request_id
    end

    function c:html(status_or_body, body_or_opts, maybe_opts)
      local status, body, opts
      if type(status_or_body) == "number" then
        status = status_or_body
        body = body_or_opts
        opts = maybe_opts or {}
      else
        status = 200
        body = status_or_body
        opts = body_or_opts or {}
      end

      local resp = {
        status = status,
        content_type = "text/html; charset=utf-8",
        headers = opts.headers or {},
        body = body,
      }
      table.insert(self._html_calls, resp)
      return resp
    end

    return c
  end

  -- =========================================================================
  -- 1. Synchronous Route Rendering
  -- =========================================================================
  describe("Synchronous Route Handler Rendering", function()
    it("renders component tree directly through c:html", function()
      local function HomePage()
        return H.h("main", { class = "home" },
          H.h("h1", nil, "Welcome to Meteorite"),
          H.h("p", nil, "In-Process Hydronium SSR")
        )
      end

      local c = create_mock_context()
      local res = meteorite.render(c, HomePage, {
        status = 200,
        headers = { ["Cache-Control"] = "public, max-age=3600" }
      })

      assert.equal(res.status, 200)
      assert.equal(res.content_type, "text/html; charset=utf-8")
      assert.equal(res.headers["Cache-Control"], "public, max-age=3600")
      assert.truthy(res.body:find('<main class="home"><h1>Welcome to Meteorite</h1><p>In-Process Hydronium SSR</p></main>', 1, true))
      assert.equal(#c._html_calls, 1)
    end)

    it("supports declarative route handler creation via meteorite.handler", function()
      local function AboutView(props)
        return H.h("section", { id = "about" },
          H.h("h2", nil, "About Us"),
          H.h("span", nil, props.c and "Context Available" or "No Context")
        )
      end

      local handler = meteorite.handler(AboutView, {
        status = 200,
        headers = { ["X-Powered-By"] = "Hydronium-SSR" }
      })

      local c = create_mock_context()
      local res = handler(c)

      assert.equal(res.status, 200)
      assert.equal(res.headers["X-Powered-By"], "Hydronium-SSR")
      assert.truthy(res.body:find('<section id="about"><h2>About Us</h2><span>Context Available</span></section>', 1, true))
    end)

    it("includes DOCTYPE when doctype option is enabled", function()
      local function App()
        return H.h("html", nil, H.h("body", nil, H.h("p", nil, "Document")))
      end

      local c = create_mock_context()
      local res = meteorite.render(c, App, { doctype = true })

      assert.truthy(res.body:find("^<!DOCTYPE html>\n<html><body><p>Document</p></body></html>"))
    end)
  end)

  -- =========================================================================
  -- 2. Dynamic Route Parameters & Query Strings
  -- =========================================================================
  describe("Dynamic Parameters and Query String Propagation", function()
    it("passes params and query directly into component props", function()
      local function UserDetail(props)
        return H.h("div", { class = "user-detail" },
          H.h("h1", nil, "User ID: " .. tostring(props.params.userId)),
          H.h("span", { class = "tab" }, "Active Tab: " .. tostring(props.query.tab))
        )
      end

      local c = create_mock_context({
        params = { userId = "42" },
        query = { tab = "activity", sort = "desc" },
      })

      local res = meteorite.render(c, UserDetail)

      assert.truthy(res.body:find("<h1>User ID: 42</h1>", 1, true))
      assert.truthy(res.body:find('<span class="tab">Active Tab: activity</span>', 1, true))
    end)

    it("exposes full request metadata via useContext(RequestContext)", function()
      local captured_ctx = nil

      local function DeepNestedComponent()
        local req = H.useContext(RequestContext)
        captured_ctx = req
        return H.h("div", { id = "deep" },
          H.h("span", { id = "req-id" }, req.request_id),
          H.h("span", { id = "org" }, req.scope.org),
          H.h("span", { id = "role" }, req.state.role)
        )
      end

      local function Page()
        return H.h("div", { class = "page" }, H.h(DeepNestedComponent))
      end

      local c = create_mock_context({
        request_id = "req-uuid-9999",
        state = { role = "administrator" },
        scope = { org = "meteorite-core" },
        params = { version = "v2" },
      })

      local res = meteorite.render(c, Page)

      assert.truthy(captured_ctx ~= nil)
      assert.equal(captured_ctx.request_id, "req-uuid-9999")
      assert.equal(captured_ctx.state.role, "administrator")
      assert.equal(captured_ctx.scope.org, "meteorite-core")
      assert.equal(captured_ctx.params.version, "v2")

      assert.truthy(res.body:find('<span id="req-id">req-uuid-9999</span>', 1, true))
      assert.truthy(res.body:find('<span id="org">meteorite-core</span>', 1, true))
      assert.truthy(res.body:find('<span id="role">administrator</span>', 1, true))
    end)
  end)

  -- =========================================================================
  -- 3. Streaming Route Rendering
  -- =========================================================================
  describe("Streaming Route Rendering into Sinks", function()
    it("streams HTML chunks in progressive order through meteorite.render_stream", function()
      local function StreamedLayout(props)
        return H.h("div", { class = "stream-layout" },
          H.h("header", nil, H.h("h1", nil, "Streaming Dashboard")),
          H.h("main", nil,
            H.h("section", { id = "section-1" }, "First Section"),
            H.h("section", { id = "section-2" }, "Second Section")
          ),
          H.h("footer", nil, "Footer Chunk")
        )
      end

      local c = create_mock_context()
      local chunks = {}
      local closed = false
      local flushed = false

      local sink = {
        write = function(self, chunk)
          table.insert(chunks, chunk)
        end,
        flush = function(self)
          flushed = true
        end,
        close = function(self)
          closed = true
        end,
      }

      local ok, err = meteorite.render_stream(c, StreamedLayout, sink)
      assert.truthy(ok, "render_stream failed: " .. tostring(err))
      assert.truthy(flushed, "Sink flush must be invoked")
      assert.truthy(closed, "Sink close must be invoked")

      local full_html = table.concat(chunks, "")
      assert.truthy(#chunks >= 3, "Expected multiple chunks streamed progressively")
      assert.truthy(full_html:find('<div class="stream-layout">', 1, true))
      assert.truthy(full_html:find("<h1>Streaming Dashboard</h1>", 1, true))
      assert.truthy(full_html:find('<section id="section-1">First Section</section>', 1, true))
      assert.truthy(full_html:find('<section id="section-2">Second Section</section>', 1, true))
      assert.truthy(full_html:find("<footer>Footer Chunk</footer>", 1, true))
    end)
  end)

  -- =========================================================================
  -- 4. ErrorBoundary Handling in Route Handlers
  -- =========================================================================
  describe("ErrorBoundary Recovery and Error Page Generation", function()
    it("renders fallback UI when component tree errors without crashing server", function()
      local function BuggyWidget()
        error("Database connection lost in SSR", 0)
      end

      local function SafePage()
        return H.h("div", { class = "safe-page" },
          H.h("h1", nil, "Dashboard"),
          H.h(H.ErrorBoundary, {
            fallback = function(err)
              return H.h("div", { class = "error-banner" }, "Recovered: " .. tostring(err))
            end
          },
            H.h(BuggyWidget)
          ),
          H.h("footer", nil, "System Operational")
        )
      end

      local c = create_mock_context()
      local res = meteorite.render(c, SafePage)

      assert.equal(res.status, 200)
      assert.truthy(res.body:find("<h1>Dashboard</h1>", 1, true))
      assert.truthy(res.body:find("Database connection lost in SSR", 1, true))
      assert.truthy(res.body:find("<footer>System Operational</footer>", 1, true))
    end)

    it("allows top-level route handler to catch unhandled errors and return 500 status", function()
      local function FatalComponent()
        error("Fatal initialization crash", 0)
      end

      local c = create_mock_context()

      -- Protected call simulating Meteorite route wrapper
      local ok, res = pcall(meteorite.render, c, FatalComponent)
      if not ok then
        res = c:html(500, '<div class="server-error">500 Internal Server Error</div>', {
          headers = { ["X-Error"] = "Crash" }
        })
      end

      assert.equal(res.status, 500)
      assert.truthy(res.body:find("500 Internal Server Error", 1, true))
      assert.equal(res.headers["X-Error"], "Crash")
    end)
  end)

  -- =========================================================================
  -- 5. Client Hydration State Injection
  -- =========================================================================
  describe("Client Hydration State Injection", function()
    it("embeds serialized JSON state script tag for client-side hydration", function()
      local function App()
        return H.h("div", { id = "app" }, "App Content")
      end

      local c = create_mock_context()
      local res = meteorite.render(c, App, {
        state = {
          user = "Ada Lovelace",
          authenticated = true,
          unread_count = 5,
        }
      })

      assert.truthy(res.body:find('<script id="__HYDRONIUM_STATE__" type="application/json">', 1, true))
      assert.truthy(res.body:find('"user":"Ada Lovelace"', 1, true))
      assert.truthy(res.body:find('"authenticated":true', 1, true))
      assert.truthy(res.body:find('"unread_count":5', 1, true))
    end)

    it("suppresses state script when suppress_state_script option is true", function()
      local function App()
        return H.h("div", nil, "No State App")
      end

      local c = create_mock_context()
      local res = meteorite.render(c, App, {
        state = { secret = "hidden" },
        suppress_state_script = true,
      })

      assert.falsy(res.body:find("__HYDRONIUM_STATE__", 1, true))
    end)
  end)
end)
