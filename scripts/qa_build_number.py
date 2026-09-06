#!/usr/bin/env python3
"""Reserve one project-wide build number before Xcode builds. Never edits the project.

Owned by Stocked; byte-identical copies ship in the other QA-enabled Xcode repos.
Uses a process lock and atomic replacement; failed builds may leave intentional gaps.
The checked-in project is the initial floor; a local high-water mark protects clean/retry.
"""
import argparse
import fcntl
import os
from pathlib import Path
import plistlib
import re
import tempfile

BUILD = re.compile(r"(CURRENT_PROJECT_VERSION\s*=\s*)([0-9]+(?:\.[0-9]+)*)(\s*;)")
def next_number(text, floor=0):
    values = BUILD.findall(text)
    if not values:
        raise ValueError("No numeric CURRENT_PROJECT_VERSION settings found")
    # Transition a legacy dotted build to an integer strictly above its major.
    number = max([floor] + [int(value.split('.')[0]) for _, value, _ in values]) + 1
    return number


def atomic_write(path, text):
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    fd, name = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def reserve(project, floor=0, reservation_dir=None):
    project = Path(project).resolve()
    path = project / 'project.pbxproj'
    state = project.parent / '.qa-build'
    state.mkdir(exist_ok=True)
    with (state / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        counter = state / 'number'
        stored = int(counter.read_text().strip()) if counter.exists() else 0
        number = next_number(path.read_text(), max(floor, stored))
        # Commit the reservation first. An interrupted write can skip, never reuse.
        atomic_write(counter, str(number) + '\n')
        if reservation_dir:
            reservation = Path(reservation_dir)
            reservation.mkdir(parents=True, exist_ok=True)
            atomic_write(reservation / 'qa-build-number', str(number) + '\n')
        return number


def stamp_product(path, reservation_dir):
    """Runs after ProcessInfoPlistFile, before signing. Generated plists too."""
    number = int((Path(reservation_dir) / 'qa-build-number').read_text().strip())
    if number < 1:
        raise ValueError('Invalid reserved build number')
    path = Path(path)
    data = plistlib.loads(path.read_bytes())
    data['CFBundleVersion'] = str(number)
    # Built output only, never source. In-place retains permissions and format
    # and avoids touching unrelated generated metadata or any marketing version.
    path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY, sort_keys=False))
    print('QA build ' + str(number) + ': ' + path.parent.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project')
    parser.add_argument('--floor', type=int, default=0)
    parser.add_argument('--reservation-dir')
    parser.add_argument('--stamp-product')
    args = parser.parse_args()
    if args.stamp_product:
        if not args.reservation_dir:
            parser.error('--reservation-dir is required for stamping')
        stamp_product(args.stamp_product, args.reservation_dir)
    elif args.project:
        print(reserve(args.project, args.floor, args.reservation_dir))
    else:
        parser.error('--project or --stamp-product is required')


if __name__ == '__main__':
    main()
