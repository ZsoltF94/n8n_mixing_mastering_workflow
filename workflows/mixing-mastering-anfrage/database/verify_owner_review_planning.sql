-- Verify the SQL used by the n8n owner-review planning node.
-- The same synthetic review is submitted twice; only one token and one action may exist.
-- Every data change is rolled back.

BEGIN;

-- Use the same restricted role as the n8n Postgres credential.
SET LOCAL ROLE mixing_mastering_app;

INSERT INTO public.inquiries (
    id,
    submission_key,
    first_name,
    last_name,
    email,
    selected_service,
    message,
    download_url,
    status,
    service_unklar,
    review_reason,
    ai_suggested_service,
    ai_summary,
    email_verified_at
) VALUES (
    '50000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000101',
    'Demo',
    'Planning',
    'planning@example.invalid',
    'mixing_and_mastering',
    'Synthetic owner notification planning test',
    'https://example.invalid/planning',
    'awaiting_owner_review',
    true,
    'service_conflict',
    'mixing',
    'Synthetic planning summary',
    now()
);

INSERT INTO public.reply_reviews (
    id,
    inquiry_id,
    draft_text
) VALUES (
    '50000000-0000-4000-8000-000000000002',
    '50000000-0000-4000-8000-000000000001',
    'Synthetic editable clarification draft'
);

-- This prepared statement mirrors the parameterized n8n Postgres query.
PREPARE prepare_owner_review(uuid, uuid, text) AS
WITH eligible AS (
  SELECT
    review.id AS reply_review_id,
    review.inquiry_id
  FROM public.reply_reviews AS review
  JOIN public.inquiries AS inquiry ON inquiry.id = review.inquiry_id
  WHERE review.id = $2::uuid
    AND review.inquiry_id = $1::uuid
    AND review.decision = 'pending'
    AND inquiry.status = 'awaiting_owner_review'
), created_token AS (
  INSERT INTO public.access_tokens (
    inquiry_id, reply_review_id, purpose, token_hash, expires_at
  )
  SELECT
    inquiry_id,
    reply_review_id,
    'owner_review',
    $3,
    now() + interval '24 hours'
  FROM eligible
  ON CONFLICT DO NOTHING
  RETURNING inquiry_id, reply_review_id, expires_at
), planned_notification AS (
  INSERT INTO public.outbound_actions (
    inquiry_id, kind, idempotency_key
  )
  SELECT
    inquiry_id,
    'owner_notification',
    'owner_notification:' || reply_review_id::text
  FROM created_token
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING inquiry_id
)
SELECT
  created_token.inquiry_id::text AS inquiry_id,
  created_token.reply_review_id::text AS reply_review_id,
  created_token.expires_at,
  EXISTS (SELECT 1 FROM planned_notification) AS owner_notification_planned
FROM created_token;

-- The first execution must create the token and plan the notification.
EXECUTE prepare_owner_review(
    '50000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000002',
    repeat('8', 64)
);

-- A repeated execution with a new raw-token hash must create no second row.
EXECUTE prepare_owner_review(
    '50000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000002',
    repeat('9', 64)
);

-- Expected result: one owner token and one owner notification action.
SELECT
    (SELECT count(*)
     FROM public.access_tokens
     WHERE inquiry_id = '50000000-0000-4000-8000-000000000001'
       AND purpose = 'owner_review') AS owner_token_count,
    (SELECT count(*)
     FROM public.outbound_actions
     WHERE inquiry_id = '50000000-0000-4000-8000-000000000001'
       AND kind = 'owner_notification') AS owner_notification_count;

ROLLBACK;

-- The synthetic inquiry must not remain after verification.
SELECT count(*) AS synthetic_rows_after_rollback
FROM public.inquiries
WHERE id = '50000000-0000-4000-8000-000000000001';
