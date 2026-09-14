"""macOS app-only build, signature and exact-app process boundary."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time

from deployment_files import file_bytes, tree_digest

PET_FILES = {"pet.json": "Sources/TravelUI/Resources/pet.json",
             "spritesheet.webp": "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"}
APP_ID = "com.nebulae.travelcat"


def build_environment(parent, scratch):
    environment = {key: value for key, value in parent.items() if not key.startswith("TRAVEL_CAT_")}
    environment["TRAVEL_CAT_SCRATCH_ROOT"] = str(scratch)
    return environment


def source_digest(repository):
    paths = [repository / "Package.swift"]
    for component in ("TravelCore", "TravelStorage", "TravelCatCLI"):
        root = repository / "Sources" / component
        tree_digest(root)
        paths.extend(path for path in root.rglob("*") if path.is_file())
    manifest = b""
    for path in sorted(paths, key=lambda value: value.relative_to(repository).as_posix().encode()):
        name = path.relative_to(repository).as_posix()
        manifest += hashlib.sha256(file_bytes(path)).hexdigest().encode() + b"  " + name.encode() + b"\n"
    return hashlib.sha256(manifest).hexdigest()


def pet_digest(root, mapping=None):
    result = hashlib.sha256()
    for name, relative in sorted((mapping or {name: name for name in PET_FILES}).items()):
        payload = file_bytes(root / relative)
        result.update(name.encode() + b"\0" + hashlib.sha256(payload).digest())
    return result.hexdigest()


def import_script(path, name):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class Runtime:
    def run(self, arguments, *, cwd=None, env=None, log=None, timeout=1800):
        result = subprocess.run([str(value) for value in arguments], cwd=cwd, env=env, check=True,
                                stdout=log if log is not None else subprocess.PIPE,
                                stderr=log if log is not None else subprocess.STDOUT,
                                timeout=timeout)
        return result.stdout.decode("utf-8", errors="replace") if log is None else ""

    def check_tools(self):
        if sys.platform != "darwin":
            raise ValueError("本机部署需要 macOS。")
        missing = [name for name in ("git", "python3", "xcrun", "swift", "codesign", "ditto", "open", "osascript", "zsh")
                   if shutil.which(name) is None]
        if missing:
            raise ValueError("缺少部署工具：" + ", ".join(missing))
        self.run(["xcrun", "--find", "swift"], timeout=30)

    def audit(self, repository):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TRAVEL_CAT_")}
        self.run([repository / "Scripts/audit-project-upload.sh"], cwd=repository, env=environment, timeout=120)

    def verify_signature(self, app):
        self.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], timeout=60)
        signing = self.run(["/usr/bin/codesign", "-d", "--verbose=4", app], timeout=60)
        if re.findall(r"^Identifier=(.*)$", signing, re.MULTILINE) != [APP_ID]:
            raise ValueError("App signing identifier is invalid")

    def inspect_app(self, app):
        tree_digest(app)
        info = plistlib.loads(file_bytes(app / "Contents/Info.plist", 1024 * 1024))
        if info.get("CFBundleIdentifier") != APP_ID:
            raise ValueError("Existing app bundle identifier is invalid")
        self.verify_signature(app)
        root = info.get("TravelCatDataRoot")
        if root is not None and (not isinstance(root, str) or not root.startswith("/") or ".." in Path(root).parts):
            raise ValueError("Existing app album path is invalid")
        return info

    def legacy_data_root(self, home):
        roots = []
        for parent in (home / "Applications", Path("/Applications")):
            app = parent / "Travel Cat.app"
            if app.exists() or app.is_symlink():
                root = self.inspect_app(app).get("TravelCatDataRoot")
                if root:
                    roots.append(root)
        if len(set(roots)) > 1:
            raise ValueError("多个已安装应用使用不同相册，请先明确保留的安装。")
        return roots[0] if roots else None

    def verify_app(self, app, repository, revision, config):
        info = self.inspect_app(app)
        if info.get("TravelCatSourceRevision") != revision:
            raise ValueError("Built app source revision mismatch")
        if info.get("TravelCatDataRoot") != config["dataRoot"]:
            raise ValueError("Built app album path mismatch")
        resources = app / "Contents/Resources/TravelCat_TravelUI.bundle"
        for source in PET_FILES.values():
            if file_bytes(resources / Path(source).name) != file_bytes(repository / source):
                raise ValueError("Built app bundled pet asset mismatch")
        helper = app / "Contents/Helpers/travelcatctl"
        if stat.S_IMODE(helper.lstat().st_mode) != 0o555:
            raise ValueError("Built app helper mode mismatch")
        binary = hashlib.sha256(file_bytes(helper)).hexdigest()
        expected = "\n".join(["format=travel-cat-cli-provenance-v3", "product=travelcatctl", "configuration=release",
                              "sourceTreeSHA256=" + source_digest(repository), "binarySHA256=" + binary,
                              "binaryArtifactID=" + binary + "/travelcatctl"]) + "\n"
        if file_bytes(app / "Contents/Resources/travelcatctl-release.provenance", 4096) != expected.encode():
            raise ValueError("Built app helper provenance mismatch")

    def build(self, repository, revision, config, workspace, log):
        exporter = import_script(repository / "Scripts/export-source.py", "travel_deployment_export")
        package = import_script(repository / "Scripts/package-project.py", "travel_deployment_package")
        archive = exporter.export(repository, workspace / "source.zip")
        package.safe_extract(archive, workspace / "extracted")
        source = workspace / "extracted/TravelCat"
        package.verify_extracted_source(source)
        environment = package.build_environment(os.environ, workspace / "swift-scratch")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        self.run([source / "Scripts/package-app.sh", "--data-root", config["dataRoot"]],
                 cwd=source, env=environment, log=log)
        app = source / "dist/Travel Cat.app"
        helper = app / "Contents/Helpers/travelcatctl"
        before = hashlib.sha256(file_bytes(helper)).hexdigest()
        path = app / "Contents/Info.plist"
        info = plistlib.loads(file_bytes(path))
        info["TravelCatSourceRevision"] = revision
        with path.open("wb") as stream:
            plistlib.dump(info, stream)
        # Only the outer bundle is re-signed. Re-signing nested helper code
        # would invalidate its recorded binary SHA-256.
        self.run(["/usr/bin/codesign", "--force", "--sign", "-", app], log=log, timeout=60)
        if hashlib.sha256(file_bytes(helper)).hexdigest() != before:
            raise ValueError("Outer signing changed helper bytes")
        self.verify_app(app, repository, revision, config)
        return app

    def copy_tree(self, source, target):
        self.run(["/usr/bin/ditto", "--rsrc", "--extattr", source, target], timeout=120)

    def is_running(self, app):
        return bool(self.processes(app))

    def processes(self, app):
        script = '''ObjC.import('AppKit'); function run(argv) {
          var all = $.NSWorkspace.sharedWorkspace.runningApplications, found = [];
          for (var i = 0; i < all.count; i++) {
            var a = all.objectAtIndex(i);
            if (a.bundleURL && ObjC.unwrap(a.bundleURL.path) === argv[0]) found.push(Number(a.processIdentifier));
          } return JSON.stringify(found);
        }'''
        value = json.loads(self.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(app)], timeout=20))
        if not isinstance(value, list) or any(type(pid) is not int or pid <= 0 for pid in value):
            raise ValueError("Cannot identify exact application processes")
        return value

    def stop(self, app):
        pids = self.processes(app)
        if not pids:
            return False
        script = '''ObjC.import('AppKit'); function run(argv) {
          var pids = JSON.parse(argv[1]);
          for (var i = 0; i < pids.length; i++) {
            var a = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pids[i]);
            if (a && a.bundleURL && ObjC.unwrap(a.bundleURL.path) === argv[0]) {
              if (!a.terminate) throw Error('Graceful termination refused');
            }
          } return 'requested';
        }'''
        self.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(app), json.dumps(pids)], timeout=20)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if not self.processes(app):
                return True
            time.sleep(0.25)
        raise ValueError("应用未在时限内退出；未替换文件。")

    def launch(self, app):
        self.run(["/usr/bin/open", "-n", str(app)], timeout=30)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            pids = self.processes(app)
            if pids:
                time.sleep(1)
                if set(pids) & set(self.processes(app)):
                    return
            time.sleep(0.25)
        raise ValueError("新应用未成功启动并保持运行。")
