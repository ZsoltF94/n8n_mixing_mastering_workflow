-- Gate for automated Notion synchronization. Only inquiries created at or
-- after started_at may be selected. Leave started_at NULL until the owner
-- enables the scheduled workflow; this protects all existing inquiries.
-- Run as the database administrator against mixing_mastering_demo only.
BEGIN;

DO $$
BEGIN
    IF current_database() <> 'mixing_mastering_demo' THEN
        RAISE EXCEPTION 'This migration must run against mixing_mastering_demo';
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.notion_sync_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    started_at timestamptz
);

INSERT INTO public.notion_sync_settings (id, started_at)
VALUES (true, NULL)
ON CONFLICT (id) DO NOTHING;

GRANT SELECT ON public.notion_sync_settings TO mixing_mastering_app;

COMMIT;
