import { resolve } from "node:path";
import { buildPwa, type PwaBuildOptions } from "./pwa";
import { exportStaticSite, type StaticExportOptions } from "./static-export";

export interface StaticSiteBuildOptions {
  export: StaticExportOptions;
  pagefind?: { executable: string };
  pwa?: Omit<PwaBuildOptions, "siteDir">;
}

/** Render, index, then hash the final release tree into a service worker. */
export async function buildStaticSite(options: StaticSiteBuildOptions) {
  if (options.pwa && !options.pagefind && options.pwa.assetDirectories.some((dir) => dir === "/pagefind")) {
    throw new Error("PWA precache includes Pagefind, but this build has no Pagefind task");
  }
  const routes = await exportStaticSite(options.export);
  const outputDir = resolve(options.export.outputDir);
  if (options.pagefind) {
    const child = Bun.spawn([options.pagefind.executable, "--site", outputDir], {
      cwd: resolve(options.export.appDir),
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    if (code !== 0) throw new Error(`Pagefind failed (${code}): ${stderr || stdout}`);
  }
  const pwa = options.pwa ? await buildPwa({ ...options.pwa, siteDir: outputDir }) : undefined;
  return { routes, pwa };
}
