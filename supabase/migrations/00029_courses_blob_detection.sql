-- Persist blob-detection results on the shared courses row so that:
--   1. The first iPhone to run the analyzer for a course pays the cost
--      (~10-30s for MKMapSnapshotter + connected-component labeling).
--   2. Every subsequent device — same user or any other — reuses the
--      cached result instantly without re-running the analyzer.
--   3. iPhone-app-not-foreground scenarios stop being a hard blocker:
--      if the data exists server-side, the watch can fetch it directly.
--
-- Shape: a JSON envelope identical to `CourseHoleDetectionData` (the
-- struct already serialized for WatchConnectivity transfer). One row
-- per course, last-write-wins. We rely on the existing courses RLS
-- policies (read-all-authenticated, write-restricted-to-creator OR
-- legacy-null).

alter table courses
    add column if not exists blob_detection_results jsonb,
    add column if not exists blob_detection_at timestamptz;

comment on column courses.blob_detection_results is
    'Cached HoleDetectionAnalyzer output: array of detected blobs with area, min_width, elongation, greenness_score, centroid_lat/lon, polygon. One write per analyzer run; clients refetch on round start.';

comment on column courses.blob_detection_at is
    'Timestamp of the most recent successful blob detection. Used so clients can decide whether to invalidate (e.g. if MapKit imagery changed enough to warrant re-running).';

create index if not exists idx_courses_blob_detection_at
    on courses (blob_detection_at)
    where blob_detection_results is not null;
