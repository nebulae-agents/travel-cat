#!/usr/bin/env python3
"""Reproduce pinned historical prompt output; never update fixtures during tests."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


REPOSITORY = Path(__file__).resolve().parents[3]
BASELINES = [
    ("67b6db7b9b6e4809a59c1a5483918293cf81d521", [1]),
    ("25c2258405e1f95324869aad2ac3b6d703404484", [2, 3]),
]
SOURCE_PATHS = [
    "Sources/TravelCore/PostcardSceneStyle.swift",
    "Sources/TravelCatApp/TravelGenerationPrompts.swift",
]

# These are the only event fields read by the historical image prompt functions.
# The XCTest uses the real TripEvent, including serialization and retry statuses.
EVENT_TYPES = """
import Foundation
public struct Location {
    let country: String
    let city: String
    let place: String
}
public struct TripEvent {
    let id: UUID
    let location: Location?
    let summary: String
    let postcardStyleVersion: Int?
}
"""

OUTPUT_PROGRAM = r"""
struct PromptSnapshot: Encodable {
    let name: String
    let sourceCommit: String
    let eventID: UUID
    let country: String
    let city: String
    let place: String
    let summary: String
    let version: Int?
    let category: String?
    let compositionVariant: Int?
    let imagePrompt: String
    let codexPrompt: String
}

func event(place: String, version: Int?, number: Int) -> TripEvent {
    TripEvent(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
        location: Location(country: "中国", city: "旅行城市", place: place),
        summary: "停下脚步仔细看了看。", postcardStyleVersion: version)
}

func snapshot(_ event: TripEvent, name: String, commit: String) -> PromptSnapshot {
    let style = PostcardSceneStyle.resolve(event: event)
    return PromptSnapshot(name: name, sourceCommit: commit, eventID: event.id,
        country: event.location!.country, city: event.location!.city, place: event.location!.place,
        summary: event.summary, version: event.postcardStyleVersion,
        category: style?.category.rawValue, compositionVariant: style?.compositionVariant,
        imagePrompt: TravelGenerationPrompts.image(for: event),
        codexPrompt: TravelGenerationPrompts.codexImage(for: event))
}

let commit = CommandLine.arguments[1]
let versions = CommandLine.arguments.dropFirst(2).map { Int($0)! }
let scenes = [("waterside", "西湖湖岸"), ("heritage", "故宫"), ("market", "夜市"),
              ("mountain", "高山"), ("garden", "花园"), ("urban", "街头"), ("everyday", "目的地")]
var snapshots: [PromptSnapshot] = []
if versions.contains(1) {
    snapshots.append(snapshot(event(place: "西湖湖岸", version: nil, number: 1), name: "legacy", commit: commit))
    snapshots.append(snapshot(event(place: "西湖湖岸", version: 99, number: 1), name: "unknown-99", commit: commit))
}
for version in versions {
    for (category, place) in scenes {
        var variants: [Int: TripEvent] = [:]
        for number in 1...100 {
            let candidate = event(place: place, version: version, number: number)
            let style = PostcardSceneStyle.resolve(event: candidate)!
            precondition(style.category.rawValue == category)
            if variants[style.compositionVariant] == nil { variants[style.compositionVariant] = candidate }
            if variants.count == 3 { break }
        }
        precondition(variants.count == 3)
        for variant in 0...2 {
            snapshots.append(snapshot(variants[variant]!, name: "v\(version)-\(category)-\(variant)", commit: commit))
        }
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(snapshots))
"""


def historical_source(commit, path):
    return subprocess.check_output(["git", "show", f"{commit}:{path}"], cwd=REPOSITORY)


def generate():
    baselines = []
    snapshots = []
    for commit, versions in BASELINES:
        sources = []
        units = [EVENT_TYPES]
        for path in SOURCE_PATHS:
            source = historical_source(commit, path)
            blob = subprocess.check_output(
                ["git", "rev-parse", f"{commit}:{path}"], cwd=REPOSITORY, text=True
            ).strip()
            sources.append({"path": path, "gitBlob": blob, "sha256": hashlib.sha256(source).hexdigest()})
            units.append(source.decode("utf-8").replace("import TravelCore\n", ""))
        baselines.append({"commit": commit, "sources": sources})
        with tempfile.TemporaryDirectory(prefix="travelcat-historical-prompts-") as directory:
            temporary = Path(directory)
            main = temporary / "main.swift"
            main.write_text("\n".join([*units, OUTPUT_PROGRAM]), encoding="utf-8")
            executable = temporary / "historical-prompts"
            subprocess.run(
                ["/usr/bin/xcrun", "swiftc", "-module-cache-path", str(temporary / "module-cache"),
                 str(main), "-o", str(executable)], check=True
            )
            output = subprocess.check_output([str(executable), commit, *map(str, versions)])
            snapshots.extend(json.loads(output))
    return {"format": "travel-cat-historical-image-prompts-v1", "baselines": baselines,
            "cases": sorted(snapshots, key=lambda item: item["name"])}


def encoded(snapshot):
    return (json.dumps(snapshot, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="Explicit output path; existing files are refused")
    arguments = parser.parse_args()
    snapshot = generate()
    with arguments.output.open("xb") as destination:
        destination.write(encoded(snapshot))
    print(f"Reproduced {len(snapshot['cases'])} historical cases in {arguments.output}")
