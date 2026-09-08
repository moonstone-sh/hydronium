---@meta "hydronium-ambient-dom"
--[[
  Hydronium Ambient DOM Globals -- OPT-IN augmentation, not part of the
  framework's default type environment.

  What this is: one bare global per intrinsic DOM/SVG tag (`div`, `html`,
  `meta`, `button`, ...), each typed identically to its `d.<tag>` entry in
  `types/dom/init.d.lua` (inferred straight from `dom.<tag>` there, so it
  can never drift out of sync). Adding this file's directory to a
  project's `workspace.library` augments that project's ambient type
  environment so bare tags (`<div>`, not `<d.div>`) resolve to a real,
  typed global instead of LuaLS's honest "Undefined global" diagnostic.

  Why this is a SEPARATE file/directory from `types/`, not merged into
  `types/dom/init.d.lua`: Hydronium's own default `.luarc.json` lists
  the whole `types/` directory in `workspace.library`, and its test
  suite deliberately verifies (`tests/luax/isolation_spec.lua`,
  `docs/LUAX_TYPE_ENVIRONMENT_VERIFICATION.md`'s Hard Release Gate #3)
  that a project which hasn't activated a DOM environment gets zero DOM
  completion leakage on bare tags. Declaring these as ambient globals
  unconditionally, workspace-wide, would silently undo that guarantee
  for every .luax file in the repo, including ones that intentionally
  never touch hydronium.dom -- the exact "global per-tag pollution"
  trade-off that verification pass considered and rejected. Living
  outside `types/` (a sibling directory, `ambient-types/`) means the
  default config never sees this file at all; a project opts in
  explicitly and per-workspace by adding this directory to its OWN
  `workspace.library`, the same way any Lua project layers in ambient
  type declarations for a library it has decided to treat as globally
  available -- see examples/meteorite_ssr/.luarc.json for a real,
  working instance of that opt-in (a self-contained example whose whole
  purpose is DOM-authored SSR views, where ambient bare tags are exactly
  the right default, unlike the framework repo as a whole).

  `table` and `select` are deliberately excluded: both shadow a Lua
  stdlib global used constantly in ordinary Lua code
  (`table.insert`/`table.concat`, `select(...)`) -- typing the rare bare
  `<table>`/`<select>` tag is not worth breaking diagnostics on every
  other line of a project that opts into this file. Author those two
  via the lexical `<d.table>`/`<d.select>` form instead, which needs no
  ambient global and has no such collision.

  This file depends on `d` (declared in types/dom/init.d.lua) already
  being in scope -- a project that includes this directory in
  `workspace.library` must also include Hydronium's `types/` directory.
--]]

button = d.button
input = d.input
h1 = d.h1
h2 = d.h2
h3 = d.h3
h4 = d.h4
h5 = d.h5
h6 = d.h6
div = d.div
span = d.span
main = d.main
section = d.section
a = d.a
p = d.p
form = d.form
img = d.img
textarea = d.textarea
option = d.option
label = d.label
ul = d.ul
ol = d.ol
li = d.li
header = d.header
footer = d.footer
nav = d.nav
aside = d.aside
article = d.article
thead = d.thead
tbody = d.tbody
tfoot = d.tfoot
tr = d.tr
th = d.th
td = d.td
canvas = d.canvas
audio = d.audio
video = d.video
pre = d.pre
code = d.code
dialog = d.dialog
svg = d.svg
path = d.path
circle = d.circle
rect = d.rect
g = d.g
text = d.text
abbr = d.abbr
address = d.address
area = d.area
b = d.b
base = d.base
bdi = d.bdi
bdo = d.bdo
blockquote = d.blockquote
body = d.body
br = d.br
caption = d.caption
cite = d.cite
col = d.col
colgroup = d.colgroup
data = d.data
datalist = d.datalist
dd = d.dd
del = d.del
details = d.details
dfn = d.dfn
dl = d.dl
dt = d.dt
em = d.em
embed = d.embed
fieldset = d.fieldset
figcaption = d.figcaption
figure = d.figure
head = d.head
hgroup = d.hgroup
hr = d.hr
html = d.html
i = d.i
iframe = d.iframe
ins = d.ins
kbd = d.kbd
legend = d.legend
link = d.link
map = d.map
mark = d.mark
menu = d.menu
meta = d.meta
meter = d.meter
noscript = d.noscript
object = d.object
optgroup = d.optgroup
output = d.output
picture = d.picture
progress = d.progress
q = d.q
rp = d.rp
rt = d.rt
ruby = d.ruby
s = d.s
samp = d.samp
script = d.script
search = d.search
slot = d.slot
small = d.small
source = d.source
strong = d.strong
style = d.style
sub = d.sub
summary = d.summary
sup = d.sup
template = d.template
time = d.time
title = d.title
track = d.track
u = d.u
var = d.var
wbr = d.wbr
line = d.line
polyline = d.polyline
polygon = d.polygon
tspan = d.tspan
defs = d.defs
use = d.use
symbol = d.symbol
clipPath = d.clipPath
mask = d.mask
pattern = d.pattern
linearGradient = d.linearGradient
radialGradient = d.radialGradient
stop = d.stop
image = d.image
