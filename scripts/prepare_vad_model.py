#!/usr/bin/env python3
"""Prepare the pinned, checksum-verified whisper.cpp VAD model using stdlib only."""

import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parent.parent


def verified(path, manifest):
    if not path.is_file() or path.stat().st_size != manifest["bytes"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(64 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == manifest["sha256"]


def prepare(cache_directory):
    manifest = json.loads((ROOT / "assets" / "vad-model.json").read_text())
    cache_directory = cache_directory.resolve()
    destination = cache_directory / manifest["file"]
    if verified(destination, manifest):
        return destination
    cache_directory.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        print("Downloading pinned Silero VAD model…", file=sys.stderr)
        with tempfile.NamedTemporaryFile(
            dir=cache_directory,
            prefix=manifest["file"] + ".",
            suffix=".part",
            delete=False,
        ) as output:
            temporary = Path(output.name)
            request = urllib.request.Request(
                manifest["url"], headers={"User-Agent": "LumaCaption-VAD-build"}
            )
            total = 0
            with urllib.request.urlopen(request, timeout=60) as source:
                for chunk in iter(lambda: source.read(64 * 1024), b""):
                    total += len(chunk)
                    if total > manifest["bytes"]:
                        raise ValueError("Downloaded VAD model exceeds expected size")
                    output.write(chunk)
        if not verified(temporary, manifest):
            raise ValueError("Downloaded VAD model failed size/SHA256 verification")
        # The previous cache remains intact until the replacement is verified.
        temporary.replace(destination)
        return destination
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cache-dir", type=Path, default=ROOT / ".tools" / "vad"
    )
    args = parser.parse_args()
    try:
        print(prepare(args.cache_dir))
    except (OSError, ValueError) as error:
        print("Cannot prepare VAD model: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
