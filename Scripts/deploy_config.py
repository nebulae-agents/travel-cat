"""Private local configuration. Standard library only; never executes values.

All public APIs accept keyword-only repository and optional home (Path.home by
default). validate_config expands suggestions; load_config requires absolute
stored paths. choose_config returns the chosen validated dictionary or raises
ConfigCancelled / ConfigError. No API reads or changes album contents.
"""

import json
import os
from pathlib import Path
import stat
import unicodedata
import uuid


MAX_BYTES = 64 * 1024
DEFAULTS = {"schemaVersion": 2, "applicationDirectory": "~/Applications",
            "dataRoot": "~/Library/Application Support/TravelCat/TravelPetData"}
PATH_KEYS = ("applicationDirectory", "dataRoot")
_UNSET = object()


class ConfigError(ValueError):
    """Configuration is invalid or could not be safely saved."""


class ConfigCancelled(Exception):
    """Normal user cancellation; deployment must stop without demo fallback."""


def _comparison_parts(path):
    return tuple(unicodedata.normalize("NFD", part).casefold() for part in path.parts)


def _path(value, home=None):
    if not isinstance(value, (str, Path)):
        raise ConfigError("Paths must be strings.")
    value = str(value)
    if not value or any(ord(character) < 32 for character in value):
        raise ConfigError("Paths must be nonempty and contain no control characters.")
    if value.startswith("~/") and home is not None:
        value = str(home) + value[1:]
    if not value.startswith("/") or value.startswith("//") or ".." in value.split("/"):
        raise ConfigError("Use an absolute path or a ~/ suggestion, without traversal or doubled leading separators.")
    # These two system aliases are the only symlinks accepted. Validate the
    # actual link target before translating it, then inspect every component.
    result = Path(value)
    if _comparison_parts(result)[:4] == ("/", "system", "volumes", "data"):
        raise ConfigError("不支持 /System/Volumes/Data 卷别名，请填写对应的普通绝对路径。")
    for alias, destination in ((Path("/tmp"), Path("/private/tmp")),
                               (Path("/var"), Path("/private/var"))):
        if result == alias or alias in result.parents:
            if alias.is_symlink():
                target = os.readlink(str(alias))
                if target not in (str(destination), str(destination).lstrip("/")):
                    raise ConfigError("Unexpected system path alias.")
                result = destination / result.relative_to(alias)
    current = Path(result.anchor)
    try:
        for part in result.parts[1:]:
            current = current / part
            try:
                info = current.lstat()
            except FileNotFoundError:
                continue
            if not stat.S_ISDIR(info.st_mode):
                raise ConfigError("Directory paths cannot contain symlinks or files.")
    except (OSError, UnicodeError) as error:
        raise ConfigError("Cannot safely inspect a configured directory.") from error
    return result


def _context(repository, home):
    return _path(repository), _path(Path.home() if home is None else home)


def _overlap(first, second):
    # macOS commonly treats case/Unicode variants as the same directory.
    # Compare components conservatively, including nonexistent tails, without
    # creating probes. Equivalent root distinctions are refused on all volumes.
    first_parts = _comparison_parts(first)
    second_parts = _comparison_parts(second)
    prefix_length = min(len(first_parts), len(second_parts))
    return first_parts[:prefix_length] == second_parts[:prefix_length]


def validate_config(config, *, repository, home=None):
    """Validate exact v1/v2 fields and return canonical absolute paths."""
    repository, home = _context(repository, home)
    if (not isinstance(config, dict) or type(config.get("schemaVersion")) is not int
            or config["schemaVersion"] not in (1, 2)):
        raise ConfigError("schemaVersion must be integer 1 or 2.")
    keys = ("applicationDirectory", "codexHome", "dataRoot") if config["schemaVersion"] == 1 else PATH_KEYS
    if set(config) != {"schemaVersion", *keys}:
        raise ConfigError("Configuration must contain exactly the documented fields for its version.")
    paths = {}
    for key in keys:
        if not isinstance(config[key], str):
            raise ConfigError(key + " must be a string.")
        paths[key] = _path(config[key], home)
    applications = (_path(home / "Applications"), _path("/Applications"))
    if paths["applicationDirectory"] not in applications:
        raise ConfigError("applicationDirectory must be ~/Applications or /Applications.")
    scopes = [repository, *applications, paths["dataRoot"]]
    if "codexHome" in paths:
        scopes.append(paths["codexHome"])
    for index, first in enumerate(scopes):
        for second in scopes[index + 1:]:
            if _overlap(first, second):
                raise ConfigError("Code, application directories, Codex and album paths must not overlap.")
    return {"schemaVersion": config["schemaVersion"], **{key: str(paths[key]) for key in keys}}


def _open_directory(path):
    """Open ancestry one component at a time without following symlinks."""
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=descriptor)
            os.close(descriptor)
            descriptor = following
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _private_mode(info, directory=False):
    expected = 0o700 if directory else 0o600
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != expected:
        raise ConfigError("Private configuration needs owner-only permissions (directory 0700, files 0600).")


def _identity(info):
    return info.st_dev, info.st_ino


def _read_state(directory_fd):
    try:
        descriptor = os.open("deploy.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory_fd)
    except FileNotFoundError:
        return None
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ConfigError("Private configuration must be a regular file with exactly one hard link.")
        _private_mode(before)
        if before.st_size > MAX_BYTES:
            raise ConfigError("Configuration exceeds the 64 KiB limit.")
        chunks, size = [], 0
        while size <= MAX_BYTES:
            chunk = os.read(descriptor, min(8192, MAX_BYTES + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        if size > MAX_BYTES:
            raise ConfigError("Configuration exceeds the 64 KiB limit.")
        after = os.fstat(descriptor)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ConfigError("Configuration changed while being read.")
        return (_identity(os.fstat(directory_fd)), _identity(after),
                after.st_mtime_ns, after.st_ctime_ns, b"".join(chunks))
    finally:
        os.close(descriptor)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ConfigError("Duplicate configuration keys are not allowed.")
        result[key] = value
    return result


def _decode(state, repository, home):
    if state is None:
        raise ConfigError("No private configuration exists. Run the interactive wizard first.")
    try:
        config = json.loads(state[-1].decode("utf-8"), object_pairs_hook=_pairs)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise ConfigError("Private configuration is not valid, unambiguous JSON.") from error
    result = validate_config(config, repository=repository, home=home)
    if any(not config[key].startswith("/") for key in result if key != "schemaVersion"):
        raise ConfigError("Private configuration must store expanded absolute paths.")
    return result


def _existing(repository):
    try:
        descriptor = _open_directory(repository / ".local")
    except FileNotFoundError:
        return None
    try:
        _private_mode(os.fstat(descriptor), directory=True)
        return _read_state(descriptor)
    finally:
        os.close(descriptor)


def load_config(*, repository, home=None):
    """Read only .local/deploy.json, bounded and without following symlinks."""
    try:
        repository, home = _context(repository, home)
        return _decode(_existing(repository), repository, home)
    except (OSError, UnicodeError) as error:
        raise ConfigError("Cannot safely read private configuration.") from error


def _write_exclusive(directory_fd, name, contents):
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory_fd)
    completed = False
    try:
        os.fchmod(descriptor, 0o600)
        remaining = memoryview(contents)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError("Incomplete configuration write")
            remaining = remaining[written:]
        os.fsync(descriptor)
        completed = True
    finally:
        os.close(descriptor)
        if not completed:
            os.unlink(name, dir_fd=directory_fd)


def write_config(config, *, repository, home=None, expected_state=_UNSET):
    """Atomically save validated paths, backing up existing exact bytes first.

    expected_state is internal optimistic concurrency state used by the wizard.
    Callers normally omit it. Existing invalid configuration is never replaced.
    """
    descriptor = None
    temporary = ".deploy-" + uuid.uuid4().hex + ".tmp"
    try:
        repository, home = _context(repository, home)
        config = validate_config(config, repository=repository, home=home)
        contents = (json.dumps(config, ensure_ascii=True, indent=2) + "\n").encode("utf-8")
        if len(contents) > MAX_BYTES:
            raise ConfigError("Configuration exceeds the 64 KiB limit.")
        parent_fd = _open_directory(repository)
        try:
            try:
                os.mkdir(".local", 0o700, dir_fd=parent_fd)
            except FileExistsError:
                pass
            descriptor = os.open(".local", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                 dir_fd=parent_fd)
        finally:
            os.close(parent_fd)
        directory_identity = _identity(os.fstat(descriptor))
        _private_mode(os.fstat(descriptor), directory=True)
        previous = _read_state(descriptor)
        if expected_state is not _UNSET and previous != expected_state:
            raise ConfigError("Configuration changed during the wizard; nothing was replaced.")
        if previous is not None:
            _decode(previous, repository, home)
        _write_exclusive(descriptor, temporary, contents)
        if previous is not None:
            backup = "deploy.json.backup-" + uuid.uuid4().hex
            _write_exclusive(descriptor, backup, previous[-1])
        # Persist file contents and the backup directory entry before publishing.
        # The final replace is the commit point: no fallible work follows it.
        os.fsync(descriptor)
        fresh_fd = _open_directory(repository / ".local")
        try:
            if _identity(os.fstat(fresh_fd)) != directory_identity:
                raise ConfigError("Private configuration directory changed; nothing was replaced.")
            _private_mode(os.fstat(fresh_fd), directory=True)
            if _read_state(fresh_fd) != previous:
                raise ConfigError("Configuration changed before save; nothing was replaced.")
            validate_config(config, repository=repository, home=home)
            os.replace(temporary, "deploy.json", src_dir_fd=descriptor, dst_dir_fd=descriptor)
            temporary = None
        finally:
            os.close(fresh_fd)
        return config
    except (OSError, UnicodeError) as error:
        raise ConfigError("Could not safely save configuration; the previous active file was preserved.") from error
    finally:
        if descriptor is not None:
            if temporary is not None:
                try:
                    os.unlink(temporary, dir_fd=descriptor)
                except FileNotFoundError:
                    pass
            os.close(descriptor)


def choose_config(*, repository, home=None, interactive=None, reuse_existing=False,
                  input_fn=input, output_fn=print, suggested_data_root=None):
    """Select/rebuild private config; never silently substitute demo data.

    interactive defaults to stdin.isatty(). Noninteractive callers MUST pass
    reuse_existing=True. suggested_data_root is a caller-verified old album
    suggestion for first creation only. Inputs: blank defaults, yes confirms;
    cancel, EOF or Ctrl-C stop. Existing menu: 1 reuse, 2 regenerate, 3 cancel.
    """
    import sys
    try:
        repository, home = _context(repository, home)
        if interactive is None:
            interactive = sys.stdin.isatty()
        previous = _existing(repository)
        existing = _decode(previous, repository, home) if previous is not None else None
        if not interactive:
            if not reuse_existing or existing is None:
                raise ConfigError("Noninteractive use requires --reuse-existing and a valid private configuration.")
            return existing

        def ask(prompt):
            answer = input_fn(prompt).strip()
            if answer.lower() in ("cancel", "取消"):
                raise ConfigCancelled("已取消配置。")
            return answer

        if existing is not None:
            output_fn("1. 使用现有配置（默认）\n2. 重新生成\n3. 取消")
            selection = ask("请选择 [1]：") or "1"
            if selection == "1":
                # Do not rewrite even formatting or permissions on reuse.
                if _existing(repository) != previous:
                    raise ConfigError("Configuration changed during selection; please retry.")
                return existing
            if selection == "3":
                raise ConfigCancelled("已取消配置。")
            if selection != "2":
                raise ConfigError("请输入 1、2 或 3。")
        defaults = dict(existing or DEFAULTS)
        if existing is None and suggested_data_root is not None:
            defaults["dataRoot"] = str(suggested_data_root)
        candidate = {"schemaVersion": 2}
        output_fn("请输入路径（留空保留建议，输入“取消”停止）。")
        labels = {"applicationDirectory": "应用安装目录", "dataRoot": "旅行相册目录"}
        for key in PATH_KEYS:
            candidate[key] = ask(labels[key] + "（" + key + "）[" + defaults[key] + "]：") or defaults[key]
        candidate = validate_config(candidate, repository=repository, home=home)
        output_fn("配置摘要：\n" + "\n".join(labels[key] + "（" + key + "）：" + candidate[key] for key in PATH_KEYS))
        if existing is not None and candidate["dataRoot"] != existing["dataRoot"]:
            output_fn("注意：修改 dataRoot 后将打开另一相册。原相册会保留，不会迁移或删除数据。")
        if ask("保存这份私有配置？输入“确认”或 yes 保存，默认取消：").lower() not in ("yes", "确认"):
            raise ConfigCancelled("已取消配置。")
        return write_config(candidate, repository=repository, home=home, expected_state=previous)
    except (EOFError, KeyboardInterrupt) as error:
        raise ConfigCancelled("已取消配置。") from error
    except (OSError, UnicodeError) as error:
        raise ConfigError("Cannot safely access private configuration.") from error
