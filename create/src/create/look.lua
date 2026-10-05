--[[
  create.look -- the one stylesheet every browser template (ssr, islands,
  spa) ships, so they look like one product: a dark (or light) page lit
  from behind by a blurred hydronium glow in the CLI's pH colors, a header
  (brand + Home/About), one centered sentence with an inline name field
  and a segmented counter, a submit, and a footer pointing at App.luax.

  Constraints, on purpose: no cards, no shadows, system fonts (nothing to
  download), one accent (the glow). Class names are the template contract
  shared by the generated views and the browser gates.
]]
local M = {}

M.CSS = [[/* Hydronium starter look. Plain CSS; edit freely. */
:root {
  color-scheme: dark light;
  --bg: #08090c;
  --fg: #ecedf2;
  --dim: #8d909c;
  --line: rgb(255 255 255 / 0.14);
  --wash: rgb(255 255 255 / 0.05);
  /* The Hydronium CLI's pH scale. */
  --ph-red: oklch(0.62 0.19 25);
  --ph-amber: oklch(0.75 0.15 70);
  --ph-green: oklch(0.72 0.17 145);
  --ph-blue: oklch(0.6 0.15 250);
  --ph-magenta: oklch(0.62 0.16 305);
  --glow: 0.42;
  font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}

@media (prefers-color-scheme: light) {
  :root {
    --bg: #f7f7f9;
    --fg: #121318;
    --dim: #5f6270;
    --line: rgb(0 0 0 / 0.14);
    --wash: rgb(0 0 0 / 0.04);
    --glow: 0.3;
  }
}

* { box-sizing: border-box; }
html, body { margin: 0; }
body { background: var(--bg); color: var(--fg); overflow-x: hidden; }
a { color: inherit; text-decoration: none; }

/* Light from behind: a slowly turning ring of pH colors, blurred, with a
   brighter core -- the hydronium ion glowing under the page. */
.glow {
  position: fixed;
  left: 50%;
  top: 46%;
  width: min(72vmin, 580px);
  aspect-ratio: 1;
  translate: calc(-50% + var(--glow-x, 0px)) calc(-50% + var(--glow-y, 0px));
  border-radius: 50%;
  background: conic-gradient(from 200deg, var(--ph-red), var(--ph-amber), var(--ph-green),
    var(--ph-blue), var(--ph-magenta), var(--ph-red));
  filter: blur(90px) saturate(1.15);
  opacity: var(--glow);
  z-index: 0;
  pointer-events: none;
  animation: glow 14s ease-in-out infinite alternate;
}
.glow::after {
  content: "";
  position: absolute;
  inset: 26%;
  border-radius: 50%;
  background: radial-gradient(circle, rgb(255 255 255 / 0.6), transparent 70%);
  filter: blur(28px);
}
@keyframes glow {
  from { rotate: 0deg; scale: 0.95; }
  to { rotate: 60deg; scale: 1.05; }
}
@media (prefers-reduced-motion: reduce) { .glow { animation: none; } }

.shell {
  position: relative;
  min-height: 100dvh;
  display: grid;
  grid-template-rows: auto 1fr auto;
}

.top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
  width: min(64rem, 100%);
  margin: 0 auto;
  padding: 1.25rem 1.5rem;
}
.brand { display: inline-flex; align-items: baseline; gap: 0.5rem; font-weight: 600; letter-spacing: -0.01em; }
.mark {
  background: linear-gradient(90deg, var(--ph-red), var(--ph-amber), var(--ph-green), var(--ph-blue), var(--ph-magenta));
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
}
.top nav { display: flex; gap: 1.25rem; font-size: 0.95rem; }
.top nav a { color: var(--dim); transition: color 0.15s; }
.top nav a:hover, .top nav a[aria-current="page"] { color: var(--fg); }

.stage {
  display: grid;
  place-items: center;
  padding: 4rem 1.5rem;
  text-align: center;
}

.hello { display: grid; justify-items: center; gap: 2rem; }
.line {
  margin: 0;
  max-width: 18ch;
  font-size: clamp(2rem, 6vw, 3.75rem);
  font-weight: 600;
  line-height: 1.2;
  letter-spacing: -0.035em;
  text-wrap: balance;
}
.lede { margin: 0; max-width: 36rem; color: var(--dim); font-size: 1.05rem; }

.name {
  width: 5ch;
  min-width: 3ch;
  max-width: 12ch;
  field-sizing: content;
  padding: 0 0.1em;
  border: 0;
  border-bottom: 2px solid var(--line);
  background: transparent;
  color: inherit;
  font: inherit;
  letter-spacing: inherit;
  text-align: center;
  outline: none;
  transition: border-color 0.15s;
}
.name::placeholder { color: var(--dim); opacity: 0.6; }
.name:focus { border-color: var(--fg); }

.counter {
  display: inline-flex;
  align-items: center;
  vertical-align: 0.15em;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: var(--wash);
  backdrop-filter: blur(12px);
  font-size: 0.45em;
  letter-spacing: 0;
}
.counter button {
  width: 2.25em;
  height: 2.25em;
  border: 0;
  border-radius: 999px;
  background: transparent;
  color: var(--dim);
  font: inherit;
  cursor: pointer;
  transition: color 0.15s;
}
.counter button:hover { color: var(--fg); }
.counter button:disabled { opacity: 0.35; cursor: default; }
.count { min-width: 2ch; font-variant-numeric: tabular-nums; font-weight: 600; }

.send {
  padding: 0.75rem 1.5rem;
  border: 0;
  border-radius: 999px;
  background: var(--fg);
  color: var(--bg);
  font: inherit;
  font-weight: 600;
  cursor: pointer;
  transition: opacity 0.15s, translate 0.15s;
}
.send:hover { translate: 0 -1px; }
.send:disabled { opacity: 0.5; translate: none; cursor: progress; }

.result { margin: 0; min-height: 1.5em; max-width: 40rem; color: var(--dim); }
.result:empty::before { content: "\00a0"; }
.error { color: var(--ph-red); }

.foot {
  padding: 1.5rem;
  text-align: center;
  color: var(--dim);
  font-size: 0.875rem;
}
code {
  padding: 0.15em 0.45em;
  border-radius: 6px;
  background: var(--wash);
  color: var(--fg);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.9em;
}
.result--spoken { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
.greetings { margin: 0; min-height: 1.5em; max-width: 40rem; color: var(--dim); }
.greetings span { display: inline-block; animation: greeting .3s both; animation-delay: var(--delay); }
@keyframes greeting { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: none; } }
:focus-visible { outline: 2px solid var(--fg); outline-offset: 5px; }
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation: none !important; transition: none !important; } }
]]

M.SCRIPT = [[// Small presentation effects; form submission and reactive state belong to the app.
const reduced = matchMedia("(prefers-reduced-motion: reduce)");
let frame = 0;
addEventListener("pointermove", (event) => {
  if (reduced.matches || frame) return;
  frame = requestAnimationFrame(() => {
    document.documentElement.style.setProperty("--glow-x", `${(event.clientX / innerWidth - .5) * 80}px`);
    document.documentElement.style.setProperty("--glow-y", `${(event.clientY / innerHeight - .5) * 60}px`);
    frame = 0;
  });
}, { passive: true });
const outputs = new WeakMap();
function enhance() {
  document.querySelectorAll(".result").forEach((output) => {
    const text = output.textContent;
    if (outputs.get(output) === text) return;
    outputs.set(output, text);
    const previous = output.nextElementSibling;
    if (previous?.classList.contains("greetings")) previous.remove();
    output.classList.remove("result--spoken");
    if (!text || output.classList.contains("error") || reduced.matches) return;
    const visual = document.createElement("p");
    visual.className = "greetings";
    visual.setAttribute("aria-hidden", "true");
    text.split(/(?<=!)\s+/).forEach((greeting, index) => {
      const item = document.createElement("span");
      item.textContent = greeting + " ";
      item.style.setProperty("--delay", `${index * 240}ms`);
      visual.append(item);
    });
    output.classList.add("result--spoken");
    output.after(visual);
  });
}
new MutationObserver(enhance).observe(document.body, { childList: true, subtree: true, characterData: true });
reduced.addEventListener("change", () => { document.querySelectorAll(".result").forEach(el => outputs.delete(el)); enhance(); });
enhance();
]]

return M
