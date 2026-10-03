-- Rollback check for the scheduled sync start gate. Uses one artificial row;
-- no Notion API call, customer data, email, or download occurs.
BEGIN;

UPDATE public.notion_sync_settings SET started_at = now() WHERE id = true;
SET ROLE mixing_mastering_app;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.inquiries i
        CROSS JOIN public.notion_sync_settings s
        WHERE i.id = '734feb1c-021a-4313-aac5-830377a79875'
          AND i.created_at >= s.started_at
    ) THEN
        RAISE EXCEPTION 'Historical test inquiry passed the start gate';
    END IF;
END
$$;

INSERT INTO public.inquiries (
    id, submission_key, first_name, last_name, email,
    selected_service, message, download_url, status,
    service_unklar, email_verified_at
)
VALUES (
    '18b0b39d-b452-4c9a-955a-3135d2bbb3d6',
    '0ae25dfc-783e-4ba7-a197-f25355591169',
    'Neu', 'Demo', 'notion-new@example.invalid',
    'mixing', 'Kuenstlicher Test der Startgrenze.',
    'https://example.invalid/new-audio.zip',
    'awaiting_owner_review', true, now()
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.inquiries i
        CROSS JOIN public.notion_sync_settings s
        WHERE i.id = '18b0b39d-b452-4c9a-955a-3135d2bbb3d6'
          AND s.started_at IS NOT NULL
          AND i.created_at >= s.started_at
    ) THEN
        RAISE EXCEPTION 'New synthetic inquiry did not pass the start gate';
    END IF;
END
$$;

RESET ROLE;
ROLLBACK;
