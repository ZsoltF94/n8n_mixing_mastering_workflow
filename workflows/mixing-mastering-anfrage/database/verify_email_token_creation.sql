-- Synthetic, rolled-back check for creating one verification token and one mail action.
-- Run as the local PostgreSQL administrator against mixing_mastering_demo only.

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'mixing_mastering_demo' THEN
        RAISE EXCEPTION 'This test must run against mixing_mastering_demo';
    END IF;
END
$$;

SET LOCAL ROLE mixing_mastering_app;

INSERT INTO public.inquiries (
    id, submission_key, first_name, last_name, email,
    selected_service, message, download_url
) VALUES (
    '30000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000001',
    'Demo', 'Token', 'token@example.invalid',
    'mixing_and_mastering', 'Synthetic token test', 'https://example.invalid/token'
);

PREPARE prepare_verification(uuid, text, text) AS
WITH created_token AS (
  INSERT INTO public.access_tokens (
    inquiry_id, purpose, token_hash, expires_at
  )
  SELECT $1::uuid, 'email_verification', $2, now() + interval '30 minutes'
  WHERE $3 = 'pending_verification'
  ON CONFLICT (token_hash) DO NOTHING
  RETURNING inquiry_id, expires_at
), planned_email AS (
  INSERT INTO public.outbound_actions (
    inquiry_id, kind, idempotency_key
  )
  SELECT inquiry_id, 'verification_email', 'verification_email:' || inquiry_id::text
  FROM created_token
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING inquiry_id
)
SELECT
  created_token.inquiry_id::text AS inquiry_id,
  created_token.expires_at,
  EXISTS (SELECT 1 FROM planned_email) AS verification_email_planned
FROM created_token;

EXECUTE prepare_verification(
    '30000000-0000-4000-8000-000000000001', repeat('d', 64), 'pending_verification'
);
EXECUTE prepare_verification(
    '30000000-0000-4000-8000-000000000001', repeat('d', 64), 'pending_verification'
);

SELECT
    (SELECT count(*) FROM public.access_tokens
     WHERE inquiry_id = '30000000-0000-4000-8000-000000000001') AS token_count,
    (SELECT count(*) FROM public.outbound_actions
     WHERE inquiry_id = '30000000-0000-4000-8000-000000000001'
       AND kind = 'verification_email') AS action_count;

ROLLBACK;

SELECT
    (SELECT count(*) FROM public.access_tokens
     WHERE inquiry_id = '30000000-0000-4000-8000-000000000001') AS tokens_after_rollback,
    (SELECT count(*) FROM public.outbound_actions
     WHERE inquiry_id = '30000000-0000-4000-8000-000000000001') AS actions_after_rollback;
