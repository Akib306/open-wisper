import { build } from "esbuild";

await build({
  entryPoints: ["src/renderer.ts"],
  outfile: "dist/renderer.js",
  bundle: true,
  platform: "browser",
  format: "iife",
  target: "chrome136",
  sourcemap: true,
  logLevel: "info",
});
