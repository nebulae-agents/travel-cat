#!/usr/bin/env python3
"""Build clean source and recoverably install only Travel Cat.app locally."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from deploy_config import ConfigCancelled, _write_exclusive, choose_config, load_config, validate_config
from deployment_files import (DeploymentLock, OwnedDirectory, Publication, archive_receipt, file_bytes, fingerprint,
                              read_receipt, tree_digest, write_receipt)
from deployment_runtime import Runtime


def clean_revision(repository):
    def git(*arguments):
        return subprocess.check_output(["git", "-C", str(repository), *arguments], stderr=subprocess.PIPE).decode().strip()
    if Path(git("rev-parse", "--show-toplevel")).resolve() != repository:
        raise ValueError("Deployment source must be the exact Git repository root")
    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Deployment requires clean HEAD; review and commit uncommitted/untracked source first")
    return git("rev-parse", "HEAD")


def deploy(repository, config, *, home=None, runtime=None, output_fn=print, confirm_album_change=None):
    repository = Path(repository).resolve(strict=True)
    runtime = runtime or Runtime()
    config = validate_config(config, repository=repository, home=home)
    local = repository / ".local"
    with DeploymentLock(local) as lock:
        bound = fingerprint(config)
        if fingerprint(load_config(repository=repository, home=home)) != bound:
            raise ValueError("Private config changed before deployment lock")
        runtime.check_tools()
        revision = clean_revision(repository)
        runtime.audit(repository)
        targets = {"app": str(Path(config["applicationDirectory"]) / "Travel Cat.app")}
        app = Path(targets["app"])
        prior = read_receipt(local, config)
        prior_path = local / "deployment-receipt.json"
        previous_bytes = file_bytes(prior_path, 65536) if prior_path.exists() else None
        old_app_digest = None
        if app.exists() or app.is_symlink():
            existing = runtime.inspect_app(app)
            old_root = existing.get("TravelCatDataRoot")
            if old_root and old_root != config["dataRoot"]:
                if confirm_album_change is None or not confirm_album_change(old_root, config["dataRoot"]):
                    raise ValueError("Changing the installed app's explicit album needs interactive confirmation（相册路径）。")
            old_app_digest = tree_digest(app)

        def recheck():
            lock.check()
            if fingerprint(load_config(repository=repository, home=home)) != bound:
                raise ValueError("Private config changed during deployment")
            if clean_revision(repository) != revision:
                raise ValueError("HEAD revision changed during deployment")
            runtime.audit(repository)

        output_fn("正在从已提交版本构建并验证本机安装；现有应用与相册保持可用。")
        run_id = uuid.uuid4().hex
        backup = local / ("deployment-" + run_id)
        backup.mkdir(mode=0o700)
        workspace = OwnedDirectory()
        publications = []
        receipt = None
        preserve_staging = False
        stop_attempted = False
        was_running = False
        launched = False
        receipt_write_failed = False

        def persist(value):
            nonlocal receipt_write_failed
            try:
                write_receipt(local, value, lock)
            except BaseException:
                receipt_write_failed = True
                raise

        try:
            if previous_bytes is not None:
                descriptor = os.open(str(backup), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    _write_exclusive(descriptor, "previous-receipt.json", previous_bytes)
                finally:
                    os.close(descriptor)
            log_descriptor = os.open(str(backup / "build.log"), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(log_descriptor, "wb") as log:
                candidate = runtime.build(repository, revision, config, workspace.path, log)
            # A boundary adapter must only return objects under our owned temp.
            workspace.check()
            candidate.relative_to(workspace.path)
            runtime.verify_app(candidate, repository, revision, config)
            recheck()
            app_publication = Publication("app", app, candidate, backup / "app", old_app_digest, runtime.copy_tree)
            publications.append(app_publication)
            receipt = {"schemaVersion": 2, "runID": run_id, "sourceRevision": revision,
                       "configFingerprint": bound, "targets": targets, "appDigest": app_publication.new_digest,
                       "status": "prepared", "backupDirectory": str(backup), "stages": ["prepared"],
                       "error": "", "recoveryErrors": []}
            persist(receipt)
            recheck()
            for publication in publications:
                publication.check_old()
            runtime.verify_app(app_publication.candidate, repository, revision, config)
            output_fn("构建和备份校验完成，正在退出指定应用并安装。")
            if old_app_digest is not None:
                was_running = runtime.is_running(app)
                stop_attempted = True
                runtime.stop(app)
            recheck()
            for publication in publications:
                publication.publish()
                receipt["stages"].append(publication.label + "-published")
                persist(receipt)
            runtime.verify_app(app, repository, revision, config)
            if tree_digest(app) != receipt["appDigest"]:
                raise ValueError("Published installation verification failed")
            receipt["stages"].append("verified")
            persist(receipt)
            # Mark before opening: a failed launch may have created a process.
            launched = True
            runtime.launch(app)
            receipt["stages"].append("launched")
            receipt["status"] = "complete"
            persist(receipt)
            output_fn("本机应用已验证并启动；未安装或修改 Codex 宠物与插件。")
            return receipt
        except BaseException as error:
            recovery = []
            if launched:
                try:
                    runtime.stop(app)
                except BaseException as stop_error:
                    recovery.append("Could not stop new app: " + str(stop_error))
            if not recovery:
                for publication in reversed(publications):
                    try:
                        publication.rollback()
                    except BaseException as rollback_error:
                        recovery.append(publication.label + ": " + str(rollback_error))
                if stop_attempted and was_running and not recovery:
                    try:
                        if not runtime.is_running(app):
                            runtime.launch(app)
                    except BaseException as launch_error:
                        recovery.append("Could not relaunch old app: " + str(launch_error))
            if receipt_write_failed:
                recovery.append("Deployment receipt write failed; recovery needs review")
            preserve_staging = bool(recovery)
            if receipt is not None:
                receipt["status"] = "recovery-failed" if recovery else "rolled-back"
                receipt["error"] = str(error)[:4096]
                receipt["recoveryErrors"] = [value[:4096] for value in recovery]
                try:
                    persist(receipt)
                    archive_receipt(local, receipt, lock)
                    if (not recovery and prior is not None and prior["schemaVersion"] == 2
                            and prior["status"] == "complete" and tree_digest(app) == prior["appDigest"]):
                        # The failed candidate remains archived; only a fully
                        # restored, previously bound installation regains authority.
                        persist(prior)
                except BaseException as receipt_error:
                    preserve_staging = True
                    receipt["status"] = "recovery-failed"
                    receipt["recoveryErrors"].append("Receipt recovery failed: " + str(receipt_error)[:4096])
                    try:
                        persist(receipt)
                    except BaseException:
                        pass  # Preserve the last blocker and all files for manual recovery.
                    output_fn("部署记录写入失败；保留所有临时目录与备份供恢复：" + str(receipt_error))
            if recovery:
                output_fn("自动恢复未完成，保留备份与临时目录：" + str(backup))
            raise
        finally:
            if not preserve_staging:
                for publication in publications:
                    publication.cleanup()
                workspace.cleanup()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-existing", action="store_true", help="explicitly reuse private config in noninteractive mode")
    args = parser.parse_args(argv)
    repository = Path(__file__).resolve().parent.parent
    runtime = Runtime()
    try:
        interactive = sys.stdin.isatty()
        suggestion = None
        if interactive and not (repository / ".local/deploy.json").exists():
            suggestion = runtime.legacy_data_root(Path.home())
        config = choose_config(repository=repository, interactive=interactive, reuse_existing=args.reuse_existing,
                               suggested_data_root=suggestion)
        def confirm(old, new):
            print("注意：现有应用相册为 " + old + "；新配置将打开 " + new + "。原相册会保留。")
            try:
                return input("确认切换相册？输入 yes 或“确认”，默认取消：").strip().lower() in ("yes", "确认")
            except (EOFError, KeyboardInterrupt):
                return False
        deploy(repository, config, runtime=runtime, confirm_album_change=confirm if interactive else None)
    except ConfigCancelled:
        print("已取消本机部署。")
        return 0
    except (Exception, KeyboardInterrupt) as error:
        print("本机部署失败：" + str(error), file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main())
