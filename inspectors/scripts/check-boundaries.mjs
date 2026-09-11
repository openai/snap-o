import ts from "typescript";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export function checkBoundaries(root, packages) {
  root = fs.realpathSync(root);
  const errors = [];
  for (const name of packages) {
    const directory = path.join(root, name);
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
    const config = ts.readConfigFile(path.join(directory, "tsconfig.json"), ts.sys.readFile);
    const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, directory);
    const deps = { ...pkg.dependencies, ...pkg.devDependencies };
    if (name === "host-sdk" && Object.keys(deps).some((dep) => /^(preact|react|@snap-o\/)/.test(dep)))
      errors.push("host-sdk must not depend on UI or inspector packages");
    for (const file of parsed.fileNames) {
      const source = ts.createSourceFile(file, fs.readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true);
      function visit(node) {
        let specifier;
        if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) specifier = node.moduleSpecifier;
        else if (
          ts.isCallExpression(node) &&
          (node.expression.kind === ts.SyntaxKind.ImportKeyword || node.expression.getText(source) === "require")
        )
          specifier = node.arguments[0];
        else if (ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument)) specifier = node.argument.literal;
        if (specifier && ts.isStringLiteralLike(specifier)) {
          const value = specifier.text;
          const resolved = ts.resolveModuleName(value, file, parsed.options, ts.sys).resolvedModule;
          if (resolved) {
            const target = fs.realpathSync(resolved.resolvedFileName);
            const owner = packages.find((other) => target.startsWith(path.join(root, other) + path.sep));
            if (owner && owner !== name && !(owner === "host-sdk" && value === "@snap-o/host"))
              errors.push(`${file}: forbidden package import ${value}`);
            if (name === "host-sdk" && /^(preact|react)(\/|$)/.test(value))
              errors.push(`${file}: host SDK must remain framework independent`);
          }
        }
        ts.forEachChild(node, visit);
      }
      visit(source);
    }
  }
  return errors;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const errors = checkBoundaries(fileURLToPath(new URL("..", import.meta.url)), [
    "host-sdk",
    "../snapo-link-android/network/frontend",
    "../snapo-link-android/tweaks-core/frontend"
  ]);
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exitCode = 1;
  }
}
