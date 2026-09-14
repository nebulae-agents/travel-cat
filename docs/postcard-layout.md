# Postcard layout contract

Every message block is leading-aligned regardless of region.

Location labels use concise display names without changing persisted location data.
Message rendering keeps full text available to accessibility while fitting a bounded
visual summary. The paw follows measured text when space permits and otherwise
moves onto its own signature line. Placement must avoid protected image regions,
text collisions, and clipping. Geometry and fitting are covered by the UI tests.
