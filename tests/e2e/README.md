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
