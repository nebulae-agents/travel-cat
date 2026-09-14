#!/usr/bin/env python3
"""Interactively publish one reviewed Travel Cat commit to github.com."""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
from urllib.parse import urlsplit


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from github_preflight import _is_private_path  # noqa: E402


EXIT_REFUSED = 65
EXIT_ENVIRONMENT = 69
EXIT_OPERATIONAL = 70
OWNER_RE = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}"
)
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]{1,100}")


class Refusal(Exception):
    pass


class OperationalFailure(Exception):
    pass


class SystemRuntime:
    def which(self, name):
        return shutil.which(name)

    def is_interactive(self):
        return sys.stdin.isatty() and sys.stdout.isatty()

    def run(self, arguments, *, cwd=None, env=None):
        if arguments[:2] == ["git", "push"]:
            return subprocess.run(arguments, cwd=cwd, env=env)
        return subprocess.run(
            arguments,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


def _text(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="surrogateescape")
    return value


def _result(runtime, arguments, repo, *, gh=False):
    environment = None
    if gh:
        environment = os.environ.copy()
        environment["GH_HOST"] = "github.com"
        environment.pop("GH_REPO", None)
    return runtime.run(arguments, cwd=repo, env=environment)


def _git(runtime, repo, *arguments, allowed=(0,)):
    result = _result(runtime, ["git", *arguments], repo)
    if result.returncode not in allowed:
        raise Refusal("Git could not safely inspect the repository")
    return _text(result.stdout)


def _valid_target(value):
    if value.count("/") != 1 or value != value.strip():
        return False
    owner, repository = value.split("/", 1)
    return bool(
        OWNER_RE.fullmatch(owner)
        and REPOSITORY_RE.fullmatch(repository)
        and repository not in {".", ".."}
        and not repository.casefold().endswith(".git")
    )


def _target_from_remote_url(value):
    if not value or value != value.strip() or any(ord(char) < 32 for char in value):
        raise Refusal("origin contains an unsafe URL")
    scp_match = re.fullmatch(r"git@github\.com:([^/]+)/([^/]+)", value)
    if scp_match:
        owner, repository = scp_match.groups()
    else:
        parsed = urlsplit(value)
        if parsed.scheme not in {"https", "ssh"} or parsed.hostname != "github.com":
            raise Refusal("origin must use HTTPS or SSH on github.com")
        if parsed.port is not None or parsed.password is not None:
            raise Refusal("origin must not contain credentials or a custom port")
        if parsed.scheme == "https" and parsed.username is not None:
            raise Refusal("origin HTTPS URL must not contain credentials")
        if parsed.scheme == "ssh" and parsed.username != "git":
            raise Refusal("origin SSH URL must use the git account")
        if parsed.query or parsed.fragment or parsed.path.count("/") != 2:
            raise Refusal("origin contains an unsafe repository path")
        owner, repository = parsed.path.removeprefix("/").split("/", 1)
    if repository.endswith(".git"):
        repository = repository[:-4]
    target = f"{owner}/{repository}"
    if "%" in value or "\\" in value or not _valid_target(target):
        raise Refusal("origin contains an unsafe repository path")
    return target


def _config_values(runtime, repo, key):
    result = _result(runtime, ["git", "config", "--get-all", key], repo)
    if result.returncode == 1:
        return []
    if result.returncode != 0:
        raise Refusal("Git configuration could not be safely inspected")
    return [line for line in _text(result.stdout).splitlines() if line]


def _inspect_remote(runtime, repo, branch):
    remotes = _git(runtime, repo, "remote").splitlines()
    if not remotes:
        return None
    if remotes != ["origin"]:
        raise Refusal("only a single remote named origin is allowed")
    if _config_values(runtime, repo, "remote.origin.push"):
        raise Refusal("origin must not define implicit push refspecs")
    mirror = _config_values(runtime, repo, "remote.origin.mirror")
    if mirror and mirror != ["false"]:
        raise Refusal("mirror remotes are not supported")
    push_default = _config_values(runtime, repo, "remote.pushDefault")
    branch_remote = _config_values(runtime, repo, f"branch.{branch}.pushRemote")
    if any(value != "origin" for value in push_default + branch_remote):
        raise Refusal("push routing must not redirect away from origin")

    raw_urls = _config_values(runtime, repo, "remote.origin.url")
    raw_push_urls = _config_values(runtime, repo, "remote.origin.pushurl")
    fetch_urls = _git(runtime, repo, "remote", "get-url", "--all", "origin").splitlines()
    push_urls = _git(
        runtime, repo, "remote", "get-url", "--push", "--all", "origin"
    ).splitlines()
    if len(raw_urls) != 1 or not fetch_urls or not push_urls:
        raise Refusal("origin must have one unambiguous URL")
    targets = [_target_from_remote_url(url) for url in raw_urls + raw_push_urls + fetch_urls + push_urls]
    if len({target.casefold() for target in targets}) != 1:
        raise Refusal("origin fetch and push URLs must name the same repository")
    return {
        "target": targets[0],
        "raw": tuple(raw_urls),
        "raw_push": tuple(raw_push_urls),
        "fetch": tuple(fetch_urls),
        "push": tuple(push_urls),
    }


def _guard_reachable_history(runtime, repo, head):
    if any(name in os.environ for name in ("GIT_REPLACE_REF_BASE", "GIT_GRAFT_FILE")):
        raise Refusal("custom replacement or graft history is not supported")
    if _git(runtime, repo, "for-each-ref", "--format=%(refname)", "refs/replace").strip():
        raise Refusal("replacement history is not supported")
    graft = Path(_git(runtime, repo, "rev-parse", "--git-path", "info/grafts").strip())
    if not graft.is_absolute():
        graft = repo / graft
    if os.path.lexists(graft):
        raise Refusal("grafted history is not supported")
    shallow = _git(runtime, repo, "rev-parse", "--is-shallow-repository").strip()
    if shallow != "false":
        raise Refusal("complete reachable Git history is required")
    result = _result(
        runtime,
        [
            "git", "log", "--no-show-signature", "--no-color", "--format=", "--name-only", "-z", "--root", "-m",
            "--no-renames", head, "--",
        ],
        repo,
    )
    if result.returncode != 0:
        raise Refusal("reachable Git history could not be inspected")
    output = result.stdout
    if isinstance(output, str):
        output = output.encode("utf-8", errors="surrogateescape")
    for raw_path in output.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", errors="surrogateescape")
        components = PurePosixPath(path.casefold()).parts
        if _is_private_path(path) or "travelpetdata" in components:
            raise Refusal("reachable Git history contains a private or generated path")


def _inspect_repository(runtime, repo):
    actual = Path(_git(runtime, repo, "rev-parse", "--show-toplevel").strip()).resolve()
    if actual != repo:
        raise Refusal("the publisher must run against the exact repository root")
    audit = repo / "Scripts" / "audit-project-upload.sh"
    result = _result(runtime, [str(audit)], repo)
    if result.returncode != 0:
        raise Refusal("the upload audit refused this repository")
    branch_result = _result(
        runtime, ["git", "symbolic-ref", "--quiet", "--short", "HEAD"], repo
    )
    if branch_result.returncode != 0:
        raise Refusal("detached HEAD cannot be published")
    branch = _text(branch_result.stdout).strip()
    check_branch = _result(runtime, ["git", "check-ref-format", "--branch", branch], repo)
    if check_branch.returncode != 0:
        raise Refusal("the current branch name is unsafe")
    head = _git(runtime, repo, "rev-parse", "--verify", "HEAD^{commit}").strip()
    if not re.fullmatch(r"[0-9a-f]{40,64}", head):
        raise Refusal("HEAD is not an exact commit")
    status = _git(
        runtime, repo, "status", "--porcelain=v1", "-z", "--untracked-files=all"
    )
    if status:
        raise Refusal("the repository must be completely clean")
    _guard_reachable_history(runtime, repo, head)
    return {
        "head": head,
        "branch": branch,
        "remote": _inspect_remote(runtime, repo, branch),
    }


def _same_snapshot(before, after):
    return before == after


def _view_repository(runtime, repo, target):
    result = _result(
        runtime,
        ["gh", "repo", "view", target, "--json", "nameWithOwner,visibility"],
        repo,
        gh=True,
    )
    if result.returncode != 0:
        raise Refusal("GitHub could not verify the existing repository")
    try:
        payload = json.loads(_text(result.stdout))
        actual = payload["nameWithOwner"]
        visibility = payload["visibility"].lower()
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        raise Refusal("GitHub returned an invalid repository description")
    if not _valid_target(actual) or actual.casefold() != target.casefold():
        raise Refusal("origin and the GitHub repository do not match")
    if visibility not in {"private", "public", "internal"}:
        raise Refusal("GitHub returned an unknown repository visibility")
    return actual, visibility


def _prompt_target(input_fn):
    target = input_fn("GitHub target (exact OWNER/REPO): ")
    if not _valid_target(target):
        raise Refusal("target must be an exact safe OWNER/REPO name")
    visibility = input_fn("Visibility [private/public] (default: private): ").strip().lower()
    if not visibility:
        visibility = "private"
    if visibility not in {"private", "public"}:
        raise Refusal("visibility must be private or public")
    return target, visibility


def publish(*, repository, runtime=None, input_fn=input, stdout=sys.stdout, stderr=sys.stderr):
    runtime = runtime or SystemRuntime()
    created_external = False
    try:
        repo = Path(repository).resolve(strict=True)
        if not runtime.is_interactive():
            print("Publish requires an interactive Terminal session.", file=stderr)
            return EXIT_ENVIRONMENT
        for tool in ("git", "gh"):
            if runtime.which(tool) is None:
                if tool == "gh":
                    print("GitHub CLI (gh) is required. Install it from https://cli.github.com/ and run gh auth login.", file=stderr)
                else:
                    print("Git is required to publish this repository.", file=stderr)
                return EXIT_ENVIRONMENT
        auth = _result(
            runtime,
            ["gh", "auth", "status", "--active", "--hostname", "github.com"],
            repo,
            gh=True,
        )
        if auth.returncode != 0:
            print("No active github.com login. Run: gh auth login --hostname github.com", file=stderr)
            return EXIT_REFUSED

        selected = _inspect_repository(runtime, repo)
        if selected["remote"] is None:
            target, visibility = _prompt_target(input_fn)
            action = "create the repository, then push this commit"
            create = True
        else:
            target, visibility = _view_repository(
                runtime, repo, selected["remote"]["target"]
            )
            action = "push this commit to the existing repository"
            create = False

        print("\nPublish summary", file=stdout)
        print(f"  Target: {target}", file=stdout)
        print(f"  Commit: {selected['head']}", file=stdout)
        print(f"  Branch: {selected['branch']}", file=stdout)
        print(f"  Visibility: {visibility}", file=stdout)
        print(f"  Action: {action}", file=stdout)
        if input_fn("Type yes to continue: ").strip() != "yes":
            print("Publish cancelled; nothing was created or pushed.", file=stdout)
            return 0

        rechecked = _inspect_repository(runtime, repo)
        if not _same_snapshot(selected, rechecked):
            raise Refusal("repository state changed before publishing")

        if create:
            result = _result(
                runtime,
                ["gh", "repo", "create", target, f"--{visibility}", "--source", str(repo),
                 "--remote", "origin"],
                repo,
                gh=True,
            )
            if result.returncode != 0:
                print("Repository creation failed. Any GitHub repository or origin added by gh is retained for manual inspection.", file=stderr)
                return EXIT_OPERATIONAL
            created_external = True
            created = _inspect_repository(runtime, repo)
            if created["head"] != selected["head"] or created["branch"] != selected["branch"]:
                raise Refusal("repository state changed after creation; the new repository and origin are retained")
            if created["remote"] is None or created["remote"]["target"].casefold() != target.casefold():
                raise Refusal("created origin did not match the requested target; retained for manual inspection")
            actual, actual_visibility = _view_repository(runtime, repo, target)
            if actual.casefold() != target.casefold() or actual_visibility != visibility:
                raise Refusal("created repository did not match the request; retained for manual inspection")

        final_snapshot = _inspect_repository(runtime, repo)
        expected_snapshot = created if create else rechecked
        if not _same_snapshot(expected_snapshot, final_snapshot):
            raise Refusal("repository state changed before push")

        push = _result(
            runtime,
            ["git", "push", "--no-follow-tags", "origin",
             f"{selected['head']}:refs/heads/{selected['branch']}"],
            repo,
        )
        if push.returncode != 0:
            print("Push failed. The repository, origin, and any remote state are retained; no cleanup was attempted.", file=stderr)
            return EXIT_OPERATIONAL
        print("Publish completed for the exact commit shown above.", file=stdout)
        return 0
    except Refusal as error:
        retained = " The created repository and origin are retained." if created_external else ""
        print(f"Publish refused: {error}.{retained}", file=stderr)
        return EXIT_REFUSED
    except (OSError, UnicodeError, EOFError):
        retained = " The created repository and origin are retained." if created_external else ""
        print("Publish stopped because the repository could not be safely inspected." + retained, file=stderr)
        return EXIT_OPERATIONAL


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository", type=Path,
        default=Path(__file__).resolve().parent.parent,
    )
    args = parser.parse_args(argv)
    return publish(repository=args.repository)


if __name__ == "__main__":
    sys.exit(main())
