import { execFileSync } from "node:child_process";
import { constants } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { packager } from "@electron/packager";
import { parseVersionInfo } from "./version-info.mjs";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const projectDir = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(projectDir, "..");
const isRelease = process.argv[2] === "release";
const buildVariant = isRelease ? "main-release" : "main";
const targetArch = isRelease ? "arm64" : process.arch;
const variantDir = path.join(projectDir, "build/macos", buildVariant);
const packagerOutputDir = path.join(variantDir, ".packager");
const outputDir = path.join(variantDir, "app");
const appName = "Snap-O Network Inspector";
const appBundleName = `${appName}.app`;
const appBundle = path.join(outputDir, appBundleName);
const versionFile = path.join(repoRoot, "VERSION");
const packageJson = JSON.parse(await fs.readFile(path.join(projectDir, "package.json"), "utf8"));
const electronPackageJson = JSON.parse(
  await fs.readFile(path.join(projectDir, "node_modules/electron/package.json"), "utf8")
);
const versionInfo = parseVersionInfo(await fs.readFile(versionFile, "utf8"), versionFile);
const packagedPackageJson = {
  name: packageJson.name,
  productName: appName,
  version: versionInfo.version,
  private: true,
  type: packageJson.type,
  main: packageJson.main
};

await ensureBuiltArtifacts();
await fs.rm(packagerOutputDir, { recursive: true, force: true });
await fs.rm(outputDir, { recursive: true, force: true });

const packagedPaths = await packager({
  dir: projectDir,
  out: packagerOutputDir,
  overwrite: true,
  platform: "darwin",
  arch: targetArch,
  electronVersion: electronPackageJson.version,
  name: appName,
  executableName: appName,
  appBundleId: "com.openai.snapo.network-inspector",
  extendInfo: { CFBundleIconFile: "network.icns" },
  appVersion: versionInfo.version,
  buildVersion: versionInfo.buildNumber ?? versionInfo.version,
  icon: path.join(projectDir, "resources/icons/network.icns"),
  extraResource: versionFile,
  asar: false,
  prune: true,
  derefSymlinks: false,
  quiet: true,
  ignore: [
    /^\/(?!package\.json$|dist-electron(?:\/|$)|dist-renderer(?:\/|$)|resources(?:\/|$)|node_modules(?:\/|$))/u,
    /^\/node_modules\/(?:\.package-lock\.json|\.vite-temp(?:\/|$))/u
  ],
  afterCopy: [writePackagedPackageJson]
});

if (packagedPaths.length !== 1) {
  throw new Error(`Expected one packaged app directory, received ${packagedPaths.length}`);
}

const stagedAppBundle = path.join(packagedPaths[0], appBundleName);
await restoreElectronHelperNames(stagedAppBundle);
await validatePackagedBundle(stagedAppBundle);
await fs.mkdir(outputDir, { recursive: true });
await fs.rename(stagedAppBundle, appBundle);
await fs.rm(packagerOutputDir, { recursive: true, force: true });

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

async function writePackagedPackageJson({ buildPath }) {
  await fs.writeFile(path.join(buildPath, "package.json"), `${JSON.stringify(packagedPackageJson, null, 2)}\n`, "utf8");
}

async function restoreElectronHelperNames(bundlePath) {
  const frameworksDir = path.join(bundlePath, "Contents", "Frameworks");
  for (const suffix of ["", " (GPU)", " (Plugin)", " (Renderer)"]) {
    const packagedName = `${appName} Helper${suffix}`;
    const electronName = `Electron Helper${suffix}`;
    const packagedHelper = path.join(frameworksDir, `${packagedName}.app`);
    const electronHelper = path.join(frameworksDir, `${electronName}.app`);

    await fs.rename(
      path.join(packagedHelper, "Contents", "MacOS", packagedName),
      path.join(packagedHelper, "Contents", "MacOS", electronName)
    );
    await fs.rename(packagedHelper, electronHelper);

    const infoPlist = path.join(electronHelper, "Contents", "Info.plist");
    replacePlistString(infoPlist, "CFBundleExecutable", electronName);
    replacePlistString(infoPlist, "CFBundleDisplayName", electronName);
    replacePlistString(infoPlist, "CFBundleName", electronName);
  }
}

async function validatePackagedBundle(bundlePath) {
  const frameworksDir = path.join(bundlePath, "Contents", "Frameworks");
  const helperApps = (await fs.readdir(frameworksDir, { withFileTypes: true }))
    .filter((entry) => entry.isDirectory() && entry.name.endsWith(".app"))
    .map((entry) => path.join(frameworksDir, entry.name));
  if (helperApps.length === 0) throw new Error(`No helper app bundles found in ${frameworksDir}`);

  for (const bundle of [bundlePath, ...helperApps]) {
    const executable = readPlistValue(bundle, "CFBundleExecutable");
    if (executable.length === 0 || path.basename(executable) !== executable) {
      throw new Error(`Invalid CFBundleExecutable in ${bundle}`);
    }
    const executablePath = path.join(bundle, "Contents", "MacOS", executable);
    if (!(await fs.stat(executablePath)).isFile()) {
      throw new Error(`CFBundleExecutable does not resolve to a file: ${executablePath}`);
    }
    await fs.access(executablePath, constants.X_OK);

    const appVersion = readPlistValue(bundle, "CFBundleShortVersionString");
    const buildVersion = readPlistValue(bundle, "CFBundleVersion");
    if (appVersion !== versionInfo.version || buildVersion !== (versionInfo.buildNumber ?? versionInfo.version)) {
      throw new Error(`Bundle versions do not match ${versionFile}: ${bundle}`);
    }
  }

  const bundledPackageJson = JSON.parse(
    await fs.readFile(path.join(bundlePath, "Contents/Resources/app/package.json"), "utf8")
  );
  if (bundledPackageJson.version !== versionInfo.version) {
    throw new Error(`Packaged app version does not match ${versionFile}`);
  }

  for (const dependency of ["@devicefarmer/adbkit", "fast-xml-parser"]) {
    await fs.access(path.join(bundlePath, "Contents/Resources/app/node_modules", dependency, "package.json"));
  }
}

function readPlistValue(bundle, key) {
  return execFileSync(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", path.join(bundle, "Contents", "Info.plist")],
    { encoding: "utf8" }
  ).trim();
}

function replacePlistString(plistPath, key, value) {
  execFileSync("/usr/bin/plutil", ["-replace", key, "-string", value, plistPath]);
}
