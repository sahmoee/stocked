#!/usr/bin/env python3
"""Reproducible local release gates. Never uploads, bumps versions, or installs an app."""
import argparse, json, os, pathlib, plistlib, re, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = re.compile(r"[0-9]+(\.[0-9]+){0,2}")
# Main-app platform -> platforms its embedded bundles may target.
PLATFORMS = {"iphoneos": {"iphoneos", "watchos"}, "macosx": {"macosx"}}

def validate_archive(path, approved):
    path = pathlib.Path(path)
    apps = list((path / "Products/Applications").glob("*.app"))
    if len(apps) != 1: raise ValueError("Archive must contain exactly one main application")
    def metadata(bundle):
        info = bundle / "Info.plist"
        if not info.exists(): info = bundle / "Contents/Info.plist"
        return plistlib.loads(info.read_bytes())
    main = metadata(apps[0])
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        if not main.get(key): raise ValueError("Missing app versions")
        # App Store versions are one to three period-separated integers; this also
        # rejects unresolved build-setting references such as $(MARKETING_VERSION).
        if not VERSION.fullmatch(str(main[key])): raise ValueError("Invalid " + key)
    main_id = main.get("CFBundleIdentifier")
    allowed = PLATFORMS.get(main.get("DTPlatformName"), set())
    for bundle in [apps[0]] + list(apps[0].rglob("*.appex")) + list(apps[0].rglob("*.app")):
        info = metadata(bundle)
        if info.get("CFBundleVersion") != main.get("CFBundleVersion"): raise ValueError("Embedded build numbers disagree")
        if info.get("CFBundleShortVersionString") != main.get("CFBundleShortVersionString"): raise ValueError("Embedded marketing versions disagree")
        if info.get("DTXcodeBuild") not in approved: raise ValueError("Archive used an unapproved Xcode build")
        platform = info.get("DTPlatformName", "")
        if "simulator" in platform: raise ValueError("Simulator archive cannot be released")
        if platform not in allowed: raise ValueError("Unexpected platform for " + bundle.name)
        if not re.fullmatch(re.escape(platform) + r"\d+(\.\d+)*", info.get("DTSDKName", "")):
            raise ValueError("Missing or mismatched SDK for " + bundle.name)
        identifier = info.get("CFBundleIdentifier")
        if not identifier: raise ValueError("Missing bundle identifier")
        if bundle != apps[0] and not identifier.startswith(main_id + "."):
            raise ValueError("Embedded bundle identifier is not under the app identifier")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(apps[0])], check=True)
    return main

def validate_output(value):
    if not value or not pathlib.Path(value).is_absolute():
        raise ValueError("Set SOWENS_BUILD_ROOT to an absolute output directory")
    path = pathlib.Path(value)
    if path.parts[:2] == ("/", "Volumes"):
        if len(path.parts) < 3: raise ValueError("Choose a mounted output volume")
        mount = pathlib.Path(*path.parts[:3])
        if not mount.is_mount(): raise ValueError("Output volume is not mounted")
        expected = os.environ.get("SOWENS_BUILD_VOLUME_UUID")
        if not expected: raise ValueError("Set SOWENS_BUILD_VOLUME_UUID to the verified output volume UUID")
        info = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", str(mount)]))
        if info.get("VolumeUUID", "").upper() != expected.upper() or info.get("FilesystemType") != "apfs":
            raise ValueError("Output volume identity or filesystem does not match")
    return path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["check", "check-output", "build", "archive", "validate-archive"])
    parser.add_argument("--scheme")
    parser.add_argument("--archive")
    args = parser.parse_args()
    config = json.loads((ROOT / "tooling.json").read_text())
    if args.action == "check-output":
        validate_output(os.environ.get("SOWENS_BUILD_ROOT"))
        return
    if args.action == "validate-archive":
        if not args.archive: parser.error("--archive is required")
        validate_archive(args.archive, config["approved_xcode_builds"])
        print("Archive metadata and signatures verified")
        return
    version = subprocess.check_output(["xcodebuild", "-version"], text=True)
    build = re.search(r"Build version (\S+)", version)
    if not build or build[1] not in config["approved_xcode_builds"]:
        raise ValueError("Select an approved release Xcode using DEVELOPER_DIR; beta/unknown builds are blocked")
    subprocess.run(["git", "diff", "--check"], cwd=ROOT, check=True)
    if args.action == "check":
        subprocess.run([sys.executable, str(ROOT / "scripts/quality.py")], check=True)
        return
    output = os.environ.get("SOWENS_BUILD_ROOT")
    validate_output(output)
    schemes = [x for x in config["schemes"] if args.scheme is None or x["name"] == args.scheme]
    if not schemes: raise ValueError("Unknown scheme")
    if args.action == "archive" and (not args.scheme or not args.archive):
        parser.error("archive requires --scheme and a new --archive destination")
    for scheme in schemes:
        cmd = ["xcodebuild", "-project", str(ROOT / config["project"]), "-scheme", scheme["name"],
               "-destination", scheme["destination"], "-configuration", "Release",
               "-derivedDataPath", str(pathlib.Path(output) / ROOT.name / scheme["name"])]
        if args.action == "archive":
            validate_output(str(pathlib.Path(args.archive).absolute()))
            if pathlib.Path(args.archive).exists(): raise ValueError("Refusing to overwrite an existing archive")
            cmd += ["-archivePath", str(pathlib.Path(args.archive).absolute()), "archive"]
        else: cmd += ["CODE_SIGNING_ALLOWED=NO", "build"]
        subprocess.run(cmd, cwd=ROOT, check=True)
        if args.action == "archive": validate_archive(args.archive, config["approved_xcode_builds"])

if __name__ == "__main__":
    try: main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
