-- Verify the SQL used to claim and record the internal owner-notification email.
-- Two synthetic inquiries cover success and uncertain Gmail delivery; all rows roll back.

BEGIN;

-- Exercise the same restricted permissions used by the n8n Postgres credential.
SET LOCAL ROLE mixing_mastering_app;

INSERT INTO public.inquiries (
    id, submission_key, first_name, last_name, email, selected_service,
    message, download_url, status, service_unklar, review_reason,
    ai_suggested_service, ai_summary, email_verified_at
) VALUES
(
    '60000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000101',
    'Demo', 'Success', 'owner-success@example.invalid', 'mixing_and_mastering',
    'Synthetic successful owner notification', 'https://example.invalid/owner-success',
    'awaiting_owner_review', true, 'service_conflict', 'mixing',
    'Synthetic success summary', now()
),
(
    '60000000-0000-4000-8000-000000000002',
    '60000000-0000-4000-8000-000000000102',
    'Demo', 'Review', 'owner-review@example.invalid', 'mastering',
    'Synthetic uncertain owner notification', 'https://example.invalid/owner-review',
    'awaiting_owner_review', true, 'service_conflict', 'mixing',
    'Synthetic review summary', now()
);

INSERT INTO public.reply_reviews (id, inquiry_id, draft_text) VALUES
(
    '60000000-0000-4000-8000-000000000011',
    '60000000-0000-4000-8000-000000000001',
    'Synthetic success draft'
),
(
    '60000000-0000-4000-8000-000000000012',
    '60000000-0000-4000-8000-000000000002',
    'Synthetic uncertain-delivery draft'
);

INSERT INTO public.access_tokens (
    inquiry_id, reply_review_id, purpose, token_hash, expires_at
) VALUES
(
    '60000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000011',
    'owner_review', repeat('6', 64), now() + interval '24 hours'
),
(
    '60000000-0000-4000-8000-000000000002',
    '60000000-0000-4000-8000-000000000012',
    'owner_review', repeat('7', 64), now() + interval '24 hours'
);

INSERT INTO public.outbound_actions (
    inquiry_id, kind, idempotency_key
) VALUES
(
    '60000000-0000-4000-8000-000000000001',
    'owner_notification',
    'owner_notification:60000000-0000-4000-8000-000000000011'
),
(
    '60000000-0000-4000-8000-000000000002',
    'owner_notification',
    'owner_notification:60000000-0000-4000-8000-000000000012'
);

-- Mirrors the n8n claim query, including the current token and review checks.
PREPARE claim_owner_notification(uuid, uuid) AS
UPDATE public.outbound_actions AS action
SET
  state = 'in_progress',
  attempt_count = attempt_count + 1,
  last_attempt_at = now(),
  last_error_code = NULL
WHERE action.inquiry_id = $1::uuid
  AND action.kind = 'owner_notification'
  AND action.state = 'pending'
  AND EXISTS (
    SELECT 1
    FROM public.access_tokens AS token
    JOIN public.reply_reviews AS review
      ON review.id = token.reply_review_id
     AND review.inquiry_id = token.inquiry_id
    WHERE token.inquiry_id = action.inquiry_id
      AND token.reply_review_id = $2::uuid
      AND token.purpose = 'owner_review'
      AND token.used_at IS NULL
      AND token.revoked_at IS NULL
      AND token.expires_at > now()
      AND review.decision = 'pending'
  )
RETURNING
  action.inquiry_id::text AS inquiry_id,
  ($2::uuid)::text AS reply_review_id,
  action.state;

-- The first claim succeeds; the repeated claim returns no row.
EXECUTE claim_owner_notification(
    '60000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000011'
);
EXECUTE claim_owner_notification(
    '60000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000011'
);

PREPARE mark_owner_notification_success(uuid, text) AS
UPDATE public.outbound_actions
SET
  state = 'succeeded',
  completed_at = now(),
  external_reference = $2,
  last_error_code = NULL
WHERE inquiry_id = $1::uuid
  AND kind = 'owner_notification'
  AND state = 'in_progress'
RETURNING inquiry_id::text AS inquiry_id, state, completed_at;

EXECUTE mark_owner_notification_success(
    '60000000-0000-4000-8000-000000000001',
    'synthetic-gmail-message-id'
);

-- The second action covers the Gmail error output and its manual-review marker.
EXECUTE claim_owner_notification(
    '60000000-0000-4000-8000-000000000002',
    '60000000-0000-4000-8000-000000000012'
);

PREPARE mark_owner_notification_review(uuid) AS
UPDATE public.outbound_actions
SET
  state = 'needs_review',
  last_error_code = 'owner_notification_gmail_error'
WHERE inquiry_id = $1::uuid
  AND kind = 'owner_notification'
  AND state = 'in_progress'
RETURNING inquiry_id::text AS inquiry_id, state, last_error_code;

EXECUTE mark_owner_notification_review(
    '60000000-0000-4000-8000-000000000002'
);

-- Expected: one succeeded action with an external reference and one needs_review action.
SELECT
    inquiry_id,
    state,
    attempt_count,
    completed_at IS NOT NULL AS has_completed_at,
    external_reference,
    last_error_code
FROM public.outbound_actions
WHERE inquiry_id IN (
    '60000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000002'
)
ORDER BY inquiry_id;

ROLLBACK;

SELECT count(*) AS synthetic_rows_after_rollback
FROM public.inquiries
WHERE id IN (
    '60000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000002'
);
