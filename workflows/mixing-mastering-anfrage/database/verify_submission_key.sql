-- Run against mixing_mastering_demo. The transaction is always rolled back.
-- Expected counts: first_insert_count = 1, repeat_insert_count = 0.

BEGIN;
SET LOCAL ROLE mixing_mastering_app;

WITH created AS (
    INSERT INTO public.inquiries (
        submission_key, first_name, last_name, email,
        selected_service, message, download_url
    ) VALUES (
        '11111111-1111-4111-8111-111111111111',
        'Demo', 'Person', 'demo@example.invalid',
        'mixing', 'Synthetic test inquiry', 'https://example.invalid/audio.zip'
    )
    ON CONFLICT (submission_key) DO NOTHING
    RETURNING id
)
SELECT count(*) AS first_insert_count FROM created;

WITH created AS (
    INSERT INTO public.inquiries (
        submission_key, first_name, last_name, email,
        selected_service, message, download_url
    ) VALUES (
        '11111111-1111-4111-8111-111111111111',
        'Demo', 'Person', 'demo@example.invalid',
        'mixing', 'Synthetic test inquiry', 'https://example.invalid/audio.zip'
    )
    ON CONFLICT (submission_key) DO NOTHING
    RETURNING id
)
SELECT count(*) AS repeat_insert_count FROM created;

ROLLBACK;
