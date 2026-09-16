import { expect, test } from "bun:test";
import { buildStaticSite } from "../web/site-build";
import { buildPwa } from "../web/pwa";
import { exportStaticSite } from "../web/static-export";

test("static export rejects an application root as output", async () => {
  await expect(exportStaticSite({
    appDir: import.meta.dir,
    outputDir: import.meta.dir,
    siteModule: "views.Site",
    meteoriteInput: "src/main.lua",
  })).rejects.toThrow("child of the application directory");
});

test("static export rejects unsafe module and asset declarations before invoking Moonstone", async () => {
  await expect(exportStaticSite({
    appDir: import.meta.dir,
    outputDir: `${import.meta.dir}/static-dist`,
    siteModule: "../private",
    meteoriteInput: "src/main.lua",
  })).rejects.toThrow("Invalid site module");
  await expect(exportStaticSite({
    appDir: import.meta.dir,
    outputDir: `${import.meta.dir}/static-dist`,
    siteModule: "views.Site",
    meteoriteInput: "src/main.lua",
    assets: ["../private"],
  })).rejects.toThrow("Invalid static asset");
});

test("Pagefind precache requires a Pagefind build step", async () => {
  await expect(buildStaticSite({
    export: {
      appDir: import.meta.dir,
      outputDir: `${import.meta.dir}/static-dist`,
      siteModule: "views.Site",
      meteoriteInput: "src/main.lua",
    },
    pwa: {
      scope: "/",
      workerUrl: "/service-worker.js",
      startUrl: "/",
      name: "Docs",
      shortName: "Docs",
      icons: [{ src: "/icon.svg", sizes: "any", type: "image/svg+xml" }],
      offline: "shell",
      assetDirectories: ["/pagefind"],
      assets: [],
      maxPrecacheBytes: 1024,
    },
  })).rejects.toThrow("no Pagefind task");
});

test("PWA rejects a worker that cannot control its scope", async () => {
  await expect(buildPwa({
    siteDir: import.meta.dir,
    scope: "/docs",
    workerUrl: "/docs/service-worker.js",
    startUrl: "/docs",
    name: "Docs",
    shortName: "Docs",
    icons: [{ src: "/icon.svg", sizes: "any", type: "image/svg+xml" }],
    offline: "shell",
    assetDirectories: [],
    assets: [],
    maxPrecacheBytes: 1024,
  })).rejects.toThrow("cannot control scope");
});
