#!/usr/bin/env python3
"""Run the actual release app offline after relocation, including missing-asset failures.

Usage: python3 Scripts/run-packaged-travel-acceptance.py 'dist/Travel Cat.app'
The supplied app is read-only. Only disposable copies and synthetic data are changed.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

FLAG = "--offline-packaged-acceptance"
ASSETS = ("narrative.schema.json", "image.schema.json", "front.png", "side.png", "sitting.png", "identity.json")


class AcceptanceFailure(Exception):
    """Fixed public classifications only; subprocess output must never be echoed."""


def run_probe(binary, cwd, environment, arguments=None, timeout=45):
    try:
        result = subprocess.run([str(binary)] + ([FLAG] if arguments is None else arguments),
                                cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise AcceptanceFailure("probeTimedOut") from None
    except OSError:
        raise AcceptanceFailure("probeLaunchFailed") from None
    if len(result.stdout) > 65536:
        raise AcceptanceFailure("invalidReport")
    try:
        report = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        raise AcceptanceFailure("invalidReport") from None
    if not isinstance(report, dict) or report.get("schemaVersion") != 1:
        raise AcceptanceFailure("invalidReport")
    return result.returncode, report


def verify_success(status, report):
    fields = {"schemaVersion", "status", "packagedResourceCount", "copiedResourceCount",
              "pendingObserved", "readyObserved", "readbackVerified", "narrativeCalls", "imageCalls"}
    if (set(report) != fields or status != 0 or report.get("status") != "ok"
            or report.get("packagedResourceCount") != 6 or report.get("copiedResourceCount") != 6
            or any(report.get(field) is not True for field in ("pendingObserved", "readyObserved", "readbackVerified"))
            or not isinstance(report.get("narrativeCalls"), int) or report["narrativeCalls"] < 1
            or report.get("imageCalls") != 1):
        raise AcceptanceFailure("incompleteAcceptance")


def verify_failure(result, code):
    status, report = result
    if status == 0 or report != {"schemaVersion": 1, "status": "failed", "code": code}:
        raise AcceptanceFailure("expectedRejectionMissing")


def sign(app):
    try:
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       timeout=30, check=True)
    except (OSError, subprocess.SubprocessError):
        raise AcceptanceFailure("copySigningFailed") from None


def accept(app):
    if sys.platform != "darwin" or app.suffix != ".app" or not (app / "Contents/MacOS/TravelCatApp").is_file():
        raise AcceptanceFailure("invalidPackagedApp")
    with tempfile.TemporaryDirectory(prefix="travelcat-packaged-acceptance-") as temporary:
        root = Path(temporary).resolve()
        relocated = root / "Relocated Travel Cat.app"
        shutil.copytree(app, relocated)
        cwd = root / "unrelated-working-directory"
        cwd.mkdir()
        home = root / "synthetic-home"
        home.mkdir(mode=0o700)
        temporary_data = root / "temporary-data"
        temporary_data.mkdir(mode=0o700)
        # No inherited provider, proxy, model, data-root or credential settings.
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
                       "TMPDIR": str(temporary_data) + "/", "LANG": "en_US.UTF-8"}
        binary = relocated / "Contents/MacOS/TravelCatApp"
        status, positive = run_probe(binary, cwd, environment)
        verify_success(status, positive)
        for arguments in ([FLAG, "/must-not-be-used"], [FLAG + "=true"], ["--offline-packaged"]):
            verify_failure(run_probe(binary, cwd, environment, arguments), "invalidArguments")
        unbundled = root / "UnbundledTravelCatApp"
        shutil.copy2(binary, unbundled)
        verify_failure(run_probe(unbundled, cwd, environment), "notPackagedApp")

        broken = root / "Missing Resource Travel Cat.app"
        shutil.copytree(relocated, broken)
        bundle = broken / "Contents/Resources/TravelCat_TravelCatApp.bundle"
        resources = bundle / "Contents/Resources" if (bundle / "Contents/Resources").is_dir() else bundle
        generation = resources / "Generation"
        for name in ASSETS:
            resource = generation / name
            saved = root / ("saved-" + name)
            resource.rename(saved)
            try:
                # The modified disposable copy is signed again so failure proves
                # resource lookup, rather than an invalid code-signature launch.
                sign(broken)
                verify_failure(run_probe(broken / "Contents/MacOS/TravelCatApp", cwd, environment), "missingResource")
            finally:
                saved.rename(resource)
        if any(temporary_data.glob("travelcat-*")):
            raise AcceptanceFailure("syntheticCleanupFailed")
        return {"schemaVersion": 1, "status": "ok", "positive": positive,
                "missingResourceRejections": list(ASSETS), "invalidArgumentRejections": 3,
                "unbundledRejected": True, "syntheticDataRemoved": True}


def main():
    try:
        if len(sys.argv) != 2:
            raise AcceptanceFailure("invalidArguments")
        report = accept(Path(sys.argv[1]).resolve(strict=True))
    except Exception as error:
        code = str(error) if isinstance(error, AcceptanceFailure) else "acceptanceFailed"
        print(json.dumps({"schemaVersion": 1, "status": "failed", "code": code}, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
