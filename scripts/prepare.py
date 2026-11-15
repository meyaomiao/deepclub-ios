#!/usr/bin/env python3
"""Rebuild an iOS-only source export offline from the exact local upstream SHA."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from overlaylib import (ROOT, PIN, apply_patch, digest, file_state, pinned_files,
                        safe_path, states, validate_layer, write_file)


def verify_export(output: Path, expected: dict):
    paths = {p.relative_to(output).as_posix() for p in output.rglob("*") if p.is_file() or p.is_symlink()}
    if paths != set(expected):
        raise SystemExit("Source export contains missing or extra files (including excluded local data).")
    for name, value in expected.items():
        if file_state(safe_path(output, name)) != value:
            raise SystemExit(f"Prepared source digest or executable mode mismatch: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-checkout", required=True, type=Path,
                        help="local checkout whose HEAD is exactly upstream.lock.json; never fetched or modified")
    parser.add_argument("--output", type=Path, default=ROOT / ".work/DeepClub-source")
    args = parser.parse_args()
    checkout = args.upstream_checkout.resolve()
    output = args.output.resolve()
    if output.exists() or output == checkout or output.is_relative_to(checkout) or checkout.is_relative_to(output):
        raise SystemExit("Choose a new output directory outside the upstream checkout; no existing data is overwritten.")
    if output == ROOT or ROOT.is_relative_to(output):
        raise SystemExit("The export output cannot contain the owner repository.")
    tree = validate_layer()
    overlay = ROOT / "overlay"
    base = pinned_files(checkout)
    expected_base = json.loads((overlay / "upstream-state.json").read_text())
    expected = json.loads((overlay / "source-state.json").read_text())
    if states(base) != expected_base:
        raise SystemExit("The local upstream export does not match the reviewed input SHA256 manifest.")
    for collection in (tree["text"], tree["replacements"], tree["removals"]):
        for name, value in collection.items():
            if name not in base or digest(base[name][0]) != value["before_sha256"]:
                raise SystemExit(f"Pinned input digest mismatch: {name}")
    for name in tree["new"]:
        if name in base:
            raise SystemExit(f"Unexpected new-file collision in pinned source: {name}")
    for collection, layer in [("new", "new"), ("replacements", "replace")]:
        for name, value in tree[collection].items():
            source = safe_path(overlay / layer, name)
            if digest(source.read_bytes()) != value["sha256"]:
                raise SystemExit(f"Layer digest does not match its file record: {name}")
    output.mkdir(parents=True)
    for name, (data, mode) in base.items():
        write_file(output, name, data, mode)
    patch = overlay / "deepclub.patch"
    if patch.stat().st_size:
        apply_patch(output, patch, check=True)
        apply_patch(output, patch, check=False)
    for name in tree["removals"]:
        target = safe_path(output, name)
        # This exact target and its original bytes were checked before any write.
        if digest(target.read_bytes()) != tree["removals"][name]["before_sha256"]:
            raise SystemExit(f"Removal input changed: {name}")
        target.unlink()
    for collection, layer in [("new", "new"), ("replacements", "replace")]:
        for name, value in tree[collection].items():
            write_file(output, name, safe_path(overlay / layer, name).read_bytes(), value["mode"])
    for name, value in tree["text"].items():
        safe_path(output, name).chmod(int(value["mode"], 8))
    # Remove only empty directories left by reviewed upstream art removals.
    for name in tree["removals"]:
        parent = safe_path(output, name).parent
        while parent != output and parent.exists() and not any(parent.iterdir()):
            if not parent.resolve().is_relative_to(output) or parent.is_symlink():
                raise SystemExit("Unexpected empty-directory removal target.")
            parent.rmdir()
            parent = parent.parent
    verify_export(output, expected)
    print(f"Prepared {len(expected)} verified iOS source files at {output}")
    print(f"Fixed upstream: {PIN}; no upstream network requests, Android product, private keys or build caches exported.")


if __name__ == "__main__":
    main()
