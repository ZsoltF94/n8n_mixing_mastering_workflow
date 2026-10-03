-- Add a unique key supplied by each workflow execution.
-- Reusing a key cannot insert the same inquiry twice; separate submissions get new keys.
-- Run once as the database administrator against mixing_mastering_demo.
-- Existing rows, if any, receive distinct keys; future inserts must provide one.

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'mixing_mastering_demo' THEN
        RAISE EXCEPTION 'This migration must run against mixing_mastering_demo';
    END IF;
END
$$;

ALTER TABLE public.inquiries ADD COLUMN submission_key uuid;

UPDATE public.inquiries
SET submission_key = gen_random_uuid()
WHERE submission_key IS NULL;

ALTER TABLE public.inquiries
    ALTER COLUMN submission_key SET NOT NULL,
    ADD CONSTRAINT inquiries_submission_key_unique UNIQUE (submission_key);

COMMIT;
