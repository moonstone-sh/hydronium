package.path = 'create/src/?.lua;' .. package.path
local json = require('hydronium_dom.server.json')
local h = require('hydronium').h
local ink = require('hydronium_ink')
local lab = require('hydronium_lab')
local runtime = require('hydronium_ink_lab.runtime')
local story = lab.story({id='ansi',render=function() return h(ink.Box,{flexDirection='column'},h(ink.Text,{color='red',bold=true},'ANSI 界'),h(ink.Text,{italic=true},'second row')) end,sizes={{columns=20,rows=6}}})
local r=runtime.new(lab.registry({story}))
local a=r:open('ansi')
local b=r:request({op='snapshot'})
-- Scrolling: an inline story taller than its terminal keeps its focus mark
-- in step with the scrolled viewport.
-- The same contract the create wizard uses: an inlineViewport box that
-- publishes scroll deltas, driven by Page keys carrying `scrollRows`.
local signals = require('hydronium.signals')
local hooks = require('hydronium_ink.hooks')
local function Tall()
  local revision, setRevision = signals.createSignal(0)
  local delta, setDelta = signals.createSignal(0)
  hooks.useInput(function(_, key)
    if key.pageUp or key.pageDown then
      setDelta((key.pageUp and -1 or 1) * (key.scrollRows or 1))
      setRevision(revision() + 1)
    end
  end)
  return function()
    local rows = {}
    for i = 1, 40 do rows[i] = h(ink.Box,{key=i,scrollFocus=i == 20 or nil},h(ink.Text,nil,'row '..i)) end
    return h(ink.Box,{flexDirection='column',inlineViewport=true,scrollRevision=revision(),scrollDelta=delta()},rows)
  end
end
local tall = lab.story({id='tall',render=function() return h(Tall) end,sizes={{columns=20,rows=10}}})
local scroller = runtime.new(lab.registry({tall}))
local t = scroller:open('tall', {columns=20,rows=10})
assert(t.terminal.inline and t.terminal.scrollable and t.height > 10)
assert(t.focus and #t.ansi > 0)
local down = scroller:request({op='scroll',lines=3})
local up = scroller:request({op='scroll',lines=-2})
assert(down.focus.y == t.focus.y - 3 and up.focus.y == t.focus.y - 1)

-- The create wizard fits its terminal (its header and form adapt to the
-- rows available); keyboard focus jumps must stay inside the viewport.
local registry = lab.registry({lab.discovery.bind({id_prefix='wizard',path='create.stories.lua'}, dofile('create/src/create/ui/create.stories.lua'))})
local wizard = runtime.new(registry)
local f = wizard:open('wizard--install-flow', {columns=80,rows=24})
assert(f.terminal.inline and not f.terminal.scrollable and f.height <= 24)
assert(f.focus and #f.ansi > 0)
wizard:request({op='bytes',bytes='\t\t'})
local initial = wizard:request({op='snapshot'})
local jump = wizard:request({op='bytes',bytes='4'})
assert(jump.focus.token ~= initial.focus.token and jump.focus.y >= 0 and jump.focus.y < 22)
local paged = wizard:request({op='bytes',bytes='\27[5~'})
local refocus = wizard:request({op='bytes',bytes='4'})
assert(refocus.focus.token ~= paged.focus.token and refocus.focus.y >= 0 and refocus.focus.y < 22)
print(json.encode({a,b}))
