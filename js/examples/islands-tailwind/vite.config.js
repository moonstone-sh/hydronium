import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";
import hydronium from "@hydronium-js/vite";

export default defineConfig({
  plugins: [
    tailwindcss(),
    hydronium({
      // dual-hmr-island.js is fetched at runtime by bootstrap.js from a URL in
      // the page's client plan. Nothing in Vite's own module graph imports it,
      // so without declaring it here `vite build` would not emit it at all.
      islands: ["src/dual-hmr-island.js"],
      // In a normal project the Vite root IS the project root and this option
      // is unnecessary. This example is deliberately split -- Meteorite serves
      // from examples/meteorite_ssr while Vite's root is here -- so point the
      // file at the Lua server's project so it can read the port Vite bound.
      devOriginFile: "../../../examples/meteorite_ssr/.hydronium/vite-dev.json",
    }),
  ],
  // build.manifest and server.cors deliberately NOT set here: the plugin
  // supplies both. If it stops doing so, M1's manifest gate and M2's
  // cross-origin island import both fail, which is the point.
});
