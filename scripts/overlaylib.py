"""Shared offline, pinned-source and iOS export rules for the owner adaptation."""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
PIN = "f86f005e3491866a2a7aa03f8894dd606a0dde8b"
DIRECTORIES = {"DeepSeekHarnessMobile", "DeepSeekHarnessMobile.xcodeproj",
               "DeepSeekHarnessMobileTests", "DeepSeekHarnessMobileUITests",
               "ActionExtension", "AgentLiveActivityWidget", "ShareExtension", "ShareSupport",
               "AppRelease", "Vendor", "Tests", "config", "gradle", "shared"}
FILES = {"AGENTS.md", "LICENSE", "build.gradle.kts", "settings.gradle.kts",
         "gradle.properties", "gradlew", "scripts/build_metal_library.sh"}
FORBIDDEN = {".git", ".gradle", ".kotlin", ".idea", ".build", ".swiftpm", "build",
             "DerivedData", "node_modules", "__pycache__", ".cache", "xcuserdata", "captures"}
SENSITIVE_SUFFIXES = {".pem", ".key", ".p8", ".p12", ".pfx", ".jks", ".keystore",
                      ".mobileprovision", ".provisionprofile", ".ipa", ".apk", ".aab", ".xcresult"}
ASSET_SUFFIXES = {".svg", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".ico", ".icns", ".pdf"}


def git(checkout: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(checkout), *args])


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def lock() -> dict:
    value = json.loads((ROOT / "upstream.lock.json").read_text())
    if value.get("commit") != PIN or value.get("product") != "ios-only":
        raise SystemExit("The iOS lock drifted from the reviewed fixed upstream SHA.")
    return value


def require_pin(checkout: Path):
    lock()
    if git(checkout, "rev-parse", "HEAD").decode().strip() != PIN:
        raise SystemExit("The source HEAD does not match the fixed upstream SHA; refusing drift.")


def exportable(name: str) -> bool:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != name or not path.parts:
        return False
    if any(part in FORBIDDEN or part.endswith((".xcarchive", ".xcresult")) for part in path.parts):
        return False
    if path.name in {".DS_Store", "Local.xcconfig", "local.properties", "key.properties", ".credentials.yaml"}:
        return False
    if path.name.startswith(".env") or path.suffix.lower() in SENSITIVE_SUFFIXES:
        return False
    if any(part.startswith("android") for part in path.parts) or path.parts[0] == "tsnetgo":
        return False
    if path.parts[0] == "Vendor" and len(path.parts) > 1 and path.parts[1] not in {"SwiftMath", "swift-markdown-ui"}:
        return False
    return name in FILES or path.parts[0] in DIRECTORIES


def safe_path(root: Path, name: str) -> Path:
    if not exportable(name):
        raise SystemExit(f"Excluded or unsafe iOS export path: {name}")
    target = root / name
    if not target.resolve().is_relative_to(root.resolve()):
        raise SystemExit(f"Path escaped export root: {name}")
    if any((root / Path(*PurePosixPath(name).parts[:i])).is_symlink()
           for i in range(1, len(PurePosixPath(name).parts) + 1)):
        raise SystemExit(f"Symlink is not an export input: {name}")
    return target


def no_secret(name: str, data: bytes):
    if re.search(br"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----", data):
        raise SystemExit(f"Private key material is not an export input: {name}")


def file_state(path: Path) -> dict:
    return {"sha256": digest(path.read_bytes()), "mode": "755" if path.stat().st_mode & 0o111 else "644"}


def pinned_files(checkout: Path) -> dict[str, tuple[bytes, str]]:
    require_pin(checkout)
    # Archive only roots that can contribute to the reviewed export. Avoid
    # materializing unrelated Android/history/media or vendored tool binaries.
    names = [value.decode() for value in git(checkout, "ls-tree", "-r", "--name-only", "-z", PIN).split(b"\0") if value]
    roots = set()
    for name in names:
        if not exportable(name):
            continue
        parts = PurePosixPath(name).parts
        roots.add("/".join(parts[:2]) if parts[0] == "Vendor" else parts[0] if parts[0] in DIRECTORIES else name)
    archive = git(checkout, "archive", "--format=tar", PIN, "--", *sorted(roots))
    result = {}
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        for member in bundle:
            if member.isdir() or not exportable(member.name):
                continue
            if not member.isfile():
                raise SystemExit(f"Non-regular upstream export entry: {member.name}")
            data = bundle.extractfile(member).read()
            no_secret(member.name, data)
            result[member.name] = (data, "755" if member.mode & 0o111 else "644")
    return result


def current_files(checkout: Path, base: dict) -> dict[str, tuple[bytes, str]]:
    paths = {x.decode() for x in git(checkout, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0") if x}
    result = {}
    for name in sorted(set(base) | paths):
        if not exportable(name):
            continue
        path = safe_path(checkout, name)
        if not path.exists():
            continue
        if not path.is_file():
            raise SystemExit(f"Expected a regular input file: {name}")
        data = path.read_bytes()
        no_secret(name, data)
        result[name] = (data, "755" if path.stat().st_mode & 0o111 else "644")
    return result


def states(files: dict) -> dict:
    return {name: {"sha256": digest(value[0]), "mode": value[1]} for name, value in sorted(files.items())}


def write_file(root: Path, name: str, data: bytes, mode: str):
    target = safe_path(root, name)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    target.chmod(int(mode, 8))


def apply_patch(directory: Path, patch: Path, *, check: bool):
    environment = os.environ.copy()
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        environment.pop(key, None)
    # Prepared exports have no .git; prevent discovery of the owner repository.
    environment["GIT_CEILING_DIRECTORIES"] = str(directory.parent)
    args = ["git", "apply", "--whitespace=error-all"]
    if check:
        args.append("--check")
    subprocess.run([*args, str(patch)], cwd=directory, env=environment, check=True)


def validate_layer() -> dict:
    lock()
    overlay = ROOT / "overlay"
    manifest = json.loads((overlay / "manifest.json").read_text())
    if manifest.get("upstream_commit") != PIN:
        raise SystemExit("Overlay commit does not match the fixed iOS lock.")
    expected = manifest["artifacts"]
    actual = {p.relative_to(overlay).as_posix() for p in overlay.rglob("*") if p.is_file() and p.name != "manifest.json"}
    if actual != set(expected):
        raise SystemExit("The overlay file list differs from its SHA256 manifest.")
    for name, sha in expected.items():
        path = overlay / name
        if path.is_symlink() or not path.resolve().is_relative_to(overlay) or digest(path.read_bytes()) != sha:
            raise SystemExit(f"Overlay digest mismatch or unsafe artifact: {name}")
    tree = json.loads((overlay / "tree.json").read_text())
    for collection in (tree["text"], tree["new"], tree["replacements"], tree["removals"]):
        for name in collection:
            safe_path(Path("/deepclub-export-validation"), name)
    rows = subprocess.check_output(["git", "apply", "--numstat", "-z", str(overlay / "deepclub.patch")])
    patch_names = {row.split(b"\t", 2)[2].decode() for row in rows.split(b"\0") if row}
    if patch_names != set(tree["text"]):
        raise SystemExit("Text patch paths do not match the reviewed tree manifest.")
    return tree
