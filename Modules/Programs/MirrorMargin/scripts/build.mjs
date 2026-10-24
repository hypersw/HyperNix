import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { basename } from "node:path";
import { build } from "esbuild";

const fingerprint = (content) => createHash("sha256").update(content).digest("hex").slice(0, 12);

await rm("dist", { force: true, recursive: true });
await mkdir("dist", { recursive: true });

const css = await readFile("src/style.css");
const cssName = `style-${fingerprint(css)}.css`;
await writeFile(`dist/${cssName}`, css);

const bundle = await build({
  bundle: true,
  entryPoints: ["src/main.js"],
  entryNames: "app-[hash]",
  format: "esm",
  metafile: true,
  minify: true,
  outdir: "dist",
  sourcemap: false,
  target: ["es2022"],
});
const appOutput = Object.keys(bundle.metafile.outputs).find((path) => /^dist\/app-[^/]+\.js$/.test(path));
if (!appOutput) throw new Error("esbuild did not emit the application bundle");

const html = await readFile("src/index.html", "utf8");
await writeFile(
  "dist/index.html",
  html.replace("style.css", cssName).replace("app.js", basename(appOutput)),
);
