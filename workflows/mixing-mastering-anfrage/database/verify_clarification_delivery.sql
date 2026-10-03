-- Verify claim and result handling for the approved customer clarification email.
-- Success and uncertain Gmail delivery use synthetic rows and roll back completely.

BEGIN;

-- Exercise the same restricted permissions used by the n8n Postgres credential.
SET LOCAL ROLE mixing_mastering_app;

INSERT INTO public.inquiries (
    id, submission_key, first_name, last_name, email, selected_service,
    message, download_url, status, service_unklar, review_reason,
    ai_suggested_service, ai_summary, email_verified_at
) VALUES
(
    '80000000-0000-4000-8000-000000000001',
    '80000000-0000-4000-8000-000000000101',
    'Demo', 'Success', 'clarification-success@example.invalid', 'mixing_and_mastering',
    'Synthetic successful clarification delivery', 'https://example.invalid/success',
    'awaiting_owner_review', true, 'service_conflict', 'mixing',
    'Synthetic success summary', now()
),
(
    '80000000-0000-4000-8000-000000000002',
    '80000000-0000-4000-8000-000000000102',
    'Demo', 'Review', 'clarification-review@example.invalid', 'mastering',
    'Synthetic uncertain clarification delivery', 'https://example.invalid/review',
    'awaiting_owner_review', true, 'service_conflict', 'mixing',
    'Synthetic review summary', now()
);

INSERT INTO public.reply_reviews (
    id, inquiry_id, draft_text, edited_text, decision, decided_at
) VALUES
(
    '80000000-0000-4000-8000-000000000011',
    '80000000-0000-4000-8000-000000000001',
    'Synthetic original success draft',
    'Synthetic approved success text',
    'approved', now()
),
(
    '80000000-0000-4000-8000-000000000012',
    '80000000-0000-4000-8000-000000000002',
    'Synthetic original review draft',
    'Synthetic approved review text',
    'approved', now()
);

INSERT INTO public.access_tokens (
    inquiry_id, reply_review_id, purpose, token_hash, expires_at, used_at
) VALUES
(
    '80000000-0000-4000-8000-000000000001',
    '80000000-0000-4000-8000-000000000011',
    'owner_review', repeat('c', 64), now() + interval '24 hours', now()
),
(
    '80000000-0000-4000-8000-000000000002',
    '80000000-0000-4000-8000-000000000012',
    'owner_review', repeat('d', 64), now() + interval '24 hours', now()
);

INSERT INTO public.access_tokens (
    inquiry_id, purpose, token_hash, expires_at
) VALUES
(
    '80000000-0000-4000-8000-000000000001',
    'customer_followup', repeat('e', 64), now() + interval '7 days'
),
(
    '80000000-0000-4000-8000-000000000002',
    'customer_followup', repeat('f', 64), now() + interval '7 days'
);

INSERT INTO public.outbound_actions (inquiry_id, kind, idempotency_key) VALUES
(
    '80000000-0000-4000-8000-000000000001',
    'clarification_email',
    'clarification_email:80000000-0000-4000-8000-000000000011'
),
(
    '80000000-0000-4000-8000-000000000002',
    'clarification_email',
    'clarification_email:80000000-0000-4000-8000-000000000012'
);

-- Mirrors the n8n claim query. Both token hashes bind the action to the exact
-- approved review and inquiry before pending may change to in_progress.
PREPARE claim_clarification(text, text) AS
WITH eligible AS MATERIALIZED (
  SELECT
    action.id AS action_id,
    action.inquiry_id,
    review.id AS reply_review_id,
    inquiry.email,
    review.edited_text
  FROM public.outbound_actions AS action
  JOIN public.access_tokens AS followup_token
    ON followup_token.inquiry_id = action.inquiry_id
   AND followup_token.purpose = 'customer_followup'
   AND followup_token.token_hash = $1
  JOIN public.access_tokens AS owner_token
    ON owner_token.inquiry_id = action.inquiry_id
   AND owner_token.purpose = 'owner_review'
   AND owner_token.token_hash = $2
  JOIN public.reply_reviews AS review
    ON review.id = owner_token.reply_review_id
   AND review.inquiry_id = owner_token.inquiry_id
  JOIN public.inquiries AS inquiry
    ON inquiry.id = action.inquiry_id
  WHERE action.kind = 'clarification_email'
    AND action.idempotency_key = 'clarification_email:' || review.id::text
    AND action.state = 'pending'
    AND followup_token.used_at IS NULL
    AND followup_token.revoked_at IS NULL
    AND followup_token.expires_at > now()
    AND owner_token.used_at IS NOT NULL
    AND review.decision = 'approved'
    AND btrim(review.edited_text) <> ''
    AND inquiry.status = 'awaiting_owner_review'
), claimed AS (
  UPDATE public.outbound_actions AS action
  SET
    state = 'in_progress',
    attempt_count = attempt_count + 1,
    last_attempt_at = now(),
    last_error_code = NULL
  FROM eligible
  WHERE action.id = eligible.action_id
    AND action.state = 'pending'
  RETURNING action.inquiry_id
)
SELECT
  eligible.inquiry_id::text AS inquiry_id,
  eligible.reply_review_id::text AS reply_review_id,
  eligible.email,
  eligible.edited_text,
  'in_progress'::text AS state
FROM eligible
JOIN claimed ON claimed.inquiry_id = eligible.inquiry_id;

-- The first claim succeeds and returns the exact approved text; the repeated
-- claim for the same action returns no row.
EXECUTE claim_clarification(repeat('e', 64), repeat('c', 64));
EXECUTE claim_clarification(repeat('e', 64), repeat('c', 64));

PREPARE mark_clarification_success(uuid, text) AS
WITH marked_action AS (
  UPDATE public.outbound_actions AS action
  SET
    state = 'succeeded',
    completed_at = now(),
    external_reference = $2,
    last_error_code = NULL
  WHERE action.inquiry_id = $1
    AND action.kind = 'clarification_email'
    AND action.state = 'in_progress'
    AND EXISTS (
      SELECT 1
      FROM public.inquiries AS inquiry
      WHERE inquiry.id = action.inquiry_id
        AND inquiry.status = 'awaiting_owner_review'
    )
  RETURNING action.inquiry_id
), updated_inquiry AS (
  UPDATE public.inquiries AS inquiry
  SET status = 'awaiting_customer', updated_at = now()
  FROM marked_action
  WHERE inquiry.id = marked_action.inquiry_id
    AND inquiry.status = 'awaiting_owner_review'
  RETURNING inquiry.id, inquiry.status
)
SELECT
  updated_inquiry.id::text AS inquiry_id,
  'succeeded'::text AS action_state,
  updated_inquiry.status AS inquiry_status
FROM updated_inquiry;

EXECUTE mark_clarification_success(
    '80000000-0000-4000-8000-000000000001',
    'synthetic-gmail-message-id'
);

-- The second synthetic request covers the uncertain Gmail error output.
EXECUTE claim_clarification(repeat('f', 64), repeat('d', 64));

PREPARE mark_clarification_review(uuid) AS
WITH marked_action AS (
  UPDATE public.outbound_actions AS action
  SET
    state = 'needs_review',
    last_error_code = 'clarification_email_gmail_error'
  WHERE action.inquiry_id = $1
    AND action.kind = 'clarification_email'
    AND action.state = 'in_progress'
  RETURNING action.inquiry_id
), updated_inquiry AS (
  UPDATE public.inquiries AS inquiry
  SET status = 'manual_review', updated_at = now()
  FROM marked_action
  WHERE inquiry.id = marked_action.inquiry_id
    AND inquiry.status = 'awaiting_owner_review'
  RETURNING inquiry.id, inquiry.status
)
SELECT
  updated_inquiry.id::text AS inquiry_id,
  'needs_review'::text AS action_state,
  updated_inquiry.status AS inquiry_status,
  'clarification_email_gmail_error'::text AS last_error_code
FROM updated_inquiry;

EXECUTE mark_clarification_review('80000000-0000-4000-8000-000000000002');

-- Expected: one succeeded/awaiting_customer pair and one
-- needs_review/manual_review pair; neither customer token is consumed by sending.
SELECT
    action.inquiry_id,
    action.state AS action_state,
    action.attempt_count,
    action.completed_at IS NOT NULL AS has_completed_at,
    action.external_reference,
    action.last_error_code,
    inquiry.status AS inquiry_status,
    followup_token.used_at IS NULL AS customer_token_still_unused
FROM public.outbound_actions AS action
JOIN public.inquiries AS inquiry ON inquiry.id = action.inquiry_id
JOIN public.access_tokens AS followup_token
  ON followup_token.inquiry_id = action.inquiry_id
 AND followup_token.purpose = 'customer_followup'
WHERE action.inquiry_id IN (
    '80000000-0000-4000-8000-000000000001',
    '80000000-0000-4000-8000-000000000002'
)
  AND action.kind = 'clarification_email'
ORDER BY action.inquiry_id;

ROLLBACK;

SELECT count(*) AS synthetic_rows_after_rollback
FROM public.inquiries
WHERE id IN (
    '80000000-0000-4000-8000-000000000001',
    '80000000-0000-4000-8000-000000000002'
);
