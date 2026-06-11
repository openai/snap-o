import assert from "node:assert/strict";
import test from "node:test";
import { parseVersionInfo } from "./version-info.mjs";

test("reads the app and build versions from VERSION contents", () => {
  assert.deepEqual(parseVersionInfo("VERSION = 2.3.4\nBUILD_NUMBER = 20260611.1\n"), {
    version: "2.3.4",
    buildNumber: "20260611.1"
  });
});

test("requires VERSION and permits an omitted build number", () => {
  assert.deepEqual(parseVersionInfo("VERSION=2.3.4\n"), { version: "2.3.4", buildNumber: null });
  assert.throws(() => parseVersionInfo("BUILD_NUMBER=1\n", "test-version"), /Missing VERSION in test-version/u);
});
