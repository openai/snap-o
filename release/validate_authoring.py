#!/usr/bin/env python3
"""Stage packages locally and build an independent Example tool. Never uploads packages."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = "https://openai.firewall.socket.dev/npm/"
MAVEN_NS = {"m": "http://maven.apache.org/POM/4.0.0"}


def run(command, cwd, capture=False, env=None):
    print(f"[{cwd.name}] {' '.join(map(str, command))}", flush=True)
    result = subprocess.run(command, cwd=cwd, check=True, text=True,
                            env={**os.environ, "NPM_CONFIG_REGISTRY": REGISTRY, **(env or {})},
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout


def properties(path):
    return dict(tuple(part.strip() for part in line.split("=", 1)) for line in path.read_text().splitlines()
                if "=" in line and not line.lstrip().startswith("#"))


def verify_maven(repository):
    poms = list(repository.rglob("*.pom"))
    assert len(poms) == 3, f"Expected core library, plugin implementation, and marker; found {poms}"
    coordinates = []
    for path in poms:
        root = ET.parse(path).getroot()
        get = lambda name: root.findtext(f"m:{name}", namespaces=MAVEN_NS)
        group, artifact, version = get("groupId"), get("artifactId"), get("version")
        coordinates.append(f"{group}:{artifact}:{version}")
        for section in ("name", "description", "url", "licenses", "developers", "scm"):
            assert root.find(f"m:{section}", MAVEN_NS) is not None, f"Missing {section}: {path}"
        if artifact.endswith(".gradle.plugin"):
            dependency = root.find("m:dependencies/m:dependency", MAVEN_NS)
            assert dependency is not None, "Plugin marker must identify its implementation"
            parts = [dependency.findtext(f"m:{key}", namespaces=MAVEN_NS)
                     for key in ("groupId", "artifactId", "version")]
            target = repository.joinpath(*parts[0].split("."), parts[1], parts[2], f"{parts[1]}-{parts[2]}.jar")
            assert target.is_file(), f"Marker implementation is missing: {target}"
        else:
            extension = "aar" if get("packaging") == "aar" else "jar"
            for suffix in (f".{extension}", "-sources.jar", "-javadoc.jar", ".module"):
                assert path.with_name(f"{artifact}-{version}{suffix}").is_file(), f"Missing {suffix}: {path}"
    return sorted(coordinates)


def verify_sdk(archive):
    with tarfile.open(archive) as package:
        names = set(package.getnames())
        expected = {"package/package.json", "package/README.md", "package/LICENSE",
                    "package/dist/index.js", "package/dist/index.d.ts", "package/dist/bridge.js"}
        assert expected <= names, f"Missing SDK files: {expected - names}"
        assert not any("/src/" in name or ".test." in name or "node_modules" in name for name in names)
        metadata = json.load(package.extractfile("package/package.json"))
        assert not metadata.get("private")
        assert metadata["publishConfig"]["access"] == "public"
        return metadata


def verify_example(example):
    debug = example / "app/build/outputs/apk/debug/app-debug.apk"
    release = example / "app/build/outputs/apk/release/app-release-unsigned.apk"
    asset = "assets/snapo/inspectors/example/frontend.zip"
    with zipfile.ZipFile(debug) as apk:
        assert asset in apk.namelist(), "Example frontend was not packaged"
        import io
        with zipfile.ZipFile(io.BytesIO(apk.read(asset))) as frontend:
            assert "index.html" in frontend.namelist()
            assert any(name.endswith(".js") for name in frontend.namelist())
            assert not any(name.endswith(".map") for name in frontend.namelist())
    with zipfile.ZipFile(release) as apk:
        assert not any(name.startswith("assets/snapo/inspectors/") for name in apk.namelist()), \
            "Release app must not contain the debug-only Example tool"
    descriptors = list((example / "example-tool/build").glob("**/snapo_inspector_*.xml"))
    assert descriptors, "Example tool descriptor was not generated"
    for path in descriptors:
        descriptor = ET.parse(path).getroot()
        assert "protocolVersion" not in descriptor.attrib, "Tool discovery must not define protocol versions"
        assert descriptor.get("icon") == "@drawable/example_tool_icon"
        assert descriptor.get("hostApiVersion") == "3"
    android = "{http://schemas.android.com/apk/res/android}"
    for variant in ("debug", "release"):
        manifest = example / f"app/build/intermediates/merged_manifests/{variant}/process{variant.title()}Manifest/AndroidManifest.xml"
        providers = ET.parse(manifest).findall("./application/provider")
        initializers = [(provider, metadata) for provider in providers
                        for metadata in provider.findall("meta-data")
                        if metadata.get(android + "name") == "com.example.snapo.tool.ExampleInitializer"]
        if variant == "debug":
            assert len(initializers) == 1, "Debug app must register the Example initializer exactly once"
            provider, metadata = initializers[0]
            assert provider.get(android + "name") == "androidx.startup.InitializationProvider"
            assert provider.get(android + "exported") == "false"
            assert metadata.get(android + "value") == "androidx.startup"
        else:
            assert not initializers, "Release app must not initialize the debug-only Example tool"
    return debug


def node_free_environment():
    directories = os.environ.get("PATH", os.defpath).split(os.pathsep)
    path = os.pathsep.join(directory for directory in directories
                           if not any((Path(directory) / name).is_file()
                                      for name in ("node", "node.exe", "npm", "npm.cmd")))
    assert shutil.which("node", path=path) is None
    assert shutil.which("npm", path=path) is None
    return {"PATH": path}


def verify_configuration_cache(command, example, env):
    cached = [*command, "--configuration-cache"]
    run(cached, example, env=env)
    reused = run(cached, example, capture=True, env=env)
    assert "Reusing configuration cache." in reused, "Configuration cache was not reused"


def verify_node_runtimes(example, command, managed_env):
    verify_configuration_cache([*command, ":example-tool:buildSnapoToolFrontend"], example, managed_env)

    init = example / "installed-node.gradle"
    installed_node = Path(shutil.which("node")).resolve()
    installed_env = {"SNAPO_EXPECT_NODE_ROOT": str(installed_node.parent)}
    installed = [*command, "--init-script", str(init), ":example-tool:buildSnapoToolFrontend"]
    try:
        init.write_text('''
gradle.beforeProject { project ->
    project.pluginManager.withPlugin("com.openai.snapo.tool-packager") {
        project.extensions.getByName("node").download.set(false)
    }
}
''')
        run([*installed, "--rerun-tasks"], example, env=installed_env)
        verify_configuration_cache(installed, example, installed_env)
    finally:
        init.unlink(missing_ok=True)


def verify_prebuilt_frontend(example, command, managed_env):
    init = example / "prebuilt-frontend.gradle"
    prebuilt = [*command, "--init-script", str(init), ":app:assembleDebug"]
    try:
        init.write_text('''
gradle.beforeProject { project ->
    project.pluginManager.withPlugin("com.openai.snapo.tool-packager") {
        project.extensions.getByName("snapoTool").frontendAssets.set(
            project.layout.projectDirectory.dir("frontend/dist"))
    }
}
''')
        graph = run([*prebuilt, "--dry-run"], example, capture=True, env=managed_env)
        for task in ("nodeSetup", "npmSetup", "npmInstall", "buildSnapoToolFrontend"):
            assert f":example-tool:{task} " not in graph, f"Prebuilt assets unexpectedly schedule {task}"
        run(prebuilt, example, env=managed_env)
    finally:
        init.unlink(missing_ok=True)


def verify_automatic_node_repository(example, command, managed_env):
    module_build = example / "example-tool/build.gradle.kts"
    original_build = module_build.read_text()
    default_build = original_build.replace("node { distBaseUrl.set(null as String?) }\n", "")
    assert default_build != original_build, "Example's Node repository override was not found"
    init = example / "automatic-node-repository.gradle"
    try:
        init.write_text('''
gradle.settingsEvaluated { settings ->
    settings.dependencyResolutionManagement.repositoriesMode.set(
        org.gradle.api.initialization.resolve.RepositoriesMode.PREFER_PROJECT)
    settings.dependencyResolutionManagement.repositories.clear()
}
gradle.beforeProject { project ->
    project.pluginManager.withPlugin("com.openai.snapo.tool-packager") {
        project.extensions.getByName("node").workDir.set(project.layout.buildDirectory.dir("default-node"))
    }
}
''')
        module_build.write_text(default_build)
        run([*command, "--init-script", str(init), ":example-tool:buildSnapoToolFrontend", "--rerun-tasks"], example,
            env={**managed_env, "SNAPO_EXPECT_NODE_ROOT": str(example / "example-tool/build/default-node")})
    finally:
        module_build.write_text(original_build)
        init.unlink(missing_ok=True)


def verify_frontend_initializer(example, command, managed_env):
    init = example / "initialize-frontend.gradle"
    frontend = example / "example-tool/initialized-frontend"
    # Use the staged SDK so this also validates changes before an npm release.
    try:
        init.write_text('''
gradle.beforeProject { project ->
    project.pluginManager.withPlugin("com.openai.snapo.tool-packager") {
        project.extensions.getByName("snapoTool").frontendDirectory.set(
            project.layout.projectDirectory.dir("initialized-frontend"))
        def packageFile = project.layout.projectDirectory.file("initialized-frontend/package.json").asFile
        def sdkArchive = project.layout.projectDirectory.file("frontend/vendor/host.tgz").asFile
        project.tasks.named("initSnapoToolFrontend") {
            doFirst {
                def metadata = new groovy.json.JsonSlurper().parse(packageFile)
                metadata.dependencies["@snap-o/tool-host"] = sdkArchive.toURI().toString()
                packageFile.text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(metadata))
            }
        }
    }
}
''')
        configured = [*command, "--init-script", str(init)]
        run([*configured, ":example-tool:initSnapoToolFrontend", "--configuration-cache"], example, env=managed_env)
        assert (frontend / "package-lock.json").is_file(), "Initializer did not install dependencies"
        assert (frontend / "src/main.tsx").is_file(), "Initializer did not write the starter"
        run([*configured, ":example-tool:zipSnapoToolFrontend"], example, env=managed_env)
        assert (frontend / "dist/index.html").is_file(), "Generated frontend did not build"
        source = frontend / "src/main.tsx"
        source.write_text(source.read_text() + "\n// Keep user edits.\n")
        expected = source.read_text()
        refused = subprocess.run([*configured, ":example-tool:initSnapoToolFrontend", "--configuration-cache"],
                                 cwd=example, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 env={**os.environ, "NPM_CONFIG_REGISTRY": REGISTRY, **managed_env})
        assert refused.returncode != 0 and "Frontend directory is not empty" in refused.stdout, refused.stdout
        assert source.read_text() == expected, "Initializer overwrote user edits"
        aliases = run([*configured, ":example-tool:toolBuild", ":example-tool:toolZip"],
                      example, capture=True, env=managed_env)
        assert "toolBuild is deprecated" in aliases and "toolZip is deprecated" in aliases
        dev = run([*configured, ":example-tool:toolDev", "--dry-run"], example, capture=True, env=managed_env)
        assert ":example-tool:devSnapoToolFrontend " in dev, "Development alias does not delegate"
    finally:
        init.unlink(missing_ok=True)


def verify_frontend_modes(example, overrides, managed_env):
    command = [str(example / "gradlew"), "--no-daemon", *overrides]
    verify_node_runtimes(example, command, managed_env)
    verify_prebuilt_frontend(example, command, managed_env)
    verify_automatic_node_repository(example, command, managed_env)
    verify_frontend_initializer(example, command, managed_env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="A new or empty directory outside the checkout")
    args = parser.parse_args()
    output = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="snapo-authoring-"))
    if output == ROOT or ROOT in output.parents:
        parser.error("Use an output directory outside the checkout to verify independent consumption")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output directory must be empty")
    android = ROOT
    repository = output / "maven"
    npm_output = output / "npm"
    npm_output.mkdir()
    gradle = str(android / "gradlew")
    local = [f"-Psnapo.authoringRepository={repository}", "-Psnapo.localAuthoring=true"]
    run([gradle, "--no-daemon", ":tool-core:publishAllPublicationsToAuthoringRepository", *local], android)
    run([gradle, "--no-daemon", "test", "validatePlugins", "publishAllPublicationsToAuthoringRepository", *local],
        ROOT / "tool-sdk/gradle-plugin")
    coordinates = verify_maven(repository)

    sdk = json.loads((ROOT / "tool-sdk/host/package.json").read_text())
    run(["npm", "ci", f"--registry={REGISTRY}"], ROOT / "tool-sdk/host")
    run(["npm", "run", "build"], ROOT / "tool-sdk/host")
    packed = json.loads(run(["npm", "pack", "--ignore-scripts",
                             "--json", "--pack-destination", str(npm_output)], ROOT / "tool-sdk/host", capture=True))
    archive = npm_output / packed[0]["filename"]
    verify_sdk(archive)

    example = output / "example"
    shutil.copytree(ROOT / "examples/tool", example,
                    ignore=shutil.ignore_patterns(".gradle", ".kotlin", ".idea", "build", "node_modules",
                                                  "dist", ".test-build", "vendor", "local.properties"))
    frontend = example / "example-tool/frontend"
    (frontend / "verify-node.cjs").write_text('''
const assert = require("node:assert/strict");
const path = require("node:path");
const relative = path.relative(process.env.SNAPO_EXPECT_NODE_ROOT, process.execPath);
assert(!relative.startsWith("..") && !path.isAbsolute(relative),
    `Unexpected Node executable: ${process.execPath}`);
''')
    package_path = frontend / "package.json"
    package = json.loads(package_path.read_text())
    original_build = package["scripts"]["build"]
    package["scripts"]["build"] = "node verify-node.cjs && " + package["scripts"]["build"]
    package_path.write_text(json.dumps(package, indent=2) + "\n")
    (frontend / "vendor").mkdir()
    shutil.copyfile(archive, frontend / "vendor/host.tgz")
    # The tarball changes with SDK edits; retain the locked third-party dependencies.
    lock_path = frontend / "package-lock.json"
    if lock_path.exists():
        lock = json.loads(lock_path.read_text())
        lock["packages"].pop(f"node_modules/{sdk['name']}", None)
        lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    run(["npm", "install", "--package-lock-only", "--ignore-scripts", f"--registry={REGISTRY}"], frontend)
    version = properties(ROOT / "VERSION")["VERSION"]
    group = properties(android / "gradle.properties")["GROUP"]
    settings = example / "gradle.properties"
    values = properties(settings)
    values.update(snapoVersion=version, snapoGroup=group)
    settings.write_text("".join(f"{key}={value}\n" for key, value in values.items()))
    overrides = [f"-PsnapoRepository={repository}"]
    managed_env = {**node_free_environment(),
                   "SNAPO_EXPECT_NODE_ROOT": str(example / "example-tool/.gradle/nodejs")}
    run([str(example / "gradlew"), "--no-daemon", *overrides, ":app:assembleDebug", ":app:assembleRelease",
         ":example-tool:testDebugUnitTest", ":app:lintDebug", ":app:lintRelease", ":example-tool:lintDebug"], example,
        env=managed_env)
    run(["npm", "test"], frontend)
    verify_frontend_modes(example, overrides, managed_env)
    apk = verify_example(example)
    package["scripts"]["build"] = original_build
    package_path.write_text(json.dumps(package, indent=2) + "\n")
    (frontend / "verify-node.cjs").unlink()
    report = {"mavenCoordinates": coordinates, "npmPackage": f"{sdk['name']}@{sdk['version']}",
              "npmTarball": str(archive), "exampleProject": str(example), "debugApk": str(apk),
              "frontendModes": ["managed-node-without-path", "installed-node", "prebuilt", "automatic-node-repository",
                                "frontend-initializer", "legacy-task-aliases"],
              "configurationCacheReused": True, "published": False}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
