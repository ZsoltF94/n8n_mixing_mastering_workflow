-- Verify the atomic owner-review POST decision used by n8n.
-- Approval and rejection use synthetic rows only; the transaction is rolled back.

BEGIN;

-- Exercise the same restricted permissions used by the n8n Postgres credential.
SET LOCAL ROLE mixing_mastering_app;

INSERT INTO public.inquiries (
    id, submission_key, first_name, last_name, email, selected_service,
    message, download_url, status, service_unklar, review_reason,
    ai_suggested_service, ai_summary, email_verified_at
) VALUES
(
    '70000000-0000-4000-8000-000000000001',
    '70000000-0000-4000-8000-000000000101',
    'Demo', 'Approve', 'approve@example.invalid', 'mixing_and_mastering',
    'Synthetic approval case', 'https://example.invalid/approve',
    'awaiting_owner_review', true, 'service_conflict', 'mixing',
    'Synthetic approval summary', now()
),
(
    '70000000-0000-4000-8000-000000000002',
    '70000000-0000-4000-8000-000000000102',
    'Demo', 'Reject', 'reject@example.invalid', 'mastering',
    'Synthetic rejection case', 'https://example.invalid/reject',
    'awaiting_owner_review', true, 'service_conflict', 'mixing',
    'Synthetic rejection summary', now()
);

INSERT INTO public.reply_reviews (id, inquiry_id, draft_text) VALUES
(
    '70000000-0000-4000-8000-000000000011',
    '70000000-0000-4000-8000-000000000001',
    'Synthetic approval draft'
),
(
    '70000000-0000-4000-8000-000000000012',
    '70000000-0000-4000-8000-000000000002',
    'Synthetic rejection draft'
);

INSERT INTO public.access_tokens (
    inquiry_id, reply_review_id, purpose, token_hash, expires_at
) VALUES
(
    '70000000-0000-4000-8000-000000000001',
    '70000000-0000-4000-8000-000000000011',
    'owner_review', repeat('7', 64), now() + interval '24 hours'
),
(
    '70000000-0000-4000-8000-000000000002',
    '70000000-0000-4000-8000-000000000012',
    'owner_review', repeat('8', 64), now() + interval '24 hours'
);

-- Mirrors the full parameterized n8n query. The CTE chain locks the decision
-- through the one-time token update before changing any dependent row.
PREPARE decide_owner_review(text, text, text, text, text) AS
WITH matched AS MATERIALIZED (
  SELECT
    token.id AS token_id,
    token.inquiry_id,
    token.reply_review_id,
    token.expires_at,
    token.used_at,
    token.revoked_at,
    review.decision AS review_decision,
    inquiry.status AS inquiry_status
  FROM public.access_tokens AS token
  JOIN public.reply_reviews AS review
    ON review.id = token.reply_review_id
   AND review.inquiry_id = token.inquiry_id
  JOIN public.inquiries AS inquiry
    ON inquiry.id = token.inquiry_id
  WHERE token.token_hash = $1
    AND token.purpose = 'owner_review'
), eligible AS (
  SELECT *
  FROM matched
  WHERE $5 = 'valid'
    AND $2 IN ('approve', 'reject')
    AND used_at IS NULL
    AND revoked_at IS NULL
    AND expires_at > now()
    AND review_decision = 'pending'
    AND inquiry_status = 'awaiting_owner_review'
    AND ($2 = 'reject' OR (btrim($3) <> '' AND char_length($3) <= 2000))
), consumed AS (
  UPDATE public.access_tokens AS token
  SET used_at = now()
  FROM eligible
  WHERE token.id = eligible.token_id
    AND token.used_at IS NULL
  RETURNING token.inquiry_id, token.reply_review_id
), decided AS (
  UPDATE public.reply_reviews AS review
  SET
    decision = CASE WHEN $2 = 'approve' THEN 'approved' ELSE 'rejected' END,
    edited_text = CASE WHEN $2 = 'approve' THEN $3 ELSE NULL END,
    decided_at = now()
  FROM consumed
  WHERE review.id = consumed.reply_review_id
    AND review.inquiry_id = consumed.inquiry_id
    AND review.decision = 'pending'
  RETURNING review.id AS reply_review_id, review.inquiry_id, review.decision
), rejected_inquiry AS (
  UPDATE public.inquiries AS inquiry
  SET status = 'manual_review', updated_at = now()
  FROM decided
  WHERE inquiry.id = decided.inquiry_id
    AND decided.decision = 'rejected'
    AND inquiry.status = 'awaiting_owner_review'
  RETURNING inquiry.id
), followup_token AS (
  INSERT INTO public.access_tokens (inquiry_id, purpose, token_hash, expires_at)
  SELECT
    decided.inquiry_id,
    'customer_followup',
    $4,
    now() + interval '7 days'
  FROM decided
  WHERE decided.decision = 'approved'
  ON CONFLICT DO NOTHING
  RETURNING inquiry_id, expires_at
), planned_email AS (
  INSERT INTO public.outbound_actions (inquiry_id, kind, idempotency_key)
  SELECT
    decided.inquiry_id,
    'clarification_email',
    'clarification_email:' || decided.reply_review_id::text
  FROM decided
  JOIN followup_token ON followup_token.inquiry_id = decided.inquiry_id
  WHERE decided.decision = 'approved'
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING inquiry_id
)
SELECT
  CASE
    WHEN $5 <> 'valid' THEN 'invalid_input'
    WHEN NOT EXISTS (SELECT 1 FROM matched) THEN 'invalid'
    WHEN (SELECT used_at IS NOT NULL FROM matched LIMIT 1) THEN 'already_used'
    WHEN (SELECT revoked_at IS NOT NULL FROM matched LIMIT 1) THEN 'revoked'
    WHEN (SELECT expires_at <= now() FROM matched LIMIT 1) THEN 'expired'
    WHEN (SELECT review_decision <> 'pending' FROM matched LIMIT 1) THEN 'already_decided'
    WHEN (SELECT inquiry_status <> 'awaiting_owner_review' FROM matched LIMIT 1) THEN 'unavailable'
    WHEN EXISTS (SELECT 1 FROM decided WHERE decision = 'approved') THEN 'approved'
    WHEN EXISTS (SELECT 1 FROM decided WHERE decision = 'rejected') THEN 'rejected'
    ELSE 'unavailable'
  END AS outcome,
  EXISTS (SELECT 1 FROM planned_email) AS customer_followup_planned,
  (SELECT expires_at FROM followup_token LIMIT 1) AS customer_followup_expires_at;

-- Approval must consume the owner token, preserve the edited text exactly,
-- create one seven-day customer token, and plan one clarification email.
EXECUTE decide_owner_review(
    repeat('7', 64),
    'approve',
    'Synthetic edited approval text',
    repeat('9', 64),
    'valid'
);

-- Repeating the same request must return already_used and change nothing else.
EXECUTE decide_owner_review(
    repeat('7', 64),
    'approve',
    'Synthetic duplicate text',
    repeat('a', 64),
    'valid'
);

-- Rejection consumes its token, stores no edited text, moves the inquiry to
-- manual_review, and creates neither customer token nor email action.
EXECUTE decide_owner_review(
    repeat('8', 64),
    'reject',
    '',
    repeat('b', 64),
    'valid'
);

SELECT
    review.inquiry_id,
    review.decision,
    review.edited_text,
    review.decided_at IS NOT NULL AS has_decided_at,
    inquiry.status,
    owner_token.used_at IS NOT NULL AS owner_token_used,
    count(followup_token.id) AS customer_followup_tokens,
    count(action.id) AS clarification_actions
FROM public.reply_reviews AS review
JOIN public.inquiries AS inquiry ON inquiry.id = review.inquiry_id
JOIN public.access_tokens AS owner_token
  ON owner_token.reply_review_id = review.id
 AND owner_token.purpose = 'owner_review'
LEFT JOIN public.access_tokens AS followup_token
  ON followup_token.inquiry_id = review.inquiry_id
 AND followup_token.purpose = 'customer_followup'
LEFT JOIN public.outbound_actions AS action
  ON action.inquiry_id = review.inquiry_id
 AND action.kind = 'clarification_email'
WHERE review.inquiry_id IN (
    '70000000-0000-4000-8000-000000000001',
    '70000000-0000-4000-8000-000000000002'
)
GROUP BY review.inquiry_id, review.decision, review.edited_text, review.decided_at,
         inquiry.status, owner_token.used_at
ORDER BY review.inquiry_id;

-- The approval inquiry remains in awaiting_owner_review until Gmail confirms
-- delivery; the customer token should be approximately seven days valid.
SELECT
    inquiry_id,
    expires_at > now() + interval '6 days 23 hours' AS valid_for_about_seven_days,
    expires_at <= now() + interval '7 days 1 minute' AS not_longer_than_seven_days
FROM public.access_tokens
WHERE purpose = 'customer_followup'
  AND inquiry_id = '70000000-0000-4000-8000-000000000001';

ROLLBACK;

SELECT count(*) AS synthetic_rows_after_rollback
FROM public.inquiries
WHERE id IN (
    '70000000-0000-4000-8000-000000000001',
    '70000000-0000-4000-8000-000000000002'
);
