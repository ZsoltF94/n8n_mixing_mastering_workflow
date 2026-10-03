-- Synthetic, rolled-back check for the form intake INSERT.
-- Run as the local PostgreSQL administrator against mixing_mastering_demo only.
-- This test assumes 001_init.sql and 002_submission_key.sql are applied.

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'mixing_mastering_demo' THEN
        RAISE EXCEPTION 'This test must run against mixing_mastering_demo';
    END IF;
END
$$;

SET LOCAL ROLE mixing_mastering_app;

PREPARE insert_demo(uuid, text, text, text, text, text, text) AS
INSERT INTO public.inquiries (
  submission_key, first_name, last_name, email,
  selected_service, message, download_url
) VALUES (
  $1::uuid, $2, $3, $4, $5, $6, $7
)
ON CONFLICT (submission_key) DO NOTHING
RETURNING id::text AS inquiry_id, status;

EXECUTE insert_demo(
    '9a421e44-b902-494c-a8a5-7bccd949c1f2',
    'Demo', 'Person', 'demo@example.invalid', 'mixing',
    'Synthetic portfolio inquiry', 'https://example.invalid/files'
);

EXECUTE insert_demo(
    '9a421e44-b902-494c-a8a5-7bccd949c1f2',
    'Demo', 'Person', 'demo@example.invalid', 'mixing',
    'Synthetic portfolio inquiry', 'https://example.invalid/files'
);

SELECT count(*) AS rows_in_transaction
FROM public.inquiries
WHERE submission_key = '9a421e44-b902-494c-a8a5-7bccd949c1f2';

ROLLBACK;

SELECT count(*) AS rows_after_rollback
FROM public.inquiries
WHERE submission_key = '9a421e44-b902-494c-a8a5-7bccd949c1f2';
