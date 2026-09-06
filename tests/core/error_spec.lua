local h = require("tests.runner")
local H = require("hydronium")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Core: Error Handling & Resilient Boundaries", function()

  describe("ErrorBoundary catching setup & render errors", function()
    it("catches setup errors in child components and renders fallback", function()
      local errorLogged = nil

      local function CrashingSetup()
        error("Setup failure in component")
      end

      local function App()
        return H.h(H.ErrorBoundary, {
          fallback = H.h("div", { id = "fallback" }, "Fallback content"),
          onError = function(err) errorLogged = err end,
        }, H.h(CrashingSetup))
      end

      local root = H.create_test_root()
      root:render(H.h(App))

      assert.is_not_nil(root:find({ id = "fallback" }))
      assert.equal(root:text(), "Fallback content")
      assert.is_not_nil(errorLogged)
      assert.truthy(string.find(tostring(errorLogged), "Setup failure in component"))
    end)

    it("catches render errors in child components and renders fallback", function()
      local shouldCrash, setShouldCrash = H.signal(false)

      local function CrashingRender()
        return function()
          if shouldCrash() then
            error("Render failure: dynamic crash")
          end
          return H.h("div", { id = "safe" }, "Safe component")
        end
      end

      local root = H.create_test_root()
      root:render(H.h(H.ErrorBoundary, {
        fallback = function(err)
          return H.h("div", { id = "err_fallback" }, "Recovered from error")
        end
      }, H.h(CrashingRender)))

      assert.is_not_nil(root:find({ id = "safe" }))
      assert.equal(root:text(), "Safe component")

      -- Trigger error
      H.act(function()
        setShouldCrash(true)
      end)

      assert.is_nil(root:find({ id = "safe" }))
      assert.is_not_nil(root:find({ id = "err_fallback" }))
      assert.equal(root:text(), "Recovered from error")
    end)
  end)

  describe("Fallback rendering and retry", function()
    it("supports dynamic fallback function receiving error and retry callback", function()
      local failCount = 0
      local attempt = 0

      local function FlakyComponent()
        attempt = attempt + 1
        if attempt <= 1 then
          failCount = failCount + 1
          error("Flaky network failure")
        end
        return H.h("div", { id = "success" }, "Success on attempt " .. tostring(attempt))
      end

      local retryFn = nil

      local root = H.create_test_root()
      root:render(H.h(H.ErrorBoundary, {
        fallback = function(err, retry)
          retryFn = retry
          return H.h("div", { id = "fallback_retry" }, "Error: " .. tostring(err))
        end
      }, H.h(FlakyComponent)))

      assert.is_not_nil(root:find({ id = "fallback_retry" }))
      assert.equal(failCount, 1)
      assert.is_function(retryFn)

      -- Call retry() to recover
      H.act(function()
        retryFn()
      end)

      assert.is_not_nil(root:find({ id = "success" }))
      assert.equal(root:text(), "Success on attempt 2")
    end)
  end)

  describe("Cascading ErrorBoundary errors", function()
    it("bubbles errors to outer boundary when inner boundary fallback fails", function()
      local outerCaught = nil

      local function CrashingChild()
        error("Initial child crash")
      end

      local function App()
        return H.h(H.ErrorBoundary, {
          onError = function(err) outerCaught = err end,
          fallback = H.h("div", { id = "outer_fallback" }, "Outer fallback rescued app")
        },
          H.h(H.ErrorBoundary, {
            fallback = function(err)
              -- Fallback itself crashes!
              error("Crash inside inner fallback: " .. tostring(err))
            end
          }, H.h(CrashingChild))
        )
      end

      local root = H.create_test_root()
      root:render(H.h(App))

      assert.is_not_nil(root:find({ id = "outer_fallback" }))
      assert.equal(root:text(), "Outer fallback rescued app")
      assert.is_not_nil(outerCaught)
      assert.truthy(string.find(tostring(outerCaught), "Crash inside inner fallback"))
    end)
  end)

  describe("Resilient cleanup execution", function()
    it("executes all deferred cleanups even if one cleanup throws an error", function()
      local cleanupsExecuted = {}

      local function ResilientComp(props, scope)
        scope:defer(function()
          table.insert(cleanupsExecuted, "cleanup_1_success")
        end)

        scope:defer(function()
          table.insert(cleanupsExecuted, "cleanup_2_before_throw")
          error("Simulated explosion in cleanup_2")
        end)

        scope:defer(function()
          table.insert(cleanupsExecuted, "cleanup_3_success")
        end)

        return H.h("div", nil, "hello")
      end

      local root = H.create_test_root()
      root:render(H.h(ResilientComp))

      assert.same(cleanupsExecuted, {})

      -- Unmount triggers cleanups in LIFO order (3 -> 2 (fails) -> 1)
      -- The error is collected and bubbled, but all cleanups must run!
      local ok, err = pcall(function()
        root:unmount()
      end)

      assert.falsy(ok)
      assert.truthy(string.find(tostring(err), "explosion in cleanup_2"))

      -- Verify that cleanup_3, cleanup_2, and cleanup_1 ALL executed despite the error
      assert.same(cleanupsExecuted, {
        "cleanup_3_success",
        "cleanup_2_before_throw",
        "cleanup_1_success"
      })
    end)
  end)

end)
