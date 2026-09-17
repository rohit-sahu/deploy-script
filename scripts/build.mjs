#!/usr/bin/env node

// Bundles + minifies the CLI scripts (admin:create, env:create,
// tunnel:token) into self-contained files under dist/ — bcryptjs and
// scripts/lib/prompt.mjs get inlined, only Node built-ins (node:fs, etc.)
// stay external. Run with:
//   npm run build          # one-off production build (minified)
//   npm run build:dev      # unminified + sourcemaps, rebuilds on file change
//
// Production usage afterwards needs no node_modules for these scripts:
//   node dist/create-admin.mjs

import * as esbuild from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const OUTDIR = path.join(ROOT, "dist");

const isDev = process.argv.includes("--dev");

// Always start from a clean dist/ — avoids stale .map files (or
// previously-minified/unminified leftovers) mismatching the current mode.
fs.rmSync(OUTDIR, { recursive: true, force: true });

const entryPoints = [
  "scripts/create-admin.mjs",
  "scripts/create-env.mjs",
  "scripts/create-cloudflare-tunnel-token.mjs",
].map((p) => path.join(ROOT, p));

const buildOptions = {
  entryPoints,
  outdir: OUTDIR,
  outExtension: { ".js": ".mjs" },
  bundle: true,
  platform: "node",
  target: "node20",
  format: "esm",
  minify: !isDev,
  sourcemap: isDev,
  // Source files already start with their own "#!/usr/bin/env node" shebang,
  // which esbuild preserves as the first line of the bundle — don't add a
  // second one here, that would be a syntax error (only line 1 is special).
  logLevel: "info",
};

if (isDev) {
  const ctx = await esbuild.context(buildOptions);
  await ctx.watch();
  console.log("==> Watching scripts/ for changes (unminified, sourcemaps on)... Ctrl+C to stop.");
} else {
  await esbuild.build(buildOptions);
  console.log("==> Production build complete: dist/*.mjs (minified, bundled, no node_modules needed at runtime).");
}
