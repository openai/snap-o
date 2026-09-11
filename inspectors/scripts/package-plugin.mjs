import { readFile, writeFile, realpath, copyFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { JSDOM, VirtualConsole } from "jsdom";

export async function packagePlugin(directory) {
  const root = await realpath(path.join(directory, "dist"));
  async function asset(relative) {
    if (!relative || path.isAbsolute(relative) || relative.includes("\\") || relative.split("/").includes("..")) {
      throw new Error(`Invalid bundle path: ${relative}`);
    }
    const file = await realpath(path.resolve(root, relative));
    if (!file.startsWith(root + path.sep)) throw new Error(`Bundle path escapes plugin: ${relative}`);
    return file;
  }
  const entry = await asset("index.html");
  const dom = new JSDOM(await readFile(entry, "utf8"), { virtualConsole: new VirtualConsole() });
  const document = dom.window.document;
  for (const script of document.querySelectorAll("script[src]")) {
    const source = await readFile(await asset(script.getAttribute("src")), "utf8");
    script.removeAttribute("src");
    script.removeAttribute("crossorigin");
    script.textContent = source.replace(/<\/script/gi, "<\\/script");
  }
  for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
    const style = document.createElement("style");
    const css = await readFile(await asset(link.getAttribute("href")), "utf8");
    if (/@import\b|url\(\s*["']?(?!data:)[^\s"')]/i.test(css)) throw new Error("Plugin CSS must inline its assets");
    style.textContent = css.replace(/<\/style/gi, "<\\/style");
    link.replaceWith(style);
  }
  if (document.querySelector('link[href], [src]:not([src^="data:"])')) {
    throw new Error("Plugin entry must be self-contained");
  }
  await writeFile(entry, dom.serialize());
  await copyFile(path.join(directory, "plugin.json"), path.join(root, "plugin.json"));
  dom.window.close();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await packagePlugin(path.resolve(process.argv[2] ?? "."));
}
