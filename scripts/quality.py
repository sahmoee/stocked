#!/usr/bin/env python3
"""Check or format only changed first-party Swift files; never rewrite the whole app."""
import argparse, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--fix", action="store_true")
parser.add_argument("--base", default="HEAD", help="Git base revision for CI change checks")
args = parser.parse_args()
changed = subprocess.check_output(["git", "diff", args.base, "--name-only", "--diff-filter=ACMR", "-z"], cwd=root)
new = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root)
files = sorted({x.decode() for x in (changed + new).split(b"\0") if x.endswith(b".swift")})
files = [f for f in files if (root / f).is_file() and not any(p in pathlib.Path(f).parts for p in (".build", "checkouts", "Pods"))]
if not files:
    print("No changed Swift files")
    sys.exit(0)
commands = [["swiftformat", "--config", str(root / ".swiftformat")] + ([] if args.fix else ["--lint"]) + files,
            ["swiftlint", "lint", "--strict", "--quiet", "--config", str(root / ".swiftlint.yml")] + files]
result = 0
for command in commands:
    try: result |= subprocess.run(command, cwd=root).returncode
    except FileNotFoundError:
        print("Missing tool: " + command[0] + ". Install with brew bundle.", file=sys.stderr)
        result = 1
sys.exit(result)
