-- Synthetic, rolled-back check for one-time e-mail verification tokens.
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
) VALUES
(
    '10000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'Demo', 'Confirmed', 'confirmed@example.invalid',
    'mixing', 'Synthetic verification test', 'https://example.invalid/confirmed'
),
(
    '10000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'Demo', 'Expired', 'expired@example.invalid',
    'mastering', 'Synthetic expiry test', 'https://example.invalid/expired'
);

INSERT INTO public.access_tokens (
    inquiry_id, purpose, token_hash, expires_at, created_at
) VALUES
(
    '10000000-0000-4000-8000-000000000001',
    'email_verification', repeat('a', 64), now() + interval '30 minutes', now()
),
(
    '10000000-0000-4000-8000-000000000002',
    'email_verification', repeat('b', 64), now() - interval '1 minute', now() - interval '1 hour'
);

PREPARE confirm_token(text) AS
WITH matched AS MATERIALIZED (
  SELECT
    token.id AS token_id,
    token.inquiry_id,
    token.expires_at,
    token.used_at,
    token.revoked_at,
    inquiry.status
  FROM public.access_tokens AS token
  JOIN public.inquiries AS inquiry ON inquiry.id = token.inquiry_id
  WHERE token.token_hash = $1
    AND token.purpose = 'email_verification'
), eligible AS (
  SELECT *
  FROM matched
  WHERE used_at IS NULL
    AND revoked_at IS NULL
    AND expires_at > now()
    AND status = 'pending_verification'
), consumed AS (
  UPDATE public.access_tokens AS token
  SET used_at = now()
  FROM eligible
  WHERE token.id = eligible.token_id
  RETURNING token.inquiry_id
), advanced AS (
  UPDATE public.inquiries AS inquiry
  SET status = 'evaluating', email_verified_at = now(), updated_at = now()
  FROM consumed
  WHERE inquiry.id = consumed.inquiry_id
    AND inquiry.status = 'pending_verification'
  RETURNING inquiry.id
), expired AS (
  UPDATE public.inquiries AS inquiry
  SET status = 'verification_expired', updated_at = now()
  FROM matched
  WHERE inquiry.id = matched.inquiry_id
    AND matched.used_at IS NULL
    AND matched.revoked_at IS NULL
    AND matched.expires_at <= now()
    AND inquiry.status = 'pending_verification'
  RETURNING inquiry.id
)
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM advanced) THEN 'verified'
  WHEN NOT EXISTS (SELECT 1 FROM matched) THEN 'invalid'
  WHEN (SELECT revoked_at FROM matched LIMIT 1) IS NOT NULL THEN 'revoked'
  WHEN (SELECT used_at FROM matched LIMIT 1) IS NOT NULL THEN 'already_used'
  WHEN (SELECT expires_at FROM matched LIMIT 1) <= now() THEN 'expired'
  ELSE 'unavailable'
END AS outcome;

EXECUTE confirm_token(repeat('a', 64));
EXECUTE confirm_token(repeat('a', 64));
EXECUTE confirm_token(repeat('b', 64));
EXECUTE confirm_token(repeat('c', 64));

SELECT id, status, email_verified_at IS NOT NULL AS has_verification_time
FROM public.inquiries
WHERE id IN (
    '10000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002'
)
ORDER BY id;

ROLLBACK;

SELECT count(*) AS rows_after_rollback
FROM public.inquiries
WHERE id IN (
    '10000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002'
);
