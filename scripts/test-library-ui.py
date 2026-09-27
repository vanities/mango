#!/usr/bin/env python3
"""Run library UI regressions in a fresh, isolated simulator using invented demo books.

Requires Xcode, xcodegen, and demo-library (scripts/make-demo-library.py).
Keeps build logs and xcresults in the printed temporary directory. Never installs on a
personal device, reads its library, or changes the committed project configuration.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-simulator", action="store_true", help="Keep the isolated simulator for investigating a failure")
    options = parser.parse_args()
    fixtures = ROOT / "demo-library"
    if not fixtures.is_dir():
        raise SystemExit("Generate invented fixtures first: python3 scripts/make-demo-library.py")
    work = Path(tempfile.mkdtemp(prefix="mango-library-ui-"))
    print(f"UI test artifacts: {work}", flush=True)
    for name in ("Mango", "MangoTests", "Shared", "MangoWidgets", "Config"):
        (work / name).symlink_to(ROOT / name)
    shutil.copytree(ROOT / "scripts/library-ui", work / "FlowUITests")
    spec = (ROOT / "project.yml").read_text().replace("com.vanities.mango", "com.vanities.mangoqa")
    spec = "\n".join(line for line in spec.splitlines() if "CODE_SIGN_ENTITLEMENTS:" not in line)
    spec = spec.replace("\nschemes:", """
  FlowUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [FlowUITests]
    dependencies:
      - target: Mango
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vanities.libraryFlowTests
        GENERATE_INFOPLIST_FILE: YES
        TEST_TARGET_NAME: Mango

schemes:""")
    spec += """

  FlowQA:
    build:
      targets:
        Mango: all
        FlowUITests: [test]
    test:
      targets: [FlowUITests]
"""
    (work / "project.yml").write_text(spec)
    run("xcodegen", "generate", "--spec", str(work / "project.yml"))
    runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
    eligible = [r for r in runtimes if r.get("isAvailable") and r["name"].startswith("iOS ")
                and int(r["version"].split(".")[0]) >= 26]
    runtime = max(eligible, key=lambda r: tuple(map(int, r["version"].split("."))))
    sim = subprocess.check_output(["xcrun", "simctl", "create", "Mango library UI regression",
                                   "com.apple.CoreSimulator.SimDeviceType.iPhone-Air", runtime["identifier"]], text=True).strip()
    print(f"Isolated simulator: {sim}", flush=True)
    try:
        run("xcrun", "simctl", "boot", sim)
        run("xcrun", "simctl", "bootstatus", sim, "-b", timeout=180)
        args = ["xcodebuild", "-project", str(work / "Mango.xcodeproj"), "-scheme", "FlowQA",
                "-destination", f"platform=iOS Simulator,id={sim}", "-derivedDataPath", str(work / "build")]
        with (work / "build.log").open("w") as log:
            run(*args, "build-for-testing", stdout=log, stderr=subprocess.STDOUT)
        app = work / "build/Build/Products/Debug-iphonesimulator/Mango.app"
        run("xcrun", "simctl", "install", sim, str(app))
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", sim,
                                                  "com.vanities.mangoqa", "data"], text=True).strip())
        shutil.copytree(fixtures, container / "Documents/Demo")
        with (work / "tests.log").open("w") as log:
            run(*args, "test-without-building", stdout=log, stderr=subprocess.STDOUT)
        print(f"Library UI regressions passed. Results: {work / 'tests.log'}", flush=True)
    finally:
        if not options.keep_simulator:
            subprocess.run(["xcrun", "simctl", "shutdown", sim], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", sim], capture_output=True)


if __name__ == "__main__":
    main()
