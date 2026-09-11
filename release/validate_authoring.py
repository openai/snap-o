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


def run(command, cwd, capture=False):
    print(f"[{cwd.name}] {' '.join(map(str, command))}", flush=True)
    result = subprocess.run(command, cwd=cwd, check=True, text=True,
                            env={**os.environ, "NPM_CONFIG_REGISTRY": REGISTRY},
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout


def properties(path):
    return dict(tuple(part.strip() for part in line.split("=", 1)) for line in path.read_text().splitlines()
                if "=" in line and not line.lstrip().startswith("#"))


def verify_maven(repository):
    poms = list(repository.rglob("*.pom"))
    assert len(poms) == 5, f"Expected runtime, two plugin implementations, and two markers; found {poms}"
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
    return debug


def verify_frontend_modes(example, overrides):
    init = example / "frontend-mode.gradle"
    init.write_text('''
gradle.beforeProject { project ->
    project.pluginManager.withPlugin("com.openai.snapo.inspector") {
        project.extensions.getByName("snapoInspector").downloadNode.set(false)
    }
}
''')
    run([str(example / "gradlew"), "--no-daemon", *overrides, "--init-script", str(init),
         ":example-tool:inspectorBuild", "--rerun-tasks"], example)
    init.write_text('''
gradle.beforeProject { project ->
    project.pluginManager.withPlugin("com.openai.snapo.inspector") {
        project.extensions.getByName("snapoInspector").frontendAssets.set(
            project.layout.projectDirectory.dir("frontend/dist"))
    }
}
''')
    command = [str(example / "gradlew"), "--no-daemon", *overrides, "--init-script", str(init),
               ":app:assembleDebug"]
    graph = run([*command, "--dry-run"], example, capture=True)
    for task in ("nodeSetup", "npmSetup", "npmInstall", "inspectorBuild"):
        assert f":example-tool:{task} " not in graph, f"Prebuilt assets unexpectedly schedule {task}"
    run(command, example)
    init.unlink()


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
    android = ROOT / "snapo-link-android"
    repository = output / "maven"
    npm_output = output / "npm"
    npm_output.mkdir()
    gradle = str(android / "gradlew")
    local = [f"-Psnapo.authoringRepository={repository}", "-Psnapo.localAuthoring=true"]
    run([gradle, "--no-daemon", ":inspector-runtime:publishAllPublicationsToAuthoringRepository", *local], android)
    run([gradle, "--no-daemon", "test", "validatePlugins", "publishAllPublicationsToAuthoringRepository", *local],
        android / "inspector-gradle-plugin")
    coordinates = verify_maven(repository)

    sdk = json.loads((ROOT / "inspectors/host-sdk/package.json").read_text())
    run(["npm", "ci", f"--registry={REGISTRY}"], ROOT / "inspectors")
    run(["npm", "run", "build", f"--workspace={sdk['name']}"], ROOT / "inspectors")
    packed = json.loads(run(["npm", "pack", f"--workspace={sdk['name']}", "--ignore-scripts",
                             "--json", "--pack-destination", str(npm_output)], ROOT / "inspectors", capture=True))
    archive = npm_output / packed[0]["filename"]
    verify_sdk(archive)

    example = output / "example"
    shutil.copytree(ROOT / "snapo-link-android/example", example,
                    ignore=shutil.ignore_patterns(".gradle", ".kotlin", ".idea", "build", "node_modules",
                                                  "dist", ".test-build", "vendor", "local.properties"))
    frontend = example / "example-tool/frontend"
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
    run([str(example / "gradlew"), "--no-daemon", *overrides, ":app:assembleDebug", ":app:assembleRelease",
         ":example-tool:testDebugUnitTest", ":app:lintDebug", ":app:lintRelease", ":example-tool:lintDebug"], example)
    run(["npm", "test"], frontend)
    verify_frontend_modes(example, overrides)
    apk = verify_example(example)
    report = {"mavenCoordinates": coordinates, "npmPackage": f"{sdk['name']}@{sdk['version']}",
              "npmTarball": str(archive), "exampleProject": str(example), "debugApk": str(apk),
              "frontendModes": ["managed-node", "installed-node", "prebuilt"], "published": False}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
