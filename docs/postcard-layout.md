# Postcard layout contract

Every message block is leading-aligned regardless of region.

Location labels use concise display names without changing persisted location data.
Message rendering keeps full text available to accessibility while fitting a bounded
visual summary. The paw follows measured text when space permits and otherwise
moves onto its own signature line. Placement must avoid protected image regions,
text collisions, and clipping. Geometry and fitting are covered by the UI tests.

Loaded artwork uses its original aspect ratio within the available width and
maximum height. Image rendering, overlays and rounded clipping share that fitted
canvas; a square picture must not acquire landscape-shaped side gutters.

Detail placement also considers bounded short, wide strips at the top and bottom
of the image. Typography, rendering and paw placement share the same adaptive
padding. Subject protection and actual text fitting still apply: an unknown image
or a picture without enough safe space retains the conservative caption fallback.
