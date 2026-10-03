-- Run only after the owner has attached all credentials and activated the
-- scheduled workflow. This starts selection from the current PostgreSQL time;
-- older inquiries stay excluded. A second run does not move the boundary.
UPDATE public.notion_sync_settings
SET started_at = clock_timestamp()
WHERE id = true AND started_at IS NULL
RETURNING started_at;
