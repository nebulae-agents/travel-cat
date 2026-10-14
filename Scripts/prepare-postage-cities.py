#!/usr/bin/env python3
"""Derive the offline postage catalogue from a downloaded GeoNames cities15000.zip."""
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(__file__).resolve().parents[1] / "Sources/TravelUI/Resources/Postage/cities.tsv"
rows = []
with zipfile.ZipFile(source) as archive:
    for line in archive.read("cities15000.txt").decode("utf-8").splitlines():
        fields = line.split("\t")
        # Retain primary/ASCII names and CJK aliases. Population and unrelated
        # metadata are not used for postage. Ambiguous aliases remain ambiguous.
        names = [fields[1], fields[2]] + [name for name in fields[3].split(",")
            if any("\u3400" <= char <= "\u9fff" or "\u3040" <= char <= "\u30ff"
                   or "\uac00" <= char <= "\ud7af" for char in name)]
        names = list(dict.fromkeys(name for name in names if name and "|" not in name))
        rows.append("\t".join([fields[0], fields[8], fields[4], fields[5], "|".join(names)]))
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n".join(rows) + "\n", encoding="utf-8")
print(f"Prepared {len(rows)} cities, {destination.stat().st_size} bytes")
