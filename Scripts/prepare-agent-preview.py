#!/usr/bin/env python3
"""Prepare a new isolated preview bundle before its first launch."""
import argparse
from pathlib import Path
import plistlib
import re
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--name', default='AgentWorkbenchPreview')
    parser.add_argument('--bundle-id', default='com.nebulae.travelcat.agent-preview')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]{0,63}', args.name):
        parser.error('preview name must be a simple app name')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+', args.bundle_id):
        parser.error('preview bundle id must be a valid reverse domain identifier')
    app = args.root / (args.name + '.app')
    if app.exists() or app.is_symlink(): parser.error('preview app already exists; choose a fresh preview root')
    runtime = args.project_root / 'Sources/TravelCatApp/Resources/AgentRuntime'
    sources = sorted(runtime.glob('*.py'))
    if not sources or not (runtime / 'sidecar.py').is_file(): parser.error('production AgentRuntime unavailable')
    resources = app / 'Contents/Resources'
    (app / 'Contents/MacOS').mkdir(parents=True)
    (resources / 'AgentRuntime').mkdir(parents=True)
    for source in sources: shutil.copyfile(source, resources / 'AgentRuntime' / source.name)
    shutil.copyfile(args.project_root / 'Sources/TravelUI/Resources/PreviewPostcards/preview-kyoto-lanterns.png', resources / 'preview.png')
    info = {'CFBundleExecutable': args.name, 'CFBundleIdentifier': args.bundle_id, 'CFBundleName': args.name,
            'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'NSPrincipalClass': 'NSApplication', 'CFBundlePackageType': 'APPL'}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    print(app)


if __name__ == '__main__': main()
