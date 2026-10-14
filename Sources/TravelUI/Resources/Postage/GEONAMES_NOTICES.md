# GeoNames city coordinates

Source: GeoNames cities15000, retrieved 2026-10-10 from https://download.geonames.org/export/dump/cities15000.zip .

Copyright GeoNames contributors. Licensed under Creative Commons Attribution 4.0 International: https://creativecommons.org/licenses/by/4.0/ . GeoNames attribution: https://www.geonames.org/ . Documentation: https://download.geonames.org/export/dump/readme.txt .

Changes: retain GeoNames ID, country code, WGS84 latitude/longitude, primary and ASCII city names and CJK aliases; omit unrelated columns. Regenerate with `python3 Scripts/prepare-postage-cities.py /path/to/cities15000.zip`.

The source archive SHA-256 is `9339ac426943c265eb7fdfd5350ae351a5584b4d4271ed58f071ddc432982aeb`. Coordinates are approximate city centres, not user addresses or route distances. This static catalogue can be incomplete, ambiguous or stale. It is used only for fictional game postage; unresolved locations use a commemorative stamp.
