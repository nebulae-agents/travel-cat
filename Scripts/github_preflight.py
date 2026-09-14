#!/usr/bin/env python3
"""Refuse Git index entries that are unsafe for the public source repository."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import NamedTuple


DEFAULT_MAX_BYTES = 5 * 1024 * 1024
ASSET_POLICY_PATH = "config/public-assets.json"
DEMO_CONFIG_PATH = "config/deploy.demo.json"
MAX_POLICY_BYTES = 64 * 1024
REGULAR_MODES = {"100644", "100755"}
FORMAL_ASSET_PREFIXES = (
    "Assets/",
    "Fixtures/",
    "Tests/Fixtures/",
    "Sources/TravelUI/Resources/",
)
GENERATED_COMPONENTS = {
    ".build",
    ".swiftpm",
    ".worktrees",
    ".superpowers",
    "deriveddata",
    "dist",
    "travelpetdata",
    "__pycache__",
}
GENERATED_SUFFIXES = (".app", ".dsym", ".xcresult")
GENERATED_FILES = (".dmg", ".pkg", ".dsym.zip", ".pyc")
CREDENTIAL_BASENAMES = {
    ".netrc",
    ".npmrc",
    ".pypirc",
    "credentials",
    "credentials.json",
    "service-account.json",
    "service_account.json",
    "client-secret.json",
    "client_secret.json",
}
CREDENTIAL_SUFFIXES = (".p12", ".pfx", ".key")
SECRET_PATTERNS = (
    re.compile(br"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    re.compile(br"(?<![0-9A-Z])AKIA[0-9A-Z]{16}(?![0-9A-Z])"),
    re.compile(br"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{36,255}(?![A-Za-z0-9])"),
    re.compile(br"(?<![A-Za-z0-9_-])sk-(?:live-)?[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"),
    re.compile(br"(?<![A-Za-z0-9_-])xox[baprs]-[A-Za-z0-9-]{10,}(?![A-Za-z0-9_-])"),
    re.compile(br"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_-])"),
)


class Violation(NamedTuple):
    code: str
    path: str


class IndexEntry(NamedTuple):
    mode: str
    object_id: str
    stage: int
    path: str


def _git(repo, *arguments):
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout


def _index_entries(repo):
    entries = []
    for record in _git(repo, "ls-files", "--stage", "-z").split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, object_id, stage = metadata.decode("ascii").split()
        entries.append(
            IndexEntry(
                mode,
                object_id,
                int(stage),
                raw_path.decode("utf-8", errors="surrogateescape"),
            )
        )
    return entries


def _is_private_path(path):
    lowered = path.casefold()
    parts = PurePosixPath(lowered).parts
    basename = parts[-1] if parts else ""
    if ".local" in parts:
        return True
    if lowered == "config/deploy.local.json":
        return True
    if lowered.startswith("config/deploy.") and (
        ".backup" in lowered or ".receipt" in lowered
    ):
        return True
    if basename == ".env" or (basename.startswith(".env.") and basename != ".env.example"):
        return True
    if basename in CREDENTIAL_BASENAMES or basename.endswith(CREDENTIAL_SUFFIXES):
        return True
    return False


def _is_generated_path(path):
    lowered = path.casefold()
    parts = PurePosixPath(lowered).parts
    if any(part in GENERATED_COMPONENTS for part in parts):
        return True
    if any(part.endswith(GENERATED_SUFFIXES) for part in parts):
        return True
    if lowered.endswith((".log", ".out", ".err")) and not _is_formal_asset(path):
        return True
    return bool(parts and parts[-1].endswith(GENERATED_FILES))


def _is_formal_asset(path):
    return path.startswith(FORMAL_ASSET_PREFIXES)


def _blob(repo, object_id):
    return _git(repo, "cat-file", "blob", object_id)


def _blob_size(repo, object_id):
    return int(_git(repo, "cat-file", "-s", object_id).decode("ascii").strip())


def _hash_blob(repo, object_id):
    process = subprocess.Popen(
        ["git", "-C", str(repo), "cat-file", "blob", object_id],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    digest = hashlib.sha256()
    size = 0
    assert process.stdout is not None
    while True:
        chunk = process.stdout.read(64 * 1024)
        if not chunk:
            break
        size += len(chunk)
        digest.update(chunk)
    _, stderr = process.communicate()
    if process.returncode != 0:
        raise subprocess.CalledProcessError(
            process.returncode, process.args, output=b"", stderr=stderr
        )
    return size, digest.hexdigest()


def _load_asset_policy(repo, entries):
    matches = [entry for entry in entries if entry.path == ASSET_POLICY_PATH and entry.stage == 0]
    if not matches:
        return {}, None
    entry = matches[0]
    if entry.mode not in REGULAR_MODES:
        return {}, Violation("malformed-asset-policy", ASSET_POLICY_PATH)
    try:
        if _blob_size(repo, entry.object_id) > MAX_POLICY_BYTES:
            raise ValueError("asset policy exceeds size limit")
        document = json.loads(_blob(repo, entry.object_id).decode("utf-8"))
        if not isinstance(document, dict) or document.get("schemaVersion") != 1:
            raise ValueError("unsupported policy schema")
        assets = document.get("assets")
        if not isinstance(assets, list):
            raise ValueError("assets must be a list")
        approved = {}
        for item in assets:
            if not isinstance(item, dict):
                raise ValueError("asset entries must be objects")
            path = item.get("path")
            size = item.get("bytes")
            digest = item.get("sha256")
            reason = item.get("reason")
            if (
                not isinstance(path, str)
                or not _is_formal_asset(path)
                or path.startswith("/")
                or ".." in PurePosixPath(path).parts
                or "\\" in path
                or not isinstance(size, int)
                or isinstance(size, bool)
                or size < 0
                or not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None
                or not isinstance(reason, str)
                or not reason.strip()
                or path in approved
            ):
                raise ValueError("invalid asset entry")
            approved[path] = (size, digest)
        return approved, None
    except (UnicodeError, ValueError, TypeError, json.JSONDecodeError):
        return {}, Violation("malformed-asset-policy", ASSET_POLICY_PATH)


def _demo_config_violation(repo, entries):
    matches = [
        entry for entry in entries
        if entry.path == DEMO_CONFIG_PATH and entry.stage == 0
    ]
    if not matches:
        return None
    entry = matches[0]
    if entry.mode not in REGULAR_MODES:
        return Violation("unsafe-demo-config", DEMO_CONFIG_PATH)
    try:
        if _blob_size(repo, entry.object_id) > MAX_POLICY_BYTES:
            raise ValueError("demo config exceeds size limit")
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate demo field")
                result[key] = value
            return result

        document = json.loads(_blob(repo, entry.object_id).decode("utf-8"),
                              object_pairs_hook=unique_object)
        expected = {"schemaVersion", "applicationDirectory", "dataRoot"}
        if isinstance(document, dict) and type(document.get("schemaVersion")) is int and document["schemaVersion"] == 1:
            expected.add("codexHome")
        if not isinstance(document, dict) or set(document) != expected:
            raise ValueError("demo fields do not match schema")
        if type(document["schemaVersion"]) is not int or document["schemaVersion"] not in (1, 2):
            raise ValueError("unsupported demo schema")
        for key in expected - {"schemaVersion"}:
            value = document[key]
            if (not isinstance(value, str) or not value.startswith("~/")
                    or value != value.strip() or len(value) <= 2
                    or ".." in PurePosixPath(value).parts
                    or "\\" in value or any(ord(char) < 32 for char in value)):
                raise ValueError("demo path must be a safe home-relative suggestion")
    except (UnicodeError, ValueError, TypeError, json.JSONDecodeError):
        return Violation("unsafe-demo-config", DEMO_CONFIG_PATH)

    return None


def check_repository(repo, max_bytes=DEFAULT_MAX_BYTES):
    """Return public-source policy violations found in the repository's whole index."""
    repo = Path(repo).resolve(strict=True)
    if isinstance(max_bytes, bool) or not isinstance(max_bytes, int) or max_bytes < 0:
        raise ValueError("max_bytes must be a non-negative integer")
    actual_root = Path(
        _git(repo, "rev-parse", "--show-toplevel").decode("utf-8").strip()
    ).resolve()
    if actual_root != repo:
        raise ValueError("repository must name the exact Git worktree root")

    entries = _index_entries(repo)
    approved_assets, policy_violation = _load_asset_policy(repo, entries)
    demo_violation = _demo_config_violation(repo, entries)
    violations = []
    if policy_violation is not None:
        violations.append(policy_violation)
    if demo_violation is not None:
        violations.append(demo_violation)

    verified_approved_assets = set()
    for entry in entries:
        if entry.stage != 0:
            violations.append(Violation("unresolved-index", entry.path))
            continue
        if entry.mode not in REGULAR_MODES:
            violations.append(Violation("nonregular-mode", entry.path))
            continue
        if _is_private_path(entry.path):
            violations.append(Violation("private-path", entry.path))
            continue
        if _is_generated_path(entry.path):
            violations.append(Violation("generated-path", entry.path))
            continue

        size = _blob_size(repo, entry.object_id)
        approved = approved_assets.get(entry.path)
        if size > max_bytes:
            if approved is None:
                violations.append(Violation("oversized-blob", entry.path))
            else:
                if _hash_blob(repo, entry.object_id) != approved:
                    violations.append(Violation("approved-asset-mismatch", entry.path))
                verified_approved_assets.add(entry.path)
            continue

        contents = _blob(repo, entry.object_id)
        if approved is not None:
            actual = (size, hashlib.sha256(contents).hexdigest())
            if actual != approved:
                violations.append(Violation("approved-asset-mismatch", entry.path))
            verified_approved_assets.add(entry.path)
        if b"\0" not in contents[:8192] and any(pattern.search(contents) for pattern in SECRET_PATTERNS):
            violations.append(Violation("credential-content", entry.path))

    for path in approved_assets:
        if path not in verified_approved_assets:
            violations.append(Violation("approved-asset-mismatch", path))

    return violations


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    args = parser.parse_args(argv)
    try:
        violations = check_repository(args.repository, max_bytes=args.max_bytes)
    except (ValueError, OSError, subprocess.CalledProcessError, UnicodeError):
        print("github-preflight: refused because the repository could not be safely inspected", file=sys.stderr)
        return 65
    if violations:
        counts = {}
        for violation in violations:
            counts[violation.code] = counts.get(violation.code, 0) + 1
        summary = " ".join(f"{code}={counts[code]}" for code in sorted(counts))
        print(f"github-preflight: refused {summary}", file=sys.stderr)
        return 65
    print("github-preflight: status=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
