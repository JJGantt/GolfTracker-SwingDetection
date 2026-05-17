-- Metadata-only swing_events (no backing motion CSV) should not participate in
-- labeled detection analysis. Clear label/confidence when storage_path is NULL.

UPDATE public.swing_events
SET label = NULL,
    confidence = NULL
WHERE storage_path IS NULL
  AND (label IS NOT NULL OR confidence IS NOT NULL);
