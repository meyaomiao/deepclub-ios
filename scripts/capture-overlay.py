#!/usr/bin/env python3
"""Capture a quiescent pinned iOS checkout into text/new/replacement layers."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import tempfile

from overlaylib import (ROOT, PIN, ASSET_SUFFIXES, current_files, digest, git, json_bytes,
                        pinned_files, states, write_file)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--refresh", action="store_true", help="replace the generated owner overlay after review")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    overlay = ROOT / "overlay"
    if overlay.exists() and not args.refresh:
        raise SystemExit("An overlay already exists; review it and explicitly pass --refresh.")
    if overlay.is_symlink() or overlay.resolve() != ROOT / "overlay":
        raise SystemExit("Unexpected overlay destination.")
    base = pinned_files(checkout)
    current = current_files(checkout, base)
    tree = {"text": {}, "new": {}, "replacements": {}, "removals": {}}
    for name in sorted(set(base) | set(current)):
        before, after = base.get(name), current.get(name)
        if before == after:
            continue
        if after is None:
            tree["removals"][name] = {"before_sha256": digest(before[0]), "mode": before[1]}
        elif before is None:
            tree["new"][name] = {"sha256": digest(after[0]), "mode": after[1]}
        else:
            binary = b"\0" in before[0] or b"\0" in after[0] or Path(name).suffix.lower() in ASSET_SUFFIXES
            try:
                before[0].decode("utf-8")
                after[0].decode("utf-8")
            except UnicodeDecodeError:
                binary = True
            collection = "replacements" if binary else "text"
            tree[collection][name] = {"before_sha256": digest(before[0]), "sha256": digest(after[0]), "mode": after[1]}
    patch = git(checkout, "diff", "--no-ext-diff", "--no-color", "--no-renames", PIN, "--", *tree["text"]) if tree["text"] else b""
    if b"GIT binary patch" in patch or b"Binary files " in patch:
        raise SystemExit("Binary or reverse asset data cannot enter the text patch.")
    work = ROOT / ".work"
    work.mkdir(exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="capture-", dir=work)).resolve()
    try:
        (staging / "deepclub.patch").write_bytes(patch)
        for collection, directory in [("new", "new"), ("replacements", "replace")]:
            (staging / directory).mkdir()
            for name in tree[collection]:
                data, mode = current[name]
                write_file(staging / directory, name, data, mode)
        (staging / "tree.json").write_bytes(json_bytes(tree))
        (staging / "upstream-state.json").write_bytes(json_bytes(states(base)))
        (staging / "source-state.json").write_bytes(json_bytes(states(current)))
        artifacts = {path.relative_to(staging).as_posix(): digest(path.read_bytes())
                     for path in sorted(staging.rglob("*")) if path.is_file()}
        (staging / "manifest.json").write_bytes(json_bytes({"schema": 1, "upstream_commit": PIN, "artifacts": artifacts}))
        # A capture must never race the Swift owner. Refuse a moving checkout.
        if states(current_files(checkout, base)) != states(current):
            raise SystemExit("Source changed during capture; wait for the editing owner to hand off.")
        if git(checkout, "rev-parse", "HEAD").decode().strip() != PIN:
            raise SystemExit("Source HEAD changed during capture.")
        # Check resolved absolute targets immediately before replacing generated output.
        if overlay.is_symlink() or overlay.resolve() != ROOT / "overlay" or not staging.is_relative_to(work.resolve()):
            raise SystemExit("Unexpected generated-layer replacement path.")
        if overlay.exists():
            shutil.rmtree(overlay)
        staging.rename(overlay)
    finally:
        if staging.exists():
            if staging.is_symlink() or not staging.resolve().is_relative_to(work.resolve()):
                raise SystemExit("Unexpected capture cleanup path.")
            shutil.rmtree(staging)
    print(json.dumps({"upstream_commit": PIN, "export_files": len(current),
                      "text_files": len(tree["text"]), "patch_bytes": len(patch),
                      "new_files": len(tree["new"]), "replacements": len(tree["replacements"]),
                      "removals": len(tree["removals"])}, indent=2))


if __name__ == "__main__":
    main()
