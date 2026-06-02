import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const projectDir = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(projectDir, "..");
const buildVariant = process.argv[2] === "release" ? "main-release" : "main";
const outputDir = path.join(projectDir, "build/macos", buildVariant, "app");
const appName = "Snap-O Network Inspector";
const appBundleName = `${appName}.app`;
const sourceElectronApp = path.join(projectDir, "node_modules/electron/dist/Electron.app");
const appBundle = path.join(outputDir, appBundleName);
const contentsDir = path.join(appBundle, "Contents");
const resourcesDir = path.join(contentsDir, "Resources");
const bundledAppDir = path.join(resourcesDir, "app");
const packageJson = JSON.parse(await fs.readFile(path.join(projectDir, "package.json"), "utf8"));
const versionInfo = await readVersionInfo(path.join(repoRoot, "VERSION"));

await ensureBuiltArtifacts();
await fs.rm(outputDir, { recursive: true, force: true });
await fs.mkdir(outputDir, { recursive: true });
execFileSync("/usr/bin/ditto", [sourceElectronApp, appBundle], { stdio: "inherit" });

await rebrandBundle();
await copyAppPayload();
await copyRuntimeDependencies();

console.log(appBundle);

async function ensureBuiltArtifacts() {
  for (const relativePath of [
    "dist-electron/electron/main.js",
    "dist-electron/electron/cli-entry.js",
    "dist-renderer/index.html"
  ]) {
    try {
      await fs.access(path.join(projectDir, relativePath));
    } catch {
      throw new Error(`Missing build artifact ${relativePath}. Run npm run build first.`);
    }
  }
}

async function rebrandBundle() {
  const infoPlist = path.join(contentsDir, "Info.plist");
  await fs.rename(path.join(contentsDir, "MacOS/Electron"), path.join(contentsDir, `MacOS/${appName}`));
  await fs.rm(path.join(resourcesDir, "default_app.asar"), { force: true });
  await fs.copyFile(path.join(projectDir, "resources/icons/network.icns"), path.join(resourcesDir, "network.icns"));
  await fs.copyFile(path.join(repoRoot, "VERSION"), path.join(resourcesDir, "VERSION"));

  replacePlistString(infoPlist, "CFBundleDisplayName", appName);
  replacePlistString(infoPlist, "CFBundleExecutable", appName);
  replacePlistString(infoPlist, "CFBundleIconFile", "network.icns");
  replacePlistString(infoPlist, "CFBundleIdentifier", "com.openai.snapo.network-inspector");
  replacePlistString(infoPlist, "CFBundleName", appName);
  replacePlistString(infoPlist, "CFBundleShortVersionString", versionInfo.version);
  replacePlistString(infoPlist, "CFBundleVersion", versionInfo.buildNumber ?? versionInfo.version);
  removePlistKey(infoPlist, "ElectronAsarIntegrity");
}

async function copyAppPayload() {
  await fs.mkdir(bundledAppDir, { recursive: true });
  await fs.writeFile(
    path.join(bundledAppDir, "package.json"),
    `${JSON.stringify(
      {
        name: packageJson.name,
        productName: appName,
        version: versionInfo.version,
        private: true,
        type: packageJson.type,
        main: packageJson.main
      },
      null,
      2
    )}\n`,
    "utf8"
  );
  await fs.cp(path.join(projectDir, "dist-electron"), path.join(bundledAppDir, "dist-electron"), { recursive: true });
  await fs.cp(path.join(projectDir, "dist-renderer"), path.join(bundledAppDir, "dist-renderer"), { recursive: true });
  await fs.cp(path.join(projectDir, "resources"), path.join(bundledAppDir, "resources"), { recursive: true });
}

async function copyRuntimeDependencies() {
  const copied = new Set();
  for (const dependency of ["@devicefarmer/adbkit", "fast-xml-parser"]) {
    await copyDependencyClosure(dependency, projectDir, copied);
  }
}

async function copyDependencyClosure(name, fromDir, copied) {
  const packageDir = await findPackageDir(name, fromDir);
  if (copied.has(packageDir)) return;
  copied.add(packageDir);

  const relativePackageDir = path.relative(projectDir, packageDir);
  await fs.cp(packageDir, path.join(bundledAppDir, relativePackageDir), {
    recursive: true,
    dereference: false,
    verbatimSymlinks: true
  });

  const packageJsonPath = path.join(packageDir, "package.json");
  const dependencyPackageJson = JSON.parse(await fs.readFile(packageJsonPath, "utf8"));
  const dependencies = {
    ...dependencyPackageJson.dependencies,
    ...dependencyPackageJson.optionalDependencies
  };
  for (const dependencyName of Object.keys(dependencies)) {
    await copyDependencyClosure(dependencyName, packageDir, copied);
  }
}

async function findPackageDir(name, fromDir) {
  let currentDir = path.dirname(require.resolve(name, { paths: [fromDir] }));
  while (currentDir !== path.dirname(currentDir)) {
    const packageJsonPath = path.join(currentDir, "package.json");
    try {
      const dependencyPackageJson = JSON.parse(await fs.readFile(packageJsonPath, "utf8"));
      if (dependencyPackageJson.name === name && isNamedPackageDir(currentDir, name)) return currentDir;
    } catch {
      // Walk upward until we find the package root for the resolved entrypoint.
    }
    currentDir = path.dirname(currentDir);
  }
  throw new Error(`Unable to find package root for ${name}`);
}

function isNamedPackageDir(packageDir, name) {
  return packageDir.endsWith(path.join("node_modules", ...name.split("/")));
}

async function readVersionInfo(versionFile) {
  const entries = Object.fromEntries(
    (await fs.readFile(versionFile, "utf8"))
      .split(/\r?\n/u)
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith("#"))
      .map((line) => line.split("=", 2).map((part) => part.trim()))
      .filter((parts) => parts.length === 2)
  );
  if (entries.VERSION == null) throw new Error(`Missing VERSION in ${versionFile}`);
  return {
    version: entries.VERSION,
    buildNumber: entries.BUILD_NUMBER ?? null
  };
}

function replacePlistString(plistPath, key, value) {
  execFileSync("/usr/bin/plutil", ["-replace", key, "-string", value, plistPath], { stdio: "inherit" });
}

function removePlistKey(plistPath, key) {
  try {
    execFileSync("/usr/bin/plutil", ["-remove", key, plistPath], { stdio: "ignore" });
  } catch {
    // Source Electron app bundles have this today, but older releases may not.
  }
}
