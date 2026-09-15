# moonstone/hydronium-cli

The Hydronium developer CLI.

```
hydronium dev [--verbose] [--show-ips]
```

`dev` spawns `meteorite dev` as a child process, tails the structured
dev-event stream meteorite appends to `.meteorite/dev/events.log`, mirrors
every event verbatim into this CLI's own durable `.hydronium/dev.log`, and
renders a live status view with [Hydronium Ink](https://moonstone.sh/packages/moonstone/hydronium-ink):

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

A fullscreen request-debug mode (method/headers/body for every request that
passed through Meteorite) is planned but not yet implemented — this package
only ships the small persistent status view described above.

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
