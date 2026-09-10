import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { packagePlugin } from "./package-plugin.mjs";
import { checkBoundaries } from "./check-boundaries.mjs";

test("packaging preserves a third plugin's index.html and inlines assets", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "snapo-plugin-"));
  try {
    await mkdir(path.join(directory, "dist"));
    await writeFile(path.join(directory, "plugin.json"), JSON.stringify({ id: "sample" }));
    await writeFile(
      path.join(directory, "dist/index.html"),
      '<html><body><h1 id="sample">Sample</h1><script type="module" src="./main.js"></script><link rel="stylesheet" href="./style.css"></body></html>'
    );
    await writeFile(path.join(directory, "dist/main.js"), 'window.sample = "ready";');
    await writeFile(path.join(directory, "dist/style.css"), "h1 { color: green; }");
    await packagePlugin(directory);
    const html = await readFile(path.join(directory, "dist/index.html"), "utf8");
    assert.match(html, /id="sample">Sample/);
    assert.match(html, /window.sample/);
    assert.match(html, /color: green/);
    assert.doesNotMatch(html, /src=|href=/);
    assert.deepEqual(JSON.parse(await readFile(path.join(directory, "dist/plugin.json"))), {
      id: "sample"
    });
    await writeFile(path.join(directory, "dist/index.html"), '<script src="../outside.js"></script>');
    await assert.rejects(packagePlugin(directory), /Invalid bundle path/);
    await rm(path.join(directory, "dist/index.html"));
    await writeFile(path.join(directory, "dist/sample.html"), "not the entry");
    await assert.rejects(packagePlugin(directory), /ENOENT/);
    await writeFile(path.join(directory, "outside.html"), "outside");
    await symlink(path.join(directory, "outside.html"), path.join(directory, "dist/index.html"));
    await assert.rejects(packagePlugin(directory), /escapes plugin/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("boundaries reject relative, alias, and dynamic imports across inspectors", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "snapo-boundaries-"));
  try {
    for (const name of ["network", "tweaks", "host-sdk"]) {
      await mkdir(path.join(root, name, "src"), { recursive: true });
      await writeFile(path.join(root, name, "package.json"), JSON.stringify({ name }));
      await writeFile(
        path.join(root, name, "tsconfig.json"),
        JSON.stringify({
          compilerOptions: { baseUrl: ".", paths: { "alias/*": ["../tweaks/src/*"] } },
          include: ["src"]
        })
      );
      await writeFile(path.join(root, name, "src/index.ts"), "export const value = 1;");
    }
    assert.deepEqual(checkBoundaries(root), []);
    await writeFile(
      path.join(root, "network/src/index.ts"),
      'import "../../tweaks/src/index"; export { value } from "alias/index"; import("../../tweaks/src/index");'
    );
    assert.equal(checkBoundaries(root).length, 3);
    await writeFile(path.join(root, "host-sdk/src/index.ts"), 'import "../../network/src/index";');
    assert.equal(checkBoundaries(root).length, 4);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
