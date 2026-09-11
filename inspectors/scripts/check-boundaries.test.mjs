import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { checkBoundaries } from "./check-boundaries.mjs";

test("boundaries reject relative, alias, and dynamic imports across inspectors", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "snapo-boundaries-"));
  try {
    const directories = ["network/frontend", "tweaks/frontend", "host-sdk"];
    for (const name of directories) {
      await mkdir(path.join(root, name, "src"), { recursive: true });
      await writeFile(path.join(root, name, "package.json"), JSON.stringify({ name }));
      await writeFile(
        path.join(root, name, "tsconfig.json"),
        JSON.stringify({
          compilerOptions: { baseUrl: ".", paths: { "alias/*": ["../../tweaks/frontend/src/*"] } },
          include: ["src"]
        })
      );
      await writeFile(path.join(root, name, "src/index.ts"), "export const value = 1;");
    }
    assert.deepEqual(checkBoundaries(root, directories), []);
    await writeFile(
      path.join(root, "network/frontend/src/index.ts"),
      'import "../../../tweaks/frontend/src/index"; export { value } from "alias/index"; import("../../../tweaks/frontend/src/index");'
    );
    assert.equal(checkBoundaries(root, directories).length, 3);
    await writeFile(path.join(root, "host-sdk/src/index.ts"), 'import "../../network/frontend/src/index";');
    assert.equal(checkBoundaries(root, directories).length, 4);
    await writeFile(
      path.join(root, "host-sdk/package.json"),
      JSON.stringify({ name: "@snap-o/host", dependencies: { preact: "*" } })
    );
    assert.ok(checkBoundaries(root, directories).includes("host-sdk must not depend on UI or inspector packages"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
