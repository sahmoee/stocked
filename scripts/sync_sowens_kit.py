#!/usr/bin/env python3
"""Explicitly copy the owned package to a chosen consumer, then verify its files."""
import argparse, hashlib, pathlib, shutil
parser = argparse.ArgumentParser()
parser.add_argument("consumer", type=pathlib.Path)
args = parser.parse_args()
owner = pathlib.Path(__file__).resolve().parents[1] / "Packages/SowensKit"
root = args.consumer.resolve()
if not (root / ".git").exists(): raise SystemExit("Consumer must be an existing Git checkout")
target = root / "Packages/SowensKit"
for source in owner.rglob("*"):
    if not source.is_file() or any(part in (".build", ".swiftpm", ".DS_Store") for part in source.relative_to(owner).parts): continue
    destination = target / source.relative_to(owner)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(destination.read_bytes()).digest():
        raise SystemExit("Package copy verification failed")
print("Verified SowensKit copy at", target)
