"""Exercise the production listener in disposable sandboxed apps using Launch Services."""

import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

root = Path(sys.argv[1])
identity = os.environ.get("DEVICE_MANAGER_SIGNING_IDENTITY")
bundle_id = "com.example.snapo-security-" + uuid.uuid4().hex
service_id = bundle_id + ".AndroidHostService"


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=30)


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))


def sign(path, signer, *args):
    run("codesign", "--force", "--sign", signer, "--options", "runtime", "--timestamp=none", "--enforce-constraint-validity", *args, str(path))


entitlements = root / "sandbox.plist"
write_plist(entitlements, {"com.apple.security.app-sandbox": True})
service = root / "AndroidHostService.xpc"
shutil.copytree(Path(sys.argv[2]), service)
info_path = service / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["CFBundleIdentifier"] = service_id
write_plist(info_path, info)


def check(name, app_id, signer, expected):
    app = root / (name + ".app")
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy2(root / "client", app / "Contents/MacOS/Client")
    copied_service = app / "Contents/XPCServices/AndroidHostService.xpc"
    shutil.copytree(service, copied_service)
    write_plist(app / "Contents/Info.plist", {
        "CFBundleIdentifier": app_id,
        "CFBundleExecutable": "Client",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
        "TestServiceIdentifier": service_id,
    })
    sign(app, signer, "--entitlements", str(entitlements))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    # Signing a different parent must leave the embedded service untouched.
    original = hashlib.sha256((service / "Contents/MacOS/AndroidHostService").read_bytes()).digest()
    copied = hashlib.sha256((copied_service / "Contents/MacOS/AndroidHostService").read_bytes()).digest()
    assert original == copied
    output = root / (name + ".out")
    errors = root / (name + ".err")
    run("open", "-n", "-W", "--stdout", str(output), "--stderr", str(errors), str(app))
    actual = output.read_text().strip()
    assert actual == expected, (name, actual, errors.read_text())
    print(f"{name}: {actual}", flush=True)


sign(service, "-")
if sys.argv[3] in ("Debug", "Local"):
    check("DevelopmentHelper", bundle_id, "-", "accepted")
    sys.exit(0)

check("AdHocHelper", bundle_id, "-", "rejected")
if not identity:
    print("Skip signed Release callers: set DEVICE_MANAGER_SIGNING_IDENTITY to an Apple Development identity.")
    sys.exit(0)
sign(service, identity)
signature = run("codesign", "--display", "--verbose=4", str(service)).stderr
team = next(line.split("=", 1)[1] for line in signature.splitlines() if line.startswith("TeamIdentifier="))
assert team and team != "not set"
constraint = root / "responsible.coderequirement"
run("sh", "scripts/write-host-constraint.sh", str(constraint), bundle_id, team)

callers = [
    ("authorized", bundle_id, identity, "accepted"),
    ("other-app", bundle_id + ".unrelated", identity, "rejected"),
    ("ad-hoc", bundle_id, "-", "rejected"),
]
if other_identity := os.environ.get("SNAPO_TEST_OTHER_SIGNING_IDENTITY"):
    callers.append(("other-team", bundle_id, other_identity, "rejected"))

# Test caller authentication alone, then the same callers with launch protection.
for mode in ("listener", "launch"):
    if mode == "launch":
        sign(service, identity, "--launch-constraint-responsible", str(constraint))
    for name, app_id, signer, expected in callers:
        check(f"{mode}-{name}", app_id, signer, expected)

# A mismatched launch constraint must block even a caller the listener would accept.
run("sh", "scripts/write-host-constraint.sh", str(constraint), bundle_id + ".wrong", team)
sign(service, identity, "--launch-constraint-responsible", str(constraint))
check("LaunchConstraintAlone", bundle_id, identity, "rejected")
