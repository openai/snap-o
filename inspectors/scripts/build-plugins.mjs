import { readdir, readFile, mkdir, rm, cp } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = fileURLToPath(new URL("..", import.meta.url));
const output = path.join(root, "dist");
const plugins = [];
for (const entry of await readdir(root, { withFileTypes: true })) {
  if (!entry.isDirectory() || ["node_modules", "dist"].includes(entry.name)) continue;
  const directory = path.join(root, entry.name);
  let manifest;
  try {
    manifest = JSON.parse(await readFile(path.join(directory, "plugin.json"), "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") continue;
    throw error;
  }
  if (manifest.id !== entry.name || !/^[a-z][a-z0-9.-]{0,99}$/.test(manifest.id)) {
    throw new Error(`Invalid plugin directory: ${entry.name}`);
  }
  plugins.push({ directory, manifest });
}
if (!plugins.length) throw new Error("No inspector plugins found");
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const { directory, manifest } of plugins) {
  execFileSync("npm", ["run", "build"], { cwd: directory, stdio: "inherit" });
  await cp(path.join(directory, "dist"), path.join(output, manifest.id), { recursive: true });
}
