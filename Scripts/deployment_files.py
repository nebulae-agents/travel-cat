"""Owned deployment staging, identity checks, private lock and receipts."""
from contextlib import AbstractContextManager
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import sys
import uuid

from deploy_config import _open_directory, _pairs, _private_mode


def identity(path):
    info = Path(path).lstat()
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError("Expected a real directory: " + str(path))
    return info.st_dev, info.st_ino


def safe_directory(path, create=False):
    path = Path(path)
    if create:
        if not path.exists():
            safe_directory(path.parent, create=True)
            path.mkdir(mode=0o700)
    descriptor = _open_directory(path)
    os.close(descriptor)
    return identity(path)


def file_bytes(path, limit=None):
    descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Expected a regular file with one link: " + str(path))
        if limit is not None and info.st_size > limit:
            raise ValueError("File is too large: " + str(path))
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            value = stream.read() if limit is None else stream.read(limit + 1)
        if limit is not None and len(value) > limit:
            raise ValueError("File is too large")
        after = os.fstat(descriptor)
        if (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError("File changed during read")
        return value
    finally:
        os.close(descriptor)


def tree_digest(root):
    """Hash sorted relative names, types, modes and bytes; reject links/specials."""
    root = Path(root)
    safe_directory(root)
    result = hashlib.sha256()
    for path in [root] + sorted(root.rglob("*")):
        info = path.lstat()
        name = path.relative_to(root).as_posix()
        if stat.S_ISDIR(info.st_mode):
            kind, payload = "d", b""
        elif stat.S_ISREG(info.st_mode):
            kind, payload = "f", file_bytes(path)
        else:
            raise ValueError("Tree contains a link or special file: " + str(path))
        result.update(json.dumps([name, kind, stat.S_IMODE(info.st_mode), len(payload)], separators=(",", ":")).encode())
        result.update(b"\0" + payload + b"\0")
    return result.hexdigest()


def copy_tree(source, target, copier=None):
    expected = tree_digest(source)
    if target.exists() or target.is_symlink():
        raise ValueError("Copy destination already exists")
    if copier is None:
        shutil.copytree(source, target, copy_function=shutil.copy2)
    else:
        copier(source, target)
    if tree_digest(target) != expected:
        raise ValueError("Backup/staging digest mismatch")
    return expected


def exclusive_rename(source, target):
    """Rename a directory without replacing any concurrent destination entry."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        function = library.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        result = function(os.fsencode(source), os.fsencode(target), 0x00000004)  # RENAME_EXCL
    elif sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        function = library.renameat2
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        result = function(-100, os.fsencode(source), -100, os.fsencode(target), 1)  # RENAME_NOREPLACE
    else:
        raise OSError(errno.ENOTSUP, "Exclusive directory rename is unavailable")
    if result:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(target))


class OwnedDirectory:
    def __init__(self, parent=None, prefix="travel-cat-deployment-"):
        if parent is not None:
            safe_directory(parent)
        self.path = Path(tempfile.mkdtemp(prefix=prefix, dir=parent)).resolve()
        self.owner = identity(self.path)
        self.parent_owner = identity(self.path.parent)

    def check(self):
        safe_directory(self.path.parent)
        if identity(self.path.parent) != self.parent_owner or identity(self.path) != self.owner:
            raise ValueError("Owned temporary directory identity changed; preserving contents")

    def cleanup(self):
        self.check()
        if not shutil.rmtree.avoids_symlink_attacks:
            raise ValueError("Owned cleanup requires descriptor-safe directory removal")

        def retry_readonly_directory(function, failed_path, exception):
            error = exception[1]
            if not isinstance(error, PermissionError) or function not in (os.unlink, os.rmdir):
                raise error
            failed = Path(failed_path)
            try:
                relative_parent = failed.parent.relative_to(self.path)
            except ValueError:
                # Never chmod the external parent when removal of our root fails.
                raise error
            self.check()
            descriptor = os.open(str(self.path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                info = os.fstat(descriptor)
                if (info.st_dev, info.st_ino) != self.owner:
                    raise ValueError("Owned cleanup root changed; preserving contents")
                for component in relative_parent.parts:
                    following = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                        dir_fd=descriptor)
                    os.close(descriptor)
                    descriptor = following
                info = os.fstat(descriptor)
                mode = stat.S_IMODE(info.st_mode)
                if (info.st_uid != os.getuid() or info.st_dev != self.owner[0]
                        or mode & stat.S_IWUSR):
                    raise error
                self.check()
                # Pinned build directories intentionally remain 0555 until this
                # owned cleanup. Unlink needs write on their parent, not the file.
                os.fchmod(descriptor, mode | stat.S_IWUSR)
                function(failed.name, dir_fd=descriptor)
            finally:
                os.close(descriptor)

        shutil.rmtree(self.path, onerror=retry_readonly_directory)


class DeploymentLock(AbstractContextManager):
    """Stable inode lock. Never unlink the lock file, including on release."""
    def __init__(self, local):
        self.local = Path(local)
        self.directory_fd = self.fd = None

    def __enter__(self):
        try:
            self.directory_fd = _open_directory(self.local)
            _private_mode(os.fstat(self.directory_fd), directory=True)
            self.owner = identity(self.local)
            self.fd = os.open("deployment.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                              0o600, dir_fd=self.directory_fd)
            info = os.fstat(self.fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ValueError("Unsafe deployment lock")
            _private_mode(info)
            self.file_owner = (info.st_dev, info.st_ino)
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ValueError("另一个部署正在运行（deployment lock）。") from error
            self.check()
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def check(self):
        if identity(self.local) != self.owner:
            raise ValueError("Private deployment directory changed")
        info = os.stat("deployment.lock", dir_fd=self.directory_fd, follow_symlinks=False)
        if (info.st_dev, info.st_ino) != self.file_owner:
            raise ValueError("Deployment lock identity changed")

    def __exit__(self, *args):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        if self.directory_fd is not None:
            os.close(self.directory_fd)
            self.directory_fd = None


def fingerprint(config):
    return hashlib.sha256(json.dumps(config, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


RECEIPT_KEYS = {"schemaVersion", "runID", "sourceRevision", "configFingerprint", "targets", "appDigest",
                "petDigest", "petAction", "petExtras", "plugin", "status", "backupDirectory", "stages",
                "error", "recoveryErrors"}
STAGES = {"prepared", "app-published", "pet-published", "verified", "launched"}
APP_RECEIPT_KEYS = RECEIPT_KEYS - {"petDigest", "petAction", "petExtras", "plugin"}


def legacy_receipt_config(local, receipt, config):
    """Recover old target binding from a private exact-fingerprint backup only."""
    if config["schemaVersion"] == 1:
        return config
    backups = sorted(local.glob("deploy.json.backup-*"))
    if len(backups) > 256:
        raise ValueError("Too many legacy configuration backups; receipt needs recovery review")
    for path in backups:
        _private_mode(path.lstat())
        value = json.loads(file_bytes(path, 65536), object_pairs_hook=_pairs)
        if (not isinstance(value, dict) or type(value.get("schemaVersion")) is not int
                or value["schemaVersion"] != 1):
            continue
        if (set(value) != {"schemaVersion", "applicationDirectory", "codexHome", "dataRoot"}
                or any(not isinstance(value[key], str) or not value[key].startswith("/")
                       or value[key].startswith("//") or ".." in value[key].split("/")
                       or any(ord(char) < 32 for char in value[key])
                       for key in ("applicationDirectory", "codexHome", "dataRoot"))):
            raise ValueError("Invalid legacy configuration backup for receipt")
        if (fingerprint(value) == receipt.get("configFingerprint")
                and value["applicationDirectory"] == config["applicationDirectory"]):
            return value
    raise ValueError("Legacy receipt needs recovery review: matching v1 config backup is missing")


def read_receipt(local, config):
    path = local / "deployment-receipt.json"
    if not path.exists() and not path.is_symlink():
        return None
    info = path.lstat()
    _private_mode(info)
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate receipt key")
            result[key] = value
        return result
    try:
        receipt = json.loads(file_bytes(path, 65536), object_pairs_hook=pairs)
        if (not isinstance(receipt, dict) or type(receipt.get("schemaVersion")) is not int
                or receipt["schemaVersion"] not in (1, 2)):
            raise ValueError("Unsupported deployment receipt schema")
        legacy = receipt["schemaVersion"] == 1
        expected = {"app": str(Path(config["applicationDirectory"]) / "Travel Cat.app")}
        if legacy:
            old_config = legacy_receipt_config(local, receipt, config)
            expected["pet"] = str(Path(old_config["codexHome"]) / "pets/cute-black-cat")
        valid = (set(receipt) == (RECEIPT_KEYS if legacy else APP_RECEIPT_KEYS)
                 and receipt["targets"] == expected
                 and isinstance(receipt["configFingerprint"], str) and re.fullmatch("[0-9a-f]{64}", receipt["configFingerprint"])
                 and isinstance(receipt["runID"], str) and re.fullmatch("[0-9a-f]{32}", receipt["runID"])
                 and isinstance(receipt["sourceRevision"], str) and re.fullmatch("[0-9a-f]{40,64}", receipt["sourceRevision"])
                 and all(isinstance(receipt[key], str) and re.fullmatch("[0-9a-f]{64}", receipt[key]) for key in (("appDigest", "petDigest") if legacy else ("appDigest",)))
                 and receipt["backupDirectory"] == str(local / ("deployment-" + receipt["runID"]))
                 and receipt["status"] in ("prepared", "complete", "rolled-back", "recovery-failed")
                 and isinstance(receipt["error"], str)
                 and isinstance(receipt["recoveryErrors"], list) and all(isinstance(value, str) for value in receipt["recoveryErrors"])
                 and isinstance(receipt["stages"], list) and all(isinstance(value, str) and value in (STAGES if legacy else STAGES - {"pet-published"}) for value in receipt["stages"]))
        if valid and legacy:
            valid = (receipt["petAction"] in ("unchanged", "install", "replace")
                     and isinstance(receipt["plugin"], dict) and set(receipt["plugin"]) == {"sourceVersion", "refreshed"}
                     and isinstance(receipt["plugin"]["sourceVersion"], str) and receipt["plugin"]["refreshed"] is False
                     and isinstance(receipt["petExtras"], list) and all(isinstance(value, str) and "/" not in value and value not in ("", ".", "..") for value in receipt["petExtras"]))
        if not valid:
            raise ValueError("Untrusted deployment receipt shape or target/config binding")
        if receipt["status"] == "complete":
            completed = ["prepared", "app-published"]
            if legacy and receipt["petAction"] != "unchanged":
                completed.append("pet-published")
            completed.extend(["verified", "launched"])
            if receipt["stages"] != completed or receipt["error"] or receipt["recoveryErrors"]:
                raise ValueError("Contradictory complete deployment receipt")
        if receipt["status"] in ("prepared", "recovery-failed"):
            raise ValueError("Previous deployment receipt needs recovery review before deploying again")
        if receipt["configFingerprint"] != fingerprint(config):
            # A config change cannot inherit old installation authority.
            # Exact target paths and recovery blockers still apply.
            return None
        return receipt
    except (TypeError, KeyError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("Invalid deployment receipt") from error


def _write_receipt_at(directory_fd, destination, receipt, lock):
    lock.check()
    payload = (json.dumps(receipt, ensure_ascii=True, indent=2) + "\n").encode()
    if len(payload) > 65536:
        raise ValueError("Deployment receipt exceeds private size limit")
    name = ".receipt-" + uuid.uuid4().hex
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
    committed = False
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        lock.check()
        os.fsync(directory_fd)
        # Replacement is the commit point; no fallible filesystem operation
        # follows it. A reported write failure never grants new active authority.
        os.replace(name, destination, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        committed = True
    finally:
        if not committed:
            try:
                os.unlink(name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass


def write_receipt(local, receipt, lock):
    _write_receipt_at(lock.directory_fd, "deployment-receipt.json", receipt, lock)


def archive_receipt(local, receipt, lock):
    """Retain this failed attempt separately before restoring active authority."""
    run_id = receipt["runID"]
    if not isinstance(run_id, str) or not re.fullmatch("[0-9a-f]{32}", run_id):
        raise ValueError("Invalid failed receipt run identifier")
    directory = local / ("deployment-" + run_id)
    if receipt["backupDirectory"] != str(directory):
        raise ValueError("Failed receipt backup binding changed")
    descriptor = _open_directory(directory)
    try:
        _private_mode(os.fstat(descriptor), directory=True)
        _write_receipt_at(descriptor, "receipt.json", receipt, lock)
    finally:
        os.close(descriptor)


class Publication:
    """One target's staged rename, with exact identities for compensating undo."""
    def __init__(self, label, target, candidate, backup, expected_digest, copier=None):
        self.label, self.target = label, Path(target)
        safe_directory(self.target.parent, create=True)
        self.stage = OwnedDirectory(self.target.parent, prefix=".travel-cat-stage-")
        self.candidate = self.stage.path / "candidate"
        self.displaced = self.stage.path / "displaced"
        self.old_digest = expected_digest
        self.old_owner = identity(target) if expected_digest is not None else None
        self.published = self.moved_old = False
        try:
            copy_tree(candidate, self.candidate, copier)
            self.new_owner = identity(self.candidate)
            self.new_digest = tree_digest(self.candidate)
            if expected_digest is not None:
                if tree_digest(target) != expected_digest:
                    raise ValueError("Existing target changed before backup")
                if copy_tree(target, backup, copier) != expected_digest:
                    raise ValueError("Existing target changed during backup")
        except BaseException:
            self.stage.cleanup()
            raise

    def check_old(self):
        self.stage.check()
        if self.old_owner is None:
            if self.target.exists() or self.target.is_symlink():
                raise ValueError("New target appeared before publication")
        elif identity(self.target) != self.old_owner or tree_digest(self.target) != self.old_digest:
            raise ValueError("Existing target changed before publication")

    def publish(self):
        self.check_old()
        if self.old_owner is not None:
            exclusive_rename(self.target, self.displaced)
            self.moved_old = True
        # Never replace an unexpected entry appearing between the checks.
        if self.target.exists() or self.target.is_symlink():
            raise ValueError("Target appeared during publication")
        exclusive_rename(self.candidate, self.target)
        self.published = True

    def rollback(self):
        self.stage.check()
        if self.published:
            if identity(self.target) != self.new_owner or tree_digest(self.target) != self.new_digest:
                raise ValueError("Published target changed; recovery preserved it for review")
            exclusive_rename(self.target, self.candidate)
            self.published = False
        if self.moved_old:
            if self.target.exists() or self.target.is_symlink():
                raise ValueError("Recovery destination is occupied")
            if identity(self.displaced) != self.old_owner or tree_digest(self.displaced) != self.old_digest:
                raise ValueError("Displaced original changed; recovery preserved it")
            exclusive_rename(self.displaced, self.target)
            self.moved_old = False

    def cleanup(self):
        self.stage.cleanup()
