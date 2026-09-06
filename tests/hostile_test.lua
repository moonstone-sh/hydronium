package.path = "src/?.lua;src/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local H = require("hydronium")
local h = H.h
local createSignal = H.signal
local createEffect = H.effect
local createComputed = H.computed
local batch = H.batch
local createRoot = H.create_test_root
local act = H.act

local passed = 0
local failed = 0

local function assert_eq(a, b, msg)
    if a ~= b then
        print("FAIL: " .. msg .. " (expected " .. tostring(b) .. ", got " .. tostring(a) .. ")")
        failed = failed + 1
    else
        passed = passed + 1
    end
end

local function run_hostile_tests()
    print("Running hostile tests...")

    -- 1. Deeply nested conditional signal dependencies and rapid switching.
    act(function()
        local s1 = createSignal(true)
        local s2 = createSignal(false)
        local c1 = createComputed(function()
            if s1() then
                return s2() and "A" or "B"
            else
                return s2() and "C" or "D"
            end
        end)
        assert_eq(c1(), "B", "c1 init")
        
        batch(function()
            s1(false)
            s2(true)
        end)
        assert_eq(c1(), "C", "c1 batch")
        
        for i=1,1000 do
            s1(i % 2 == 0)
            s2(i % 3 == 0)
        end
        assert_eq(c1(), "B", "c1 stress")
    end)
    
    -- 2. Cycle detection under adversarial self-triggering
    act(function()
        local s1 = createSignal(0)
        local ok, err = pcall(function()
            createEffect(function()
                s1(s1() + 1)
            end)
        end)
        -- Since act() flushes effects, the effect will run and trigger cycle detection
        if not ok then
            passed = passed + 1
        else
            -- It might be caught during act
            print("FAIL: Expected cycle detection error")
            failed = failed + 1
        end
    end)
    
    -- 3. Render-phase mutation error detection
    act(function()
        local s1 = createSignal(0)
        local Comp = function()
            local ok, err = pcall(function() s1(1) end)
            if not ok and string.find(err, "ERR_RENDER_MUTATION") then
                passed = passed + 1
            else
                print("FAIL: Expected ERR_RENDER_MUTATION")
                failed = failed + 1
            end
            return h("div")
        end
        local root = createRoot()
        root:render(h(Comp))
    end)

    -- 4. Keyed child reconciliation under hostile permutations, duplicates, nil holes, fragments
    act(function()
        local s_items = createSignal({1, 2, 3, 3, false, 4})
        local Comp = function()
            local items = s_items()
            local children = {}
            for i=1, #items do
                local v = items[i]
                if v then
                    table.insert(children, h("li", {key = v}, tostring(v)))
                end
            end
            return h(H.Fragment, nil, 
                h(H.Fragment, nil, unpack(children))
            )
        end
        local root = createRoot()
        root:render(h("ul", nil, h(Comp)))
        
        local text = root:text()
        assert_eq(text, "12334", "keyed initial duplicates and holes")
        
        -- Hostile permutation and duplicate removal
        s_items({4, 1, 3, 5, false, 2})
        text = root:text()
        assert_eq(text, "41352", "keyed permutations")
    end)

    -- 5. Resilient scope cleanup when cleanups raise errors
    act(function()
        local run1, run2 = false, false
        local Comp = function()
            H.onCleanup(function() run1 = true end)
            H.onCleanup(function() error("hostile cleanup error") end)
            H.onCleanup(function() run2 = true end)
            return h("div")
        end
        local root = createRoot()
        root:render(h(Comp))
        local ok = pcall(function() root:unmount() end)
        
        assert_eq(run1, true, "cleanup 1 ran despite error")
        assert_eq(run2, true, "cleanup 2 ran before error")
    end)

    print("Done. Passed: " .. passed .. ", Failed: " .. failed)
    if failed > 0 then
        os.exit(1)
    end
end

run_hostile_tests()
