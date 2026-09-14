#!/usr/bin/env python3
"""Build a verified Travel Cat development candidate from an exported clean HEAD."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


PET_FILES = {
    "pet.json": "Sources/TravelUI/Resources/pet.json",
    "spritesheet.webp": "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp",
}
REQUIRED_CANDIDATE = (
    "Travel Cat.app/Contents/Info.plist", "README.md", "LICENSE", "NOTICE",
    "THIRD_PARTY_NOTICES.md", "OFL.txt", "INSTALLATION.md",
    "Travel Cat.app/Contents/Helpers/travelcatctl",
    "Travel Cat.app/Contents/Resources/travelcatctl-release.provenance",
)
REQUIRED_SOURCE = (
    "Package.swift", "README.md", "Scripts/package-app.sh",
    "Sources/TravelUI/Resources/pet.json",
    "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp",
)


def run(arguments, *, cwd=None, env=None, capture=False, timeout=1800):
    return subprocess.run(arguments, cwd=cwd, env=env, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None, timeout=timeout)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_environment(parent, scratch):
    environment = {key: value for key, value in parent.items() if not key.startswith("TRAVEL_CAT_")}
    environment["TRAVEL_CAT_SCRATCH_ROOT"] = str(scratch)
    return environment


def reserve_output(repo, output):
    if not output.is_absolute():
        raise ValueError("output directory must be absolute")
    repo = repo.resolve(strict=True)
    parent = output.parent.resolve(strict=True)
    output = parent / output.name
    if output == repo or output.is_relative_to(repo):
        raise ValueError("output directory must be outside the repository")
    if output.exists() or output.is_symlink():
        raise ValueError("output directory already exists; refusing to overwrite")
    output.mkdir(mode=0o755)
    return output


def safe_extract(archive_path, destination):
    if destination.exists() or destination.is_symlink():
        raise ValueError("extraction destination must be new")
    destination.mkdir(mode=0o755)
    seen = set()
    try:
        with zipfile.ZipFile(archive_path) as archive:
            for info in archive.infolist():
                name = info.filename
                pure = PurePosixPath(name)
                normalized = pure.as_posix()
                if (not name or name.startswith("/") or "\\" in name or ":" in name
                        or ".." in pure.parts or normalized in seen
                        or any(ord(character) < 32 for character in name)):
                    raise ValueError(f"unsafe or duplicate archive member: {name}")
                seen.add(normalized)
                mode = info.external_attr >> 16
                kind = stat.S_IFMT(mode)
                if info.is_dir():
                    if kind not in (0, stat.S_IFDIR):
                        raise ValueError(f"unsafe directory member: {name}")
                    (destination / pure).mkdir(parents=True, exist_ok=True)
                    continue
                if kind != stat.S_IFREG or stat.S_IMODE(mode) not in (0o444, 0o555, 0o644, 0o755):
                    raise ValueError(f"archive member has an unsafe type or mode: {name}")
                target = destination.joinpath(*pure.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(stat.S_IMODE(mode))
    except Exception:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    return destination


def reject_links_and_unsafe_modes(root):
    for base, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(base) / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise ValueError(f"candidate contains symbolic link: {path.relative_to(root)}")
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError(f"candidate contains nonregular entry: {path.relative_to(root)}")
            if stat.S_ISREG(mode) and stat.S_IMODE(mode) not in (0o644, 0o755, 0o444, 0o555):
                raise ValueError(f"candidate has unsafe mode: {path.relative_to(root)}")


def verify_extracted_source(source):
    reject_links_and_unsafe_modes(source)
    missing = [name for name in REQUIRED_SOURCE if not (source / name).is_file()]
    if missing:
        raise ValueError("extracted source missing required members: " + ", ".join(missing))
    for path in source.rglob("*"):
        relative = path.relative_to(source)
        if ".git" in relative.parts or relative.parts[:1] == ("TravelPetData",) \
                or relative.parts[:2] == ("docs", "verification"):
            raise ValueError(f"private or runtime path escaped source export: {relative}")
        relative_text = relative.as_posix()
        fixture_or_resource = relative_text.startswith((
            "Sources/TravelUI/Resources/", "Scripts/tests/", "Tests/", "Fixtures/", "Assets/"))
        if (path.is_file() and not fixture_or_resource
                and path.suffix.lower() in {".md", ".py", ".sh", ".swift", ".json", ".plist"}):
            author_prefix = b"/" + b"Users" + b"/"
            if author_prefix in path.read_bytes():
                raise ValueError(f"author runtime path escaped source export: {relative}")


def verify_candidate_layout(source, candidate):
    reject_links_and_unsafe_modes(candidate)
    missing = [name for name in REQUIRED_CANDIDATE if not (candidate / name).is_file()]
    if missing:
        raise ValueError("candidate missing required members: " + ", ".join(missing))
    for legacy in ("Plugins", "Pet", "Install Default Pet.command"):
        if (candidate / legacy).exists():
            raise ValueError("app-only candidate contains legacy component: " + legacy)
    helper = candidate / "Travel Cat.app/Contents/Helpers/travelcatctl"
    if stat.S_IMODE(helper.stat().st_mode) != 0o555:
        raise ValueError("signed helper mode must be exactly 0555")
    for output_name, source_name in PET_FILES.items():
        bundled = candidate / "Travel Cat.app/Contents/Resources/TravelCat_TravelUI.bundle" / Path(source_name).name
        if not bundled.is_file() or bundled.read_bytes() != (source / source_name).read_bytes():
            raise ValueError(f"bundled default pet bytes changed: {output_name}")


def write_zip(source, output, prefix):
    if output.exists() or output.is_symlink():
        raise ValueError("archive already exists; refusing to overwrite")
    reject_links_and_unsafe_modes(source)
    with output.open("xb") as stream, zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(p for p in source.rglob("*") if p.is_file()):
            relative = path.relative_to(source).as_posix()
            mode = stat.S_IMODE(path.stat().st_mode)
            info = zipfile.ZipInfo(f"{prefix}/{relative}", (1980, 1, 1, 0, 0, 0))
            info.create_system = 3; info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
    return output


def write_checksum(path):
    sidecar = Path(str(path) + ".sha256")
    with sidecar.open("x", encoding="utf-8") as output:
        output.write(f"{digest(path)}  {path.name}\n")


def verify_checksum(path):
    sidecar = Path(str(path) + ".sha256")
    if not sidecar.is_file() or sidecar.is_symlink():
        raise ValueError("source checksum sidecar is missing or unsafe")
    expected = f"{digest(path)}  {path.name}\n"
    if sidecar.read_text(encoding="utf-8") != expected:
        raise ValueError("source checksum sidecar does not match archive digest and filename")


def verify_app(app):
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    with (app / "Contents/Info.plist").open("rb") as stream:
        plist = plistlib.load(stream)
    if plist.get("CFBundleIdentifier") != "com.nebulae.travelcat":
        raise ValueError("candidate app bundle identifier is invalid")
    if "TravelCatDataRoot" in plist:
        raise ValueError("distributable app contains a data-root override")
    executable = app / "Contents/MacOS/TravelCatApp"
    architecture = run(["/usr/bin/lipo", "-archs", str(executable)], capture=True, timeout=60).stdout.strip()
    if not architecture or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ " for character in architecture):
        raise ValueError("candidate executable architecture is invalid")
    return architecture


def assemble(repo, output):
    output = reserve_output(repo, output)
    try:
        run([str(repo / "Scripts/audit-project-upload.sh")], cwd=repo)
        revision = run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture=True).stdout.strip()
        source_zip = output / "TravelCat-Source.zip"
        run([sys.executable, str(repo / "Scripts/export-source.py"), "--source", str(repo), str(source_zip)])
        verify_checksum(source_zip)
        with tempfile.TemporaryDirectory(prefix="Travel Cat candidate build ") as temp_name:
            temporary = Path(temp_name).resolve()
            extracted = safe_extract(source_zip, temporary / "Extracted Source with spaces") / "TravelCat"
            verify_extracted_source(extracted)
            scratch = temporary / "External Swift Scratch with spaces"
            env = build_environment(os.environ, scratch)
            run([str(extracted / "Scripts/travel-cat-swift.sh"), "test"], cwd=extracted, env=env)
            run([str(extracted / "Scripts/package-app.sh")], cwd=extracted, env=env)
            app = extracted / "dist/Travel Cat.app"
            architecture = verify_app(app)
            candidate = temporary / "TravelCat-Candidate"; candidate.mkdir()
            shutil.copytree(app, candidate / "Travel Cat.app")
            for name in ("LICENSE", "NOTICE"):
                shutil.copy2(extracted / name, candidate / name)
            notices = extracted / "Sources/TravelUI/Resources/Fonts/THIRD_PARTY_NOTICES.md"
            shutil.copy2(notices, candidate / "THIRD_PARTY_NOTICES.md")
            shutil.copy2(extracted / "Sources/TravelUI/Resources/Fonts/OFL.txt", candidate / "OFL.txt")
            shutil.copy2(extracted / "docs/installation.md", candidate / "INSTALLATION.md")
            template = (extracted / "packaging/CANDIDATE_README.md").read_text(encoding="utf-8")
            (candidate / "README.md").write_text(template.format(source_commit=revision, architecture=architecture), encoding="utf-8")
            verify_candidate_layout(extracted, candidate)
            candidate_zip = write_zip(candidate, output / "TravelCat-Candidate.zip", "TravelCat-Candidate")
            reextracted = safe_extract(candidate_zip, temporary / "Re-extracted Candidate with spaces") / "TravelCat-Candidate"
            verify_candidate_layout(extracted, reextracted); verify_app(reextracted / "Travel Cat.app")
            write_checksum(candidate_zip)
            report = {
                "sourceCommit": revision, "architecture": architecture,
                "sourceSHA256": digest(source_zip), "candidateSHA256": digest(candidate_zip),
                "signature": "ad-hoc; verified after candidate ZIP re-extraction",
                "verified": ["extracted-source full tests", "bundle signature and identifier", "resource bytes", "app-only layout"],
                "notVerified": ["notarization", "visible native UI", "cross-account installation", "public release"],
            }
            (output / "verification-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return output
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        print(assemble(args.source.resolve(strict=True), args.output))
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        print(f"candidate-package: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
