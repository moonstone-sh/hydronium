# PWA and static search integration

Hydronium does not need service-worker behavior in its component runtime.
The release builder needs a public, fully rendered HTML tree and its client
assets. Search and offline output are later build products over that tree.

The current post-render PWA builder lives in
`moonstone.sh/packages/web-foundation`. It hashes the final precache input and
emits a scoped worker and manifest. The isolated `hydronium-evaluation/docs`
app now proves the proposed order with a Hydronium route tree: render four
public routes, index their article bodies with Pagefind, build the worker, and
check offline search and navigation in Chromium. Hydronium router now accepts
`prerender = true` on literal, loader-free leaves, and the installed
`hydronium/ballad` package exports those routes through Meteorite.
The installed build package now coordinates export, Pagefind, and PWA output.
The evaluation app pins Pagefind in its Bun lockfile. A create-template option
and release-artifact wiring are still missing.

To make this a Hydronium project option, the remaining work is specific:

1. Extend the current literal, loader-free static-output contract only when
   build-time loader data and parameter expansion have explicit declarations.
   The exporter currently renders the same HTML as SSR before an optional
   app-specific transform. It must not fetch private registry data for indexing.
2. Have the docs create template pin Pagefind and emit the tested build
   declaration. The installed coordinator already runs it before hashing the
   worker. `data-pagefind-body` belongs on article content, not navigation.
   Keep heading and command search as separate result providers.
3. Join the static tree, Pagefind index, manifest, and worker into one Ballad
   release artifact. `hydronium create --pwa docs` can then emit the declaration;
   `minimal`, `ink`, and ordinary SSR projects should not inherit a worker.
4. Test the packaged result in a browser: install, search all docs, disconnect,
   search again, open an uncached and a precached route, then verify API and
   registry requests never enter Cache Storage. Also test update and rollback
   across two releases.

The current Moonstone docs home URL is `/docs`, not `/docs/`. Its worker script
is served at `/docs-worker.js` with scope `/docs`, and its fetch handler permits
only the exact `/docs` path and descendants. Reusing `/docs/sw.js` with scope
`/docs/` would leave the home URL uncontrolled. The current builder therefore
requires a canonical scope without a trailing slash. Supporting a trailing
slash scope needs its own route-key and precache test before it is exposed.

State-preserving Hydronium HMR remains separate from the production worker.
Development should not register a service worker. Meteorite can provide the
dev change stream; the release worker only handles deployed assets and offline
navigation.
