#!/usr/bin/env python3
"""Export reviewed source blobs, never the local application's state or Git history."""

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import zipfile

from github_preflight import check_repository


ROOT_FILES = {"Package.swift", "README.md", ".gitignore", "LICENSE", "NOTICE", "ASSET_LICENSE.md", "AGENTS.md"}
PREFIXES = (
    "Sources/", "Tests/", "Assets/", "Fixtures/", "Scripts/", "scripts/", "Plugins/",
    "packaging/", ".agents/skills/travel-cat-agent/", "Automation/fixtures/",
    "Automation/schemas/", "Automation/tests/", "Automation/prompts/",
)
PUBLIC_DOCS = {
    "docs/portable-runtime.md", "docs/installation.md", "docs/characters.md",
    "docs/security.md", "docs/release-status.md",
    "docs/postcard-layout.md",
    "docs/local-deployment.md", "docs/public-source-policy.md",
}
PUBLIC_CONFIG = {
    "config/deploy.demo.json", "config/deploy.schema.json", "config/public-assets.json",
}
PUBLIC_ROOT_ENTRIES = {
    "CONTRIBUTING.md", "SECURITY.md", "Deploy Local.command", "Publish to GitHub.command",
}
REQUIRED = {
    "Package.swift", "README.md", "Plugins/travel-cat/.codex-plugin/plugin.json",
    "Sources/TravelUI/Resources/pet.json",
    "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp",
}


def git(source, *arguments):
    return subprocess.run(["git", "-C", str(source), *arguments], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def selected(path):
    return (path in ROOT_FILES or path in PUBLIC_ROOT_ENTRIES or path in PUBLIC_DOCS
            or path in PUBLIC_CONFIG or path.startswith(PREFIXES) or path.startswith(".github/"))


def runtime_text(path):
    return (path.startswith(("Sources/", "Scripts/", "scripts/", "Plugins/", "packaging/",
                             ".agents/", "Automation/prompts/"))
            and not path.startswith(("Sources/TravelUI/Resources/", "Scripts/tests/")))


def source_entries(source):
    actual_root = Path(os.fsdecode(git(source, "rev-parse", "--show-toplevel")).strip()).resolve()
    if actual_root != source:
        raise ValueError("--source must name the exact Git project root")
    violations = check_repository(source)
    if violations:
        codes = ", ".join(sorted({violation.code for violation in violations}))
        raise ValueError(f"repository preflight refused the public source export: {codes}")
    if git(source, "status", "--porcelain", "--untracked-files=all").strip():
        raise ValueError("source has uncommitted or untracked changes; review and commit first")
    revision = git(source, "rev-parse", "HEAD").decode("ascii").strip()
    entries = []
    for record in git(source, "ls-tree", "-rz", "--full-tree", revision).split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, kind, blob = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8")
        if path.startswith("scripts/"):
            raise ValueError("normalize lowercase scripts directory to Scripts before export")
        if not selected(path):
            continue
        parts = PurePosixPath(path).parts
        if (path.startswith("/") or ".." in parts or "\\" in path or ":" in path
                or any(ord(c) < 32 for c in path)):
            raise ValueError("unsafe archive member name")
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise ValueError(f"nonregular source entry is not distributable: {path}")
        contents = git(source, "cat-file", "blob", blob)
        author_home_prefix = b"/" + b"Users" + b"/"
        if runtime_text(path) and author_home_prefix in contents:
            raise ValueError(f"personal runtime path must be removed before export: {path}")
        entries.append((path, int(mode, 8), contents))
    missing = REQUIRED - {path for path, _, _ in entries}
    if missing:
        raise ValueError("required source missing: " + ", ".join(sorted(missing)))
    return sorted(entries)


def export(source, output):
    source = source.resolve(strict=True)
    output = output.parent.resolve(strict=True) / output.name
    if output.suffix != ".zip" or output.is_relative_to(source):
        raise ValueError("output must be a .zip outside the source project")
    checksum = Path(str(output) + ".sha256")
    if any(p.exists() or p.is_symlink() for p in (output, checksum)):
        raise ValueError("output or checksum already exists; refusing to overwrite")
    entries = source_entries(source)
    created = []
    try:
        # Exclusive creation also protects against a file appearing after preflight.
        with output.open("xb") as stream:
            created.append(output)
            with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for path, mode, contents in entries:
                    info = zipfile.ZipInfo("TravelCat/" + path, date_time=(1980, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    info.external_attr = mode << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, contents)
            stream.flush()
            os.fsync(stream.fileno())
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        with checksum.open("x", encoding="utf-8") as stream:
            created.append(checksum)
            stream.write(f"{digest}  {output.name}\n")
            stream.flush()
            os.fsync(stream.fileno())
    except Exception:
        for path in reversed(created):
            path.unlink()
        raise
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        print(export(args.source, args.output))
    except (ValueError, OSError, subprocess.CalledProcessError, UnicodeError) as error:
        print(f"source-export: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
