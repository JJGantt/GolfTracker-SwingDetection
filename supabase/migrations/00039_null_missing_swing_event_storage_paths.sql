-- Keep historical swing-event metadata rows, but clear storage_path when the
-- referenced motion CSV does not actually exist in the swing-motion bucket.
--
-- This cleanly separates "metadata-only" events from CSV-backed detection
-- samples so analysis tools can filter on `storage_path IS NOT NULL`.

UPDATE public.swing_events AS se
SET storage_path = NULL
WHERE se.storage_path IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM storage.objects AS so
      WHERE so.bucket_id = 'swing-motion'
        AND lower(so.name) = lower(se.storage_path)
  );
