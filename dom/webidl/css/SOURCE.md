# Vendored CSS property data

`properties.json` holds the standard (non-vendor-prefixed) CSS properties from
[`mdn-data`](https://www.npmjs.com/package/mdn-data) 2.27.1
(`css/properties.json`, license CC0-1.0), trimmed to each property's `syntax`
and `mdn_url`. `../css-style.mjs` turns it into `dom/types/dom/style.d.lua`,
the typed `style` table. To update: replace this file from a newer mdn-data
with the same trimming, then run `node dom/webidl/css-style.mjs`.
