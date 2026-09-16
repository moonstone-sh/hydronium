# hydronium/cli

The Hydronium developer CLI.

```
hydronium dev [--verbose] [--show-ips] [--fullscreen]
              [--meteorite-args "<flags>"]
```

`dev` spawns `meteorite dev` as a child process, tails the structured
dev-event stream meteorite appends to `.meteorite/dev/events.log`, mirrors
every event verbatim into this CLI's own durable `.hydronium/dev.log`, and
renders a live status view with [Hydronium Ink](https://moonstone.sh/packages/hydronium/ink):

```
 ➜  Hydronium app up and running on http://127.0.0.1:8080/
    12 routes · 340ms
    GET /home · 47ms · 127.0.0.1 x3
    hmr watch · 2ms · 127.0.0.1
    reload ok
```

## Flags

| Flag | Effect |
| :--- | :--- |
| `--verbose` | Display density only — shows more rows in the collapsed events pane. Does not change what is captured or written to `.hydronium/dev.log`. |
| `--show-ips` | Appends each request's remote address to its display line. Off by default and independent of `--verbose`; the address is already recorded in the durable log regardless. |
| `--fullscreen` | Start in the fullscreen request-debug view below (`f` toggles it either way at runtime). |
| `--meteorite-args "<flags>"` | Arguments for the spawned `meteorite dev`, e.g. `"--mode hybrid_dev --backend fast_http"`. Required in practice — `meteorite dev` has no defaults of its own. |

## Fullscreen request-debug view

`f` (or starting with `--fullscreen`) takes over the terminal's alternate
screen buffer and lists **every request in `.hydronium/dev.log`** — the
durable, uncollapsed superset, including a previous session's requests, not
the 3-row display ring the status view shows:

```
 Requests 118-141 of 141      f/esc exit | j/k up/down scroll | g/G ends | q quit
   METHOD PATH                                            STATUS     TIME
   GET    /home                                              200     47ms
   GET    /__hydronium/watch                                 200      2ms
 > POST   /api/contact                                       500     18ms
 ------------------------------------------------------------------------
 POST /api/contact | 500 | 18ms | 127.0.0.1
 headers: not captured -- meteorite's dev-event stream carries no headers yet
 body: not captured -- meteorite's dev-event stream carries no bodies yet
```

(This view is deliberately pure ASCII: the terminal host paints one grid
cell per *byte* and positions each incremental-diff run by frame column, so
a multi-byte character makes partial repaints land in the wrong column.)

| Key | Effect |
| :--- | :--- |
| `f` | Toggle the fullscreen view. |
| `j` / `k`, `↓` / `↑` | Move the selected request. |
| `pgdn` / `pgup`, space | Page through the list. |
| `g` / `G` | Jump to the oldest / newest request. |
| `esc` | Leave the fullscreen view (quits from the status view). |
| `q`, `ctrl-c` | Quit. |

**Headers and bodies are not captured yet, and this view says so instead of
pretending otherwise.** Meteorite's dev-event emitter
(`zig/server/dev_events.zig`) writes method, path, status, duration and
remote address per request — no headers, no body. The detail pane renders
whatever the event actually carries and names the gap when a field is
absent, so when a later Meteorite adds `headers`/`body` to the same
`request` event they appear here with no redesign (the whole pipeline
already passes unknown fields through verbatim: envelope-only validation
when parsing, verbatim mirroring into `.hydronium/dev.log`).

Like `--verbose` and `--show-ips`, `--fullscreen` is **display only** — it
captures nothing extra. A flag that changes what is *captured*
(`--capture-bodies`) would be a separate thing and does not exist yet.

## In a generated project

`hydronium-create`'s `ssr` and `islands` templates declare
`hydronium/cli` as a `tool` dependency and generate a `dev`
script that runs this CLI with the project's own Meteorite flags, so
`moon run dev` is all a user types:

```toml
[scripts]
dev = "moon exec --dev hydronium dev --meteorite-args='--mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit'"
```

The flags travel in one `--meteorite-args` value rather than as trailing
arguments because `moon exec` consumes the first `--` after the command it
runs (`moon exec --help`: "One '--' after `<command>` is treated as an
argument delimiter and is not forwarded"), so a `--`-passthrough script
would need a second `--` to work at all. Splitting the value on whitespace
means no single argument may contain a space; nothing `meteorite dev` takes
does.

## Requirements

Meteorite must be a resolvable dependency of the project `hydronium dev` is
run from (so `meteorite` is on `PATH` once synced, e.g. via `moon exec`), and
it must be new enough to emit `.meteorite/dev/events.log` (an opt-in dev-mode
feature). Against an older Meteorite build with no emitter, `hydronium dev`
still shows the server as running — it just has no live event stream to
render, which the status view calls out explicitly rather than hanging or
erroring.

## Development-only escape hatches

Not part of the public flag grammar; useful for exercising this CLI without
a real Meteorite process:

- `HYDRONIUM_DEV_NO_SPAWN=1` — do not start a child process; only tail.
- `HYDRONIUM_DEV_EVENTS=<path>` — tail this file instead of
  `.meteorite/dev/events.log`.
- `HYDRONIUM_DEV_LOG=<path>` — write the durable log here instead of
  `.hydronium/dev.log`.
- `HYDRONIUM_METEORITE_ARGS=<flags>` — the same thing as `--meteorite-args`,
  from the environment, appended *after* the flag's own words. Kept (it
  predates the flag) for one job: overriding a flag for a single run without
  editing the project's committed `dev` script.
