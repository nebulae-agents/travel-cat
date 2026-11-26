"""Test entry point for the retired Python writer, using a private temporary fixture."""
import argparse
from pathlib import Path
import signal
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Runtime"))
from agentxd import serve


if __name__ == "__main__":
    def stop(_signal, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--pi-bundle", type=Path, help="Existing application bundle with the embedded Pi runtime")
    parser.add_argument("--audit-helper", type=Path, help="Absolute Swift app executable with audit helper support (defaults to Pi bundle executable)")
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        temporary = {Path("/tmp").resolve(), Path(tempfile.gettempdir()).resolve()}
        if not any(parent in root.parents for parent in temporary):
            raise ValueError("the Python reference requires a temporary fixture root")
        serve(root, pi_bundle=args.pi_bundle, audit_helper=args.audit_helper)
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit("agentxd: " + str(error))
