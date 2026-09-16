import { copyFile, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

const MARKER = "hydronium static export v1\n";

export interface StaticExportOptions {
  appDir: string;
  outputDir: string;
  siteModule: string;
  meteoriteInput: string;
  moonHome?: string;
  assets?: string[];
  transformHtml?: (html: string, route: string) => string | Promise<string>;
}

function safeRelativeAsset(path: string): boolean {
  return path !== "" && !isAbsolute(path) && !path.includes("\\") &&
    path.split("/").every((part) => part !== "" && part !== "." && part !== "..");
}

function safeRoute(path: string): boolean {
  return path.startsWith("/") && !path.startsWith("//") &&
    !/[\\?#:*]/.test(path) &&
    (path === "/" || path.slice(1).split("/").every((part) => part !== "" && part !== "." && part !== ".."));
}

async function moon(appDir: string, moonHome: string | undefined, args: string[]): Promise<string> {
  const child = Bun.spawn(["moon", "exec", ...args], {
    cwd: appDir,
    env: { ...process.env, ...(moonHome ? { MOONSTONE_HOME: moonHome } : {}) },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (code !== 0) throw new Error(`moon exec ${args.join(" ")} failed (${code}): ${stderr || stdout}`);
  return stdout;
}

/** Render only route leaves explicitly marked `prerender = true`. */
export async function exportStaticSite(options: StaticExportOptions): Promise<string[]> {
  const appDir = resolve(options.appDir);
  const outputDir = resolve(options.outputDir);
  const relOutput = relative(appDir, outputDir);
  if (relOutput === "" || relOutput === ".." || relOutput.startsWith(`..${sep}`)) {
    throw new Error("Static output must be a child of the application directory");
  }
  if (!options.siteModule.match(/^[A-Za-z_][\w]*(\.[A-Za-z_][\w]*)*$/)) {
    throw new Error(`Invalid site module: ${options.siteModule}`);
  }
  if (!safeRelativeAsset(options.meteoriteInput)) {
    throw new Error(`Invalid Meteorite input: ${options.meteoriteInput}`);
  }
  for (const asset of options.assets ?? []) {
    if (!safeRelativeAsset(asset)) throw new Error(`Invalid static asset: ${asset}`);
  }

  const routeSource = await moon(appDir, options.moonHome, [
    "lua", "-e",
    `package.path="src/?.lua;src/?/init.lua;"..package.path; for _,path in ipairs(require(${JSON.stringify(options.siteModule)}):prerender_paths()) do print(path) end`,
  ]);
  const routes = routeSource.trim().split("\n").filter(Boolean);
  if (!routes.length) throw new Error("The site has no routes marked prerender = true");
  const unique = new Set(routes);
  if (unique.size !== routes.length || routes.some((route) => !safeRoute(route))) {
    throw new Error("The site returned duplicate or unsafe prerender paths");
  }

  const markerPath = join(outputDir, ".hydronium-static-export");
  if (await stat(outputDir).then(() => true, () => false)) {
    const marker = await readFile(markerPath, "utf8").catch(() => "");
    if (marker !== MARKER) throw new Error(`Refusing to replace unmarked output: ${outputDir}`);
    await rm(outputDir, { recursive: true });
  }
  await mkdir(outputDir, { recursive: true });
  await writeFile(markerPath, MARKER);

  for (const route of routes) {
    const raw = await moon(appDir, options.moonHome, [
      "meteorite", "invoke", "--json", options.meteoriteInput, "GET", route,
    ]);
    const response = JSON.parse(raw).response;
    if (response?.status !== 200 || !response.content_type?.startsWith("text/html") ||
      typeof response.body !== "string") {
      throw new Error(`Cannot export ${route}: ${response?.status ?? "no response"}`);
    }
    const html = options.transformHtml ? await options.transformHtml(response.body, route) : response.body;
    if (typeof html !== "string" || html === "") throw new Error(`HTML transform returned no page for ${route}`);
    const target = join(outputDir, route.slice(1), "index.html");
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, html);
  }

  for (const asset of options.assets ?? []) {
    const target = join(outputDir, asset);
    await mkdir(dirname(target), { recursive: true });
    await copyFile(join(appDir, asset), target);
  }
  return routes;
}
