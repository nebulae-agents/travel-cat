#!/bin/zsh
# Isolated manual preview; never launch the production entry point or XCTest runner.
set -euo pipefail
project_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
"$project_root/Scripts/travel-cat-swift.sh" test --filter AgentXAppShellTests >&2
scratch="$("$project_root/Scripts/travel-cat-swift.sh" scratch-path)"
preview_root="$(mktemp -d /private/tmp/agentx-shell-v7.XXXXXX)"
python3 - "$project_root" "$scratch" "$preview_root" <<'PYBUILD'
from pathlib import Path
import plistlib, subprocess, sys
project, scratch, root = map(Path, sys.argv[1:])
products = scratch / 'out/Products/Debug'
object_dirs = list((scratch / 'out/Intermediates.noindex/TravelCat.build/Debug').glob('TravelCatApp-*-testable-t.build/Objects-normal/*'))
if len(object_dirs) != 1:
    raise SystemExit('Expected one Xcode debug testable object directory; run with the Xcode Swift toolchain.')
app = root / 'AgentXShellV7Preview.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True)
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleExecutable='AgentXShellV7Preview', CFBundleIdentifier='local.agentx.shell-v7.preview', CFBundleName='AgentX Shell v7 Preview', CFBundlePackageType='APPL', LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True), f)
objects = sorted(object_dirs[0].glob('*.o'))
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(products), '-I', str(scratch / 'checkouts/Yams/Sources/CYaml/include'), str(project / 'Tests/ManualAgentWorkbench/ShellV7Preview.swift'), *map(str, objects), *[str(products / name) for name in ['TravelCore.o', 'TravelStorage.o', 'TravelUI.o', 'Yams.o', 'CYaml.o', 'AgentXAppSDK.o']], '-lsqlite3', '-o', str(macos / 'AgentXShellV7Preview')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
PYBUILD
# Running the owned executable gives an observable PID and unbuffered diagnostics.
# Keep this terminal open; close the window or wait up to 15 minutes to end.
exec "$preview_root/AgentXShellV7Preview.app/Contents/MacOS/AgentXShellV7Preview"
