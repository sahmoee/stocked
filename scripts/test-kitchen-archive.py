#!/usr/bin/env python3
"""Generate original tiny fixtures with stdlib ZIP/gzip; compile native checks. No network or simulator."""
import base64
import gzip
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def archive(items, method=zipfile.ZIP_DEFLATED, stream=False):
    class Stream(io.BytesIO):
        def seekable(self):
            return False

        def seek(self, *args):
            raise io.UnsupportedOperation()

    out = Stream() if stream else io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(out, "w", compression=method) as handle:
            for name, data in items:
                handle.writestr(name, data)
    return out.getvalue()


def main():
    with tempfile.TemporaryDirectory(prefix="stocked-archive-checks-") as directory:
        folder = Path(directory)

        def save(name, data, expected=None):
            (folder / name).write_bytes(data)
            if expected is not None:
                (folder / name).with_suffix(".json").write_text(json.dumps({
                    key: base64.b64encode(value).decode() for key, value in expected.items()
                }))

        sample = {"Recipes/é/recipe.json": b'{"name":"Original fixture"}', "Recipes/é/photo.png": bytes(range(256))}
        for label, method in [("deflate", zipfile.ZIP_DEFLATED), ("stored", zipfile.ZIP_STORED)]:
            save(f"accept-{label}.zip", archive(sample.items(), method), sample)
        save("accept-stream-descriptor.zip", archive(sample.items(), stream=True), sample)
        save("accept-empty.zip", archive([]), {})
        save("accept-directories.zip", archive([("Recipes/", b""), *sample.items()]), sample)
        save("accept-empty-file.zip", archive([("recipe.json", b"")]), {"recipe.json": b""})
        commented = bytearray(archive(sample.items()))
        commented[-2:] = struct.pack("<H", 7)
        commented += b"comment"
        save("accept-comment.zip", commented, sample)
        raw_gzip = gzip.compress("Original recipe text — unchanged".encode(), mtime=0)
        save("accept-paprika-gzip.gz", raw_gzip)
        save("reject-gzip-truncated.gz", raw_gzip[:-2])
        save("reject-gzip-trailing.gz", raw_gzip + b"unexpected")
        save("reject-gzip-concatenated.gz", raw_gzip + raw_gzip)
        bad_gzip = bytearray(raw_gzip)
        bad_gzip[-8] ^= 1
        save("reject-gzip-crc.gz", bad_gzip)
        save("reject-gzip-bomb.gz", gzip.compress(b"x" * (8 * 1024 * 1024 + 1), mtime=0))
        for index, path in enumerate(["../recipe.json", "/recipe.json", "C:/recipe.json", "a/../../b", "a\\b", "a//b", "./a", "a\nb"]):
            save(f"reject-path-{index}.zip", archive([(path, b"recipe")]))
        save("reject-duplicate.zip", archive([("recipe.json", b"one"), ("recipe.json", b"two")]))
        save("reject-case-conflict.zip", archive([("Recipe.json", b"one"), ("recipe.json", b"two")]))
        symlink = zipfile.ZipInfo("linked.json")
        symlink.create_system = 3
        symlink.external_attr = 0o120777 << 16
        save("reject-symlink.zip", archive([(symlink, b"/private/file")]))
        save("reject-many-files.zip", archive([(f"{i}.json", b"") for i in range(501)]))
        save("reject-entry-bomb.zip", archive([("large.json", b"a" * (8 * 1024 * 1024 + 1))]))
        save("reject-total-bomb.zip", archive([(f"{i}.json", b"a" * (7 * 1024 * 1024)) for i in range(5)]))
        save("reject-input-size.zip", b"0" * (32 * 1024 * 1024 + 1))
        valid = archive([("recipe.json", b"Original")], zipfile.ZIP_STORED)
        save("reject-truncated.zip", valid[:-4])
        save("reject-trailing.zip", valid + b"trailer")
        bad = bytearray(valid)
        bad[30 + len("recipe.json")] ^= 1
        save("reject-crc.zip", bad)
        central = valid.index(b"PK\x01\x02")
        for label, positions, value in [
            ("encryption", [6, central + 8], 1),
            ("zip64-version", [4, central + 6], 45),
            ("method", [8, central + 10], 99),
            ("local-method-conflict", [8], 8),
        ]:
            bad = bytearray(valid)
            for position in positions:
                struct.pack_into("<H", bad, position, value)
            save(f"reject-{label}.zip", bad)
        bad = bytearray(valid)
        bad[30] = ord("z")
        save("reject-local-name-conflict.zip", bad)
        bad = bytearray(valid)
        struct.pack_into("<I", bad, central + 42, 2)
        save("reject-offset.zip", bad)
        bad = bytearray(archive(sample.items(), stream=True))
        descriptor = bad.index(b"PK\x07\x08")
        bad[descriptor + 4] ^= 1
        save("reject-descriptor-crc.zip", bad)
        extra = zipfile.ZipInfo("recipe.json")
        extra.extra = struct.pack("<HHQ", 1, 8, 2)
        save("reject-zip64-extra.zip", archive([(extra, b"{}")] ))
        bad = bytearray(archive(sample.items()))
        first = bad.index(b"PK\x01\x02")
        second = bad.index(b"PK\x01\x02", first + 4)
        struct.pack_into("<I", bad, second + 42, 0)
        save("reject-overlap.zip", bad)
        executable = folder / "archive-checks"
        subprocess.run(["xcrun", "swiftc", str(ROOT / "Stocked/KitchenArchive.swift"),
                        str(ROOT / "scripts/KitchenArchiveChecks.swift"), "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(folder)], check=True)


if __name__ == "__main__":
    main()
