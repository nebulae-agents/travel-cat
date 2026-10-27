"""Exercise production postage from a relocated app, with its build tree gone."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS Swift toolchain")
class PackagedPostageTests(unittest.TestCase):
    def test_postage_resolves_after_build_tree_is_removed(self):
        with tempfile.TemporaryDirectory(prefix="travelcat-packaged-postage-") as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            scripts = source / "Scripts"
            scripts.mkdir(parents=True)
            wrapper = scripts / "travel-cat-swift.sh"
            shutil.copy2(ROOT / "Scripts/travel-cat-swift.sh", wrapper)
            for target in ("TravelCore", "TravelStorage"):
                shutil.copytree(ROOT / "Sources" / target, source / "Sources" / target)
            ui = source / "Sources/TravelUI"
            (ui / "Resources").mkdir(parents=True)
            for name in ("Module.swift", "PostcardPostage.swift"):
                shutil.copy2(ROOT / "Sources/TravelUI" / name, ui / name)
            shutil.copy2(ROOT / "Sources/TravelUI/Resources/Postage/cities.tsv", ui / "Resources/cities.tsv")
            (source / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TravelCat", platforms: [.macOS(.v14)],
    products: [.executable(name: "PackagedPostageProbe", targets: ["TravelUI"])],
    targets: [
        .target(name: "TravelCore"),
        .target(name: "TravelStorage", dependencies: ["TravelCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "TravelUI", dependencies: ["TravelCore", "TravelStorage"], resources: [.process("Resources")])
    ])
''')
            (ui / "main.swift").write_text('''import Foundation
import TravelCore
import TravelStorage
let home = HomeLocation(city: "广州", source: .manual, updatedAt: Date(timeIntervalSince1970: 0))
let postage = PostcardPostage.resolve(location: Location(country: "中国", city: "佛山", place: "fixture"), home: home)
guard postage.fare == 2, let distance = postage.distanceKilometers, (10...30).contains(distance) else {
    fatalError("Packaged city coordinates did not resolve nearby postage")
}
guard let resources = Bundle.main.resourceURL else { fatalError("App resources directory missing") }
let actual = TravelUIResources.bundle.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
let expected = resources.resolvingSymlinksInPath().standardizedFileURL.path
guard actual == expected else {
    fatalError("Resource lookup escaped the installed app: actual=\(actual), expected=\(expected)")
}
print("packaged postage: OK")
''')
            environment = {k: v for k, v in os.environ.items() if not k.startswith(("TRAVEL_CAT_", "TRAVELCAT_"))}
            scratch = root / "swift-scratch"
            environment["TRAVEL_CAT_SCRATCH_ROOT"] = str(scratch)
            build = subprocess.run([str(wrapper), "build", "--disable-sandbox", "-c", "release", "--product", "PackagedPostageProbe"],
                                   env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
            self.assertEqual(build.returncode, 0, build.stdout)
            binary_directory = subprocess.check_output([str(wrapper), "build", "-c", "release", "--show-bin-path"],
                                                        env=environment, text=True, timeout=30).strip()
            binary_directory = Path(binary_directory)
            app = root / "Relocated Travel Cat.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            shutil.copy2(binary_directory / "PackagedPostageProbe", app / "Contents/MacOS/PackagedPostageProbe")
            shutil.copytree(binary_directory / "TravelCat_TravelUI.bundle", app / "Contents/Resources/TravelCat_TravelUI.bundle")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.example.travelcat.packaged-postage-probe",
                "CFBundleExecutable": "PackagedPostageProbe", "CFBundlePackageType": "APPL"}))
            shutil.rmtree(scratch)
            shutil.rmtree(source)
            cwd = root / "unrelated-working-directory"
            cwd.mkdir()
            result = subprocess.run([str(app / "Contents/MacOS/PackagedPostageProbe")], cwd=cwd, env=environment,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(result.stdout.strip(), "packaged postage: OK")


if __name__ == "__main__":
    unittest.main()
