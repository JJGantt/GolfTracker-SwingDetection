# On-Course Test Reminders

- Scorecard proximity widening (25km gate). Multi-course resorts like
  Citrus Hills should surface all sibling courses in the picker now;
  single-course locations should still rank correctly by distance.

- Relative altitude capture during a round. Rows should land in
  `round_altitude_readings`, roughly one per 3m of movement, with
  sensible elevation deltas between tee and green. `sample_count`
  should be ~2-3 for walking rows and much higher for rows captured
  after the user paused at a tee or green.

- Per-stroke altitude. Each row in `strokes` should now carry a
  `rel_alt_meters` value from the moment of the swing. Within a single
  round, deltas between consecutive strokes on the same hole should
  match the actual elevation change of the shot.

- False-negative group capture on manual stroke add. When a real swing
  was missed by the detector (presumably gated out somewhere) and the
  user falls back to manually recording the stroke, every rejected
  shape since the last recorded stroke should bundle into a single
  false-negative group and upload — rows land in
  `false_negative_groups` + `false_negative_candidates` with the
  motion CSVs in storage. This was broken at one point and fixed; not
  re-verified on-course since.

- Green-placement screen round context (branch `placement-map-round-context`,
  written on the Pi with no compiler — build it first). On a non-OSM course,
  after a few holes: the compass wedge turns with the wrist and points the way
  the watch's 12 o'clock faces; the whole walked path, prior holes' shot lines,
  flags with hole numbers, and cyan launch rays all show; the map stays smooth
  late in the round; the wedge is gone on the round-play map. Also check the
  cyan rays on the round-play full view.

- Breadcrumb trail UI after the refactor. The fading dot trail on the
  watch reads from the new `pathSamples` array — should look identical
  to before, both in `ActiveRoundView` and `AddHoleNavigationView`.
