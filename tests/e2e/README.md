# Consumer browser gate

`consumer_scaffold.sh` is the release-facing Hydronium test. It consumes the
artifacts exported by the root `partiture.lua` through a disposable Moonstone
file registry; it does not point dependencies at this checkout.

It currently proves the `islands` template end to end:

1. install the exported `hydronium/create` binary;
2. scaffold an app and resolve it twice (`sync`, then `sync --locked`);
3. build and run its production Meteorite server; and
4. drive Chromium against actual SSR markup and the hydrated counter, failing
   on a console error, page exception, or failed request.

The gate intentionally does not advertise the disabled SPA template or create
a generic `hydronium build` command. SPA still lacks a supported server-less
delivery contract. The SSR template needs its own production browser scenario
once its browser-Lua runtime artifact is published and usable from a fresh
registry; the islands template is the smaller published consumer closure that
already has a deterministic build/run contract. HMR remains a separate dev
server gate: this test runs the production binary and must not blur that
boundary.

### Packaged SSR + Tailwind with Bun

The same consumer harness also generates an SSR app from exported registry artifacts. CI runs it with `HYDRONIUM_CONSUMER_TEMPLATE=ssr`, `HYDRONIUM_CONSUMER_TAILWIND=1`, `HYDRONIUM_CONSUMER_DEV=1` and `HYDRONIUM_BROWSER_GATE="bun test ./js/tests/consumer_ssr_hmr.browser.test.mjs"`. It checks hydration, a reactive counter, LUAX HMR with preserved signal state, Tailwind source discovery and CSS updates without a page reload. Both consumer gates verify locked archive hashes against the candidate export.
